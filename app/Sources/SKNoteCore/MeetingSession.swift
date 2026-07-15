import Foundation
import Observation

/// Maps an RMS level (0…1) to a 0…`maxBars` meter-bar count on a perceptual dB scale. Normal
/// speech is only RMS ~0.02–0.15; a linear scale barely moves, so we map roughly −50 dBFS
/// (quiet) … −6 dBFS (loud) across the bars. Shared by the UI meter and its tests.
public enum LevelMeter {
    public static func bars(forRMS rms: Float, maxBars: Int = 5) -> Int {
        guard rms > 0.0005 else { return 0 }
        let db = 20 * log10(rms)                    // 0.01→−40, 0.1→−20, 0.3→−10
        let normalized = (db + 50) / 44             // −50 dB…−6 dB → 0…1
        let bars = Int((Float(maxBars) * normalized).rounded(.up))
        return min(maxBars, max(0, bars))
    }
}

/// Orchestrates one live meeting: audio sources → transcription (per channel) → diarization
/// (system channel) → assembled transcript → store, plus the full-audio recording.
///
/// Observable so SwiftUI can render live state directly.
@Observable
@MainActor
public final class MeetingSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing        // models downloading / permissions
        case recording
        case finishing        // final diarization + save
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var meeting: Meeting
    /// Finalized, speaker-attributed segments (rebuilt as diarization refines).
    public private(set) var liveSegments: [TranscriptSegment] = []
    /// In-flight volatile text per channel (lighter styling in UI).
    public private(set) var volatileText: [AudioChannel: String] = [:]
    public private(set) var elapsed: Double = 0
    /// Smoothed 0…1 input level per channel, for live level meters.
    public private(set) var levels: [AudioChannel: Float] = [.mic: 0, .system: 0]
    /// True once each channel has produced at least one non-silent chunk — lets the UI warn
    /// "no microphone audio detected" instead of silently recording nothing.
    public private(set) var channelHasAudio: [AudioChannel: Bool] = [:]

    // MARK: - Meeting-end detection

    /// Non-nil while the "has the meeting ended?" prompt is showing. UI renders a banner
    /// with a countdown to `deadline`; no response by then auto-ends the meeting.
    public struct EndPrompt: Equatable, Sendable {
        public let reason: String
        public let deadline: Date
    }
    public private(set) var endPrompt: EndPrompt?
    /// Fired when the end prompt appears (app layer posts the native notification).
    public var onEndPromptShown: ((String) -> Void)?
    /// Fired when an outstanding end prompt is cleared because the meeting continued
    /// (app layer removes the delivered notification).
    public var onEndPromptCleared: (() -> Void)?
    /// Fired when the grace period lapses with no response — the owner should end the
    /// meeting (falls back to `finish()` directly when unset).
    public var onAutoEnd: (() -> Void)?

    private var endEngine: MeetingEndEngine?
    private var autoEndTask: Task<Void, Never>?
    private let autoEndGraceSeconds: Double = 60

    private let store: MeetingStore
    private let sources: [any AudioSource]
    private let recordAudio: Bool
    private var finals: [TranscriptionResult] = []
    private var services: [AudioChannel: TranscriptionService] = [:]
    private var diarizer = DiarizationService()
    private var assembler = TranscriptAssembler()
    private var recorder: RecordingWriter?
    private var pumpTasks: [Task<Void, Never>] = []
    private let clock: SessionClock

    /// When false (offline reprocess from file sources), skip the mic TCC prompt.
    private let requiresMic: Bool

    public init(title: String, store: MeetingStore, sources: [any AudioSource],
                clock: SessionClock, recordAudio: Bool = true,
                autoEndSilenceSeconds: Double? = nil, requiresMic: Bool = true) {
        self.meeting = Meeting(title: title)
        self.store = store
        self.sources = sources
        self.clock = clock
        self.recordAudio = recordAudio
        self.requiresMic = requiresMic
        if let autoEndSilenceSeconds {
            self.endEngine = MeetingEndEngine(silenceTimeout: autoEndSilenceSeconds)
        }
    }

    /// Convenience: live meeting with mic + system tap on a fresh clock. Async because the
    /// mic path is chosen at start: during an active call (WhatsApp/Teams/FaceTime), macOS
    /// mutes raw mic taps, so `MicSourcePicker` probes and falls back to AUVoiceIO capture.
    public static func live(title: String, store: MeetingStore,
                            autoEndSilenceSeconds: Double? = nil) async -> MeetingSession {
        let clock = SessionClock()
        let mic = await MicSourcePicker.pick(clock: clock)
        return MeetingSession(
            title: title, store: store,
            sources: [mic, SystemAudioSource(clock: clock)],
            clock: clock,
            autoEndSilenceSeconds: autoEndSilenceSeconds)
    }

    // MARK: - Lifecycle

    public func start() async {
        phase = .preparing
        do {
            // Preflight: request mic up front so the TCC prompt fires before we invest in
            // model loading, and so a denial is a clear error rather than silent recording.
            // Skipped for offline reprocess (file sources, no live mic).
            if requiresMic {
                let micStatus = await Permission.requestMic()
                if micStatus == .denied {
                    phase = .failed(
                        "Microphone access is off. Enable it in System Settings → Privacy & "
                        + "Security → Microphone, then start again.")
                    return
                }
            }

            try await store.save(meeting)

            // On-device models (no-ops after first run).
            try await TranscriptionService.ensureModel()
            try await diarizer.prepare()

            if recordAudio {
                let recorder = RecordingWriter(url: await store.recordingURL(for: meeting.id))
                try await recorder.start()
                self.recorder = recorder
            }

            for source in sources {
                let service = TranscriptionService(channel: source.channel)
                services[source.channel] = service
                try await service.start { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.ingest(result)
                    }
                }
                let stream = try await source.start()
                pumpTasks.append(Task { [weak self] in
                    for await chunk in stream {
                        guard let self else { break }
                        await self.pump(chunk, into: service)
                    }
                })
            }

            phase = .recording
            meeting.state = .recording
            try await store.save(meeting)
        } catch {
            phase = .failed(error.localizedDescription)
            await teardownSources()
        }
    }

    public func finish() async {
        guard phase == .recording || phase == .preparing else { return }
        phase = .finishing
        dismissEndPrompt()

        await teardownSources()
        for service in services.values {
            await service.finish()
        }
        // The last results hop to the MainActor via ingest(); let those queued tasks land
        // before snapshotting `finals` for the definitive rebuild.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(400))

        // Final full-quality diarization pass, then rebuild the transcript.
        let segments = await diarizer.finalPass()
        rebuild(with: segments)

        await recorder?.finish()

        meeting.state = .complete
        meeting.endedAt = Date()
        meeting.durationSec = elapsed
        meeting.hasRecording = recordAudio
        do {
            try await store.save(meeting)
            try await store.save(Transcript(segments: liveSegments), for: meeting.id)
        } catch {
            phase = .failed("Saving failed: \(error.localizedDescription)")
            return
        }
        phase = .idle
    }

    /// Assign a human name to a speaker key (S2 → "Kainat").
    public func nameSpeaker(key: String, name: String) async {
        meeting.speakers[key]?.name = name.isEmpty ? nil : name
        try? await store.save(meeting)
    }

    // MARK: - Pipeline plumbing

    // Debug: per-channel chunk counters (SKNOTE_DEBUG=1 prints periodic RMS to stderr).
    private var debugChunkCounts: [AudioChannel: Int] = [:]
    private static let debugEnabled =
        ProcessInfo.processInfo.environment["SKNOTE_DEBUG"] == "1"

    private func pump(_ chunk: AudioChunk, into service: TranscriptionService) async {
        // Elapsed time comes from the audio itself (works for live and file sources alike).
        elapsed = max(elapsed, chunk.endTime)

        // Live level + audio-presence tracking (drives the UI meter and the
        // "no microphone audio" warning).
        if !chunk.samples.isEmpty {
            let rms = (chunk.samples.reduce(Float(0)) { $0 + $1 * $1 }
                       / Float(chunk.samples.count)).squareRoot()
            let prior = levels[chunk.channel] ?? 0
            levels[chunk.channel] = max(rms, prior * 0.8)   // fast attack, slow decay
            if rms > 0.01 { channelHasAudio[chunk.channel] = true }
            feedEndDetection(now: chunk.endTime, rms: rms)
        }

        if Self.debugEnabled {
            let count = (debugChunkCounts[chunk.channel] ?? 0) + 1
            debugChunkCounts[chunk.channel] = count
            if count % 20 == 1 {
                let rms = chunk.samples.isEmpty ? 0
                    : (chunk.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.samples.count))
                        .squareRoot()
                FileHandle.standardError.write(Data(
                    "SKNOTE_DEBUG \(chunk.channel.rawValue) chunk#\(count) t=\(String(format: "%.1f", chunk.startTime)) samples=\(chunk.samples.count) rms=\(String(format: "%.5f", rms))\n".utf8))
            }
        }
        await service.feed(chunk)
        if chunk.channel == .system {
            await diarizer.feed(chunk)
            if let refreshed = await diarizer.incrementalPass() {
                rebuild(with: refreshed)
            }
        }
        await recorder?.append(chunk)
    }

    // MARK: - Meeting-end detection plumbing

    private func feedEndDetection(now: Double, rms: Float) {
        guard endEngine != nil, phase == .recording else { return }
        endEngine?.noteAudio(now: now, rms: rms)
        // Audio came back while the prompt/countdown was up → the meeting continues.
        if endPrompt != nil, rms >= MeetingEndEngine.activityRMS {
            endEngine?.cancelPrompt(now: now)
            dismissEndPrompt()
            onEndPromptCleared?()
            return
        }
        if let trigger = endEngine?.evaluate(now: now) {
            showEndPrompt(for: trigger)
        }
    }

    private func showEndPrompt(for trigger: MeetingEndEngine.Trigger) {
        let reason: String
        switch trigger {
        case .silence(let seconds):
            reason = "No audio for \(Int(seconds / 60)) min — has the meeting ended?"
        case .farewell:
            reason = "Sounded like everyone said goodbye — has the meeting ended?"
        }
        let deadline = Date().addingTimeInterval(autoEndGraceSeconds)
        endPrompt = EndPrompt(reason: reason, deadline: deadline)
        onEndPromptShown?(reason)
        autoEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.autoEndGraceSeconds ?? 60))
            guard let self, !Task.isCancelled, self.endPrompt != nil else { return }
            self.endPrompt = nil
            if let onAutoEnd = self.onAutoEnd {
                onAutoEnd()
            } else {
                await self.finish()
            }
        }
    }

    private func dismissEndPrompt() {
        autoEndTask?.cancel()
        autoEndTask = nil
        endPrompt = nil
    }

    /// User chose "Keep Recording" on the end prompt — suppress end detection for a while.
    public func keepRecording() {
        endEngine?.snooze(now: elapsed)
        dismissEndPrompt()
    }

    private func ingest(_ result: TranscriptionResult) {
        // Any transcription — on either channel, volatile or final — proves the meeting is
        // live. The remote client's voice (system channel) is often transcribed below the
        // RMS activity gate, so this is what keeps the silence timer honest while the local
        // user is quiet and just listening.
        noteTranscriptionActivity()

        if result.isFinal {
            endEngine?.noteUtterance(now: elapsed, text: result.text)
            finals.append(result)
            volatileText[result.channel] = nil
            Task { [diarizer] in
                let segments = await diarizer.segments
                await MainActor.run { self.rebuild(with: segments) }
            }
        } else {
            volatileText[result.channel] = result.text
        }
    }

    private func noteTranscriptionActivity() {
        guard endEngine != nil, phase == .recording else { return }
        endEngine?.noteActivity(now: elapsed)
        // Words are being transcribed while the end prompt is up → the meeting continues.
        if endPrompt != nil {
            endEngine?.cancelPrompt(now: elapsed)
            dismissEndPrompt()
            onEndPromptCleared?()
        }
    }

    private func rebuild(with speakerSegments: [SpeakerSegment]) {
        let (segments, speakers) = assembler.assemble(
            finals: finals, speakerSegments: speakerSegments)
        liveSegments = segments
        // Preserve any names the user already assigned mid-meeting.
        for (key, var info) in speakers {
            if let existing = meeting.speakers[key]?.name { info.name = existing }
            meeting.speakers[key] = info
        }
        // Autosave transcript progress so a crash never loses a meeting.
        let snapshot = Transcript(segments: segments)
        let id = meeting.id
        Task { [store, meeting] in
            try? await store.save(snapshot, for: id)
            try? await store.save(meeting)
        }
    }

    private func teardownSources() async {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        for source in sources {
            await source.stop()
        }
    }
}
