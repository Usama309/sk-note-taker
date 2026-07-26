import Foundation
import Observation
import ScreenCaptureKit

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
    /// True while paused: incoming audio is dropped and the timeline is frozen (stopwatch-style),
    /// so the paused stretch is neither recorded nor transcribed. Recording resumes seamlessly.
    public private(set) var isPaused = false
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

    /// Fired on each final utterance so the copilot can proactively offer an answer.
    /// `speakerIsMe` is true for the mic channel (the machine owner).
    public var onFinalUtterance: ((_ speakerIsMe: Bool, _ text: String) -> Void)?

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
    /// Real participant names from the meeting-app UI (Zoom Accessibility / Meet extension),
    /// fed live via `noteActiveSpeaker` and merged into the transcript by the assembler.
    public let nameTrack = SpeakerNameTrack()
    /// Speaker keys the user renamed by hand — these always win over auto-detected names.
    private var userNamedKeys: Set<String> = []
    /// Optional per-meeting screen (video) recording, started on demand after the meeting begins.
    public private(set) var isRecordingScreen = false
    private var screenRecorder: ScreenVideoRecorder?
    private var recorder: RecordingWriter?
    private var pumpTasks: [Task<Void, Never>] = []
    /// Live speaker-labelling runs on its own cadence, off the ingestion path.
    private var diarizationTask: Task<Void, Never>?
    /// Coalescing state for the off-main transcript rebuild: at most one assemble runs at a
    /// time, always over the latest data.
    private var rebuildInFlight = false
    private var rebuildAgain = false
    private var latestSpeakerSegments: [SpeakerSegment] = []
    /// The rapidly-changing meter observables (`elapsed`, `levels`) are published at ~15 Hz from
    /// these scratch values, so per-chunk SwiftUI invalidation never competes with real-time
    /// audio ingestion on the main actor.
    private var scratchElapsed: Double = 0
    private var scratchLevels: [AudioChannel: Float] = [.mic: 0, .system: 0]
    private var lastMeterPublishNanos: UInt64 = 0
    /// Cumulative wall time the pump spends blocked on each stage, so a throughput shortfall can
    /// be localized (recorder vs ASR vs diarizer) from the end-of-meeting log.
    private var recorderNanos: UInt64 = 0
    private var feedNanos: UInt64 = 0
    private var diarizerNanos: UInt64 = 0
    private let clock: SessionClock

    /// When false (offline reprocess from file sources), skip the mic TCC prompt.
    private let requiresMic: Bool
    /// The machine owner's name. Stamped onto the mic speaker so it flows everywhere the
    /// transcript goes — summaries, chat, exports, MCP, the web view — instead of only being
    /// prettified in the UI.
    private let userName: String?
    /// Normalised owner name (nil when unset/blank) — exposed for tests.
    public var configuredUserName: String? { userName }

    public init(title: String, store: MeetingStore, sources: [any AudioSource],
                clock: SessionClock, recordAudio: Bool = true,
                autoEndSilenceSeconds: Double? = nil, requiresMic: Bool = true,
                userName: String? = nil) {
        self.meeting = Meeting(title: title)
        self.store = store
        self.sources = sources
        self.clock = clock
        self.recordAudio = recordAudio
        self.requiresMic = requiresMic
        self.userName = userName?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? userName?.trimmingCharacters(in: .whitespaces) : nil
        if let autoEndSilenceSeconds {
            self.endEngine = MeetingEndEngine(silenceTimeout: autoEndSilenceSeconds)
        }
    }

    /// Convenience: live meeting with mic + system tap on a fresh clock. Async because the
    /// mic path is chosen at start: during an active call (WhatsApp/Teams/FaceTime), macOS
    /// mutes raw mic taps, so `MicSourcePicker` probes and falls back to AUVoiceIO capture.
    public static func live(title: String, store: MeetingStore,
                            autoEndSilenceSeconds: Double? = nil,
                            userName: String? = nil) async -> MeetingSession {
        // Live capture: anchor both channels to one wall clock so a ScreenCaptureKit restart
        // gap can't shift the system timeline behind the mic and get the whole remote side
        // discarded by the recorder. Offline reprocess keeps the default audio-content timing.
        let clock = SessionClock(anchorToWallClock: true)
        let mic = await MicSourcePicker.pick(clock: clock)
        return MeetingSession(
            title: title, store: store,
            sources: [mic, SystemAudioCapture(clock: clock)],
            clock: clock,
            autoEndSilenceSeconds: autoEndSilenceSeconds,
            userName: userName)
    }

    // MARK: - Lifecycle

    public func start() async {
        phase = .preparing
        SKLog.beginMeeting(title: meeting.title, id: meeting.id)
        do {
            // Preflight: request mic up front so the TCC prompt fires before we invest in
            // model loading, and so a denial is a clear error rather than silent recording.
            // Skipped for offline reprocess (file sources, no live mic).
            if requiresMic {
                let micStatus = await Permission.requestMic()
                if micStatus == .denied {
                    SKLog.error(.micPermissionDenied, .mic,
                                "Microphone access denied — the meeting cannot record local audio")
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
                let channel = source.channel
                pumpTasks.append(Task { [weak self] in
                    // Coalesce the source's native (often ~10 ms) buffers into ~80 ms batches
                    // before the per-chunk pump work. VoiceIOMicSource (AUVoiceIO) and
                    // ScreenCaptureKit both deliver small buffers at ~100/s; doing recorder + ASR
                    // + diarizer work per tiny chunk on two channels can't sustain real time on an
                    // older Mac (measured 38% of real time). Batching cuts the iteration and
                    // allocation count ~8x while keeping the audio contiguous.
                    var batch: [Float] = []
                    var batchStart = 0.0
                    var batchEnd = 0.0
                    let flushCount = 1280   // ~80 ms at 16 kHz
                    for await chunk in stream {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        // Paused: flush anything pending, then drop audio until resumed.
                        if self.isPaused {
                            if !batch.isEmpty {
                                await self.pump(AudioChunk(channel: channel, samples: batch,
                                                           startTime: batchStart), into: service)
                                batch.removeAll(keepingCapacity: true)
                            }
                            continue
                        }
                        // A non-contiguous chunk (a capture gap re-anchored the clock) must not be
                        // concatenated onto the batch — flush first so timestamps stay exact.
                        if !batch.isEmpty, abs(chunk.startTime - batchEnd) > 0.005 {
                            await self.pump(AudioChunk(channel: channel, samples: batch,
                                                       startTime: batchStart), into: service)
                            batch.removeAll(keepingCapacity: true)
                        }
                        if batch.isEmpty { batchStart = chunk.startTime }
                        batch.append(contentsOf: chunk.samples)
                        batchEnd = chunk.endTime
                        if batch.count >= flushCount {
                            await self.pump(AudioChunk(channel: channel, samples: batch,
                                                       startTime: batchStart), into: service)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty, let self {
                        await self.pump(AudioChunk(channel: channel, samples: batch,
                                                   startTime: batchStart), into: service)
                    }
                })
            }

            phase = .recording
            meeting.state = .recording
            try await store.save(meeting)
            SKLog.info(.session, "Recording started — sources: "
                       + sources.map { "\($0.channel.rawValue):\(type(of: $0))" }
                            .joined(separator: ", "))

            // Refine speaker labels on a background cadence, never inline in `pump`. A slow
            // diarization pass on an older Mac used to back up chunk ingestion until the
            // recorder dropped the tail of the meeting; here it can lag without starving capture.
            // Low priority so the growing per-pass diarization cost (it re-analyzes the whole
            // accumulated buffer) can never starve real-time audio ingestion on a limited-core Mac.
            diarizationTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.phase == .recording else { break }
                    if let refreshed = await self.diarizer.incrementalPass() {
                        self.rebuild(with: refreshed)
                    }
                }
            }
        } catch {
            SKLog.error(.sessionStartFailed, .session,
                        "Meeting failed to start — no audio is being captured", error: error)
            phase = .failed(error.localizedDescription)
            await teardownSources()
        }
    }

    public func finish() async {
        guard phase == .recording || phase == .preparing else { return }
        phase = .finishing
        dismissEndPrompt()

        await teardownSources()
        // Publish the final accumulated timeline (the meters are throttled to ~15 Hz during
        // the meeting, so the last fraction of a second may not have been published yet).
        elapsed = scratchElapsed
        for service in services.values {
            await service.finish()
        }
        // The last results hop to the MainActor via ingest(); let those queued tasks land
        // before snapshotting `finals` for the definitive rebuild.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(400))

        // Final full-quality diarization pass, then one authoritative synchronous assemble so
        // the saved transcript below reflects it (the live rebuild is async/coalesced).
        let segments = await diarizer.finalPass()
        nameTrack.clearActive(at: elapsed)
        let (finalSegments, finalSpeakers) = assembler.assemble(
            finals: finals, speakerSegments: segments, nameSpans: nameTrack.snapshot(now: elapsed))
        applyRebuild(segments: finalSegments, speakers: finalSpeakers)

        await recorder?.finish()
        await stopScreenRecording()   // finalize the .mov before the meeting is saved

        meeting.state = .complete
        meeting.endedAt = Date()
        meeting.durationSec = elapsed
        meeting.hasRecording = recordAudio
        do {
            try await store.save(meeting)
            try await store.save(Transcript(segments: liveSegments), for: meeting.id)
        } catch {
            SKLog.error(.sessionSaveFailed, .session,
                        "Saving the finished meeting failed", error: error)
            phase = .failed("Saving failed: \(error.localizedDescription)")
            return
        }
        // Per-channel summary: the single most useful line when a meeting goes wrong.
        let micOK = channelHasAudio[.mic] == true, sysOK = channelHasAudio[.system] == true
        let sysSegs = liveSegments.filter { $0.source == .system }.count
        let micSegs = liveSegments.filter { $0.source == .mic }.count
        SKLog.info(.session, "Channels — mic had audio: \(micOK), system had audio: \(sysOK); "
                   + "segments mic=\(micSegs) system=\(sysSegs)")
        // Clock health: how far each channel's audio timeline advanced vs real wall time. A
        // channel whose cursor trails wall by a lot underran (dropped callbacks, or the machine
        // slept); a big mic-vs-system cursor gap is what makes the recorder drop the trailing
        // channel. This is the line that turns "why did audio go missing" into a number.
        let wall = Date().timeIntervalSince(meeting.createdAt)
        SKLog.info(.session, String(format:
            "Clock check — audio %.0fs over %.0fs wall; cursors mic=%.1fs system=%.1fs (gap %.1fs)",
            elapsed, wall, clock.position(of: .mic), clock.position(of: .system),
            abs(clock.position(of: .mic) - clock.position(of: .system))))
        SKLog.info(.session, String(format:
            "Pump time — recorder %.1fs, ASR %.1fs, diarizer %.1fs (over %.0fs processed; if these "
            + "sum near the wall time, per-chunk work is the throughput bottleneck)",
            Double(recorderNanos) / 1e9, Double(feedNanos) / 1e9, Double(diarizerNanos) / 1e9, elapsed))
        if !sysOK {
            // A whole-meeting silent system channel is only a real failure when the meeting
            // ran long enough that the remote almost certainly spoke. Under ~60s it is
            // indistinguishable from "the remote side simply stayed quiet", so do not cry wolf.
            if elapsed >= 60 {
                SKLog.error(.captureStalled, .capture,
                            "System channel produced NO audio across a \(Int(elapsed))s meeting — "
                            + "remote speakers will have been attributed to the microphone")
            } else {
                SKLog.info(.capture,
                           "System channel had no audio, but the meeting was only \(Int(elapsed))s "
                           + "— too short to conclude capture failed (the remote may just have been silent)")
            }
        }
        SKLog.endMeeting(title: meeting.title, durationSec: elapsed)
        phase = .idle
    }

    /// Assign a human name to a speaker key (S2 → "Kainat").
    public func nameSpeaker(key: String, name: String) async {
        meeting.speakers[key]?.name = name.isEmpty ? nil : name
        if name.isEmpty { userNamedKeys.remove(key) } else { userNamedKeys.insert(key) }
        try? await store.save(meeting)
    }

    /// Fed by the meeting-app speaker reader (Zoom Accessibility / Meet extension): "this named
    /// participant is the active speaker right now", or `nil` when nobody is (so the open span is
    /// closed and one speaker's name does not bleed onto the next). Stamped onto the transcript
    /// timeline and picked up by the next rebuild, so remote speakers show their real name.
    /// Assign the live meeting to a project folder so the copilot uses that project's memory.
    public func setFolder(_ folderId: UUID?) {
        meeting.folderId = folderId
    }

    public func noteActiveSpeaker(_ name: String?) {
        guard phase == .recording, !isPaused else { return }
        let t = clock.sessionTime()
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nameTrack.record(name: name, at: t)
        } else {
            nameTrack.clearActive(at: t)
        }
    }

    // MARK: - Screen recording (optional, on demand)

    public func startScreenRecording(filter: sending SCContentFilter? = nil, appScoped: Bool = true) async {
        guard phase == .recording, screenRecorder == nil else { return }
        // Use the source the user picked; else, when `appScoped`, scope to the meeting app's window
        // (Zoom → Zoom, Teams → Teams, Meet → the browser) from whichever registered app holds the
        // mic; else record the full display. The recorder falls back to full display if no window.
        let appBundleId = (filter == nil && appScoped)
            ? MeetingAppRegistry.meetingAppBundleId(amongRunning: MicActivity.bundleIdsUsingMic())
            : nil
        let recorder = ScreenVideoRecorder(outputURL: await store.screenRecordingURL(for: meeting.id))
        do {
            let scope = try await recorder.start(filter: filter, appBundleId: appBundleId)
            screenRecorder = recorder
            isRecordingScreen = true
            SKLog.info(.session, "Screen recording started (\(scope))")
        } catch {
            SKLog.error(.captureStartFailed, .capture, "Screen recording failed to start", error: error)
        }
    }

    public func stopScreenRecording() async {
        guard let recorder = screenRecorder else { return }
        screenRecorder = nil
        isRecordingScreen = false
        let ok = await recorder.stop()
        if ok {
            meeting.hasScreenRecording = true
            try? await store.save(meeting)
        }
        SKLog.info(.session, "Screen recording stopped (saved: \(ok))")
    }

    // MARK: - Pause / resume

    public func pause() {
        guard phase == .recording, !isPaused else { return }
        isPaused = true
        clock.setPaused(true)
        SKLog.info(.session, "Meeting paused")
    }

    public func resume() {
        guard phase == .recording, isPaused else { return }
        isPaused = false
        clock.setPaused(false)
        SKLog.info(.session, "Meeting resumed")
    }

    // MARK: - Pipeline plumbing

    // Debug: per-channel chunk counters (SKNOTE_DEBUG=1 prints periodic RMS to stderr).
    private var debugChunkCounts: [AudioChannel: Int] = [:]
    private static let debugEnabled =
        ProcessInfo.processInfo.environment["SKNOTE_DEBUG"] == "1"

    private func pump(_ chunk: AudioChunk, into service: TranscriptionService) async {
        // Durability first: the raw recording is the core artifact, so write it BEFORE the ASR
        // (which can be slow or stall) — a wedged transcriber must never be able to blank
        // recorded audio. Then feed the transcriber, then hand the diarizer its samples (a cheap
        // append; the heavy pass runs on `diarizationTask`). None block on diarization/assembly.
        let t0 = DispatchTime.now().uptimeNanoseconds
        await recorder?.append(chunk)
        let t1 = DispatchTime.now().uptimeNanoseconds
        await service.feed(chunk)
        let t2 = DispatchTime.now().uptimeNanoseconds
        if chunk.channel == .system {
            await diarizer.feed(chunk)
        }
        let t3 = DispatchTime.now().uptimeNanoseconds
        recorderNanos &+= t1 &- t0
        feedNanos &+= t2 &- t1
        diarizerNanos &+= t3 &- t2

        // Elapsed + live level tracking. Accumulate here; publish the @Observable meters at
        // ~15 Hz below so SwiftUI invalidation never throttles ingestion.
        scratchElapsed = max(scratchElapsed, chunk.endTime)
        if !chunk.samples.isEmpty {
            let rms = (chunk.samples.reduce(Float(0)) { $0 + $1 * $1 }
                       / Float(chunk.samples.count)).squareRoot()
            scratchLevels[chunk.channel] = max(rms, (scratchLevels[chunk.channel] ?? 0) * 0.8)
            if rms > 0.01, channelHasAudio[chunk.channel] != true {
                channelHasAudio[chunk.channel] = true
            }
            feedEndDetection(now: chunk.endTime, rms: rms)
        }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        if nowNanos &- lastMeterPublishNanos > 66_000_000 {   // ~15 Hz
            lastMeterPublishNanos = nowNanos
            elapsed = scratchElapsed
            levels = scratchLevels
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
            onFinalUtterance?(result.channel == .mic, result.text)
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

    /// Requests a transcript rebuild. The assemble is O(mic×system) and used to run on the main
    /// actor on every ASR final, saturating it on a busy call until ingestion backed up and the
    /// recorder dropped the meeting's tail. It now runs OFF the main actor, coalesced to at most
    /// one in flight over the latest data, so ingestion never blocks on it.
    private func rebuild(with speakerSegments: [SpeakerSegment]) {
        latestSpeakerSegments = speakerSegments
        guard !rebuildInFlight else { rebuildAgain = true; return }
        rebuildInFlight = true
        launchRebuild()
    }

    private func launchRebuild() {
        let finalsSnapshot = finals
        let segs = latestSpeakerSegments
        let nameSnapshot = nameTrack.snapshot(now: clock.sessionTime())
        let assembler = self.assembler
        // Low priority: the O(mic×system) assemble grows with the meeting and must yield to
        // real-time audio ingestion.
        Task.detached(priority: .utility) { [weak self] in
            let (segments, speakers) = assembler.assemble(
                finals: finalsSnapshot, speakerSegments: segs, nameSpans: nameSnapshot)
            await MainActor.run {
                guard let self else { return }
                // A finishing/failed meeting does its own authoritative final assemble; ignore
                // a late background result so it can't overwrite the final transcript.
                if self.phase == .recording {
                    self.applyRebuild(segments: segments, speakers: speakers)
                }
                if self.rebuildAgain {
                    self.rebuildAgain = false
                    self.launchRebuild()
                } else {
                    self.rebuildInFlight = false
                }
            }
        }
    }

    /// Applies an assembled transcript to observable state and autosaves. Main-actor, cheap.
    private func applyRebuild(segments: [TranscriptSegment], speakers: [String: SpeakerInfo]) {
        liveSegments = segments
        // Preserve any names the user already assigned mid-meeting; otherwise stamp the
        // machine owner's configured name onto the mic speaker.
        for (key, var info) in speakers {
            // User renames win over everything; otherwise keep the assembler's name (from the
            // meeting-app UI), and seed the mic owner's configured name when none is known.
            if userNamedKeys.contains(key), let existing = meeting.speakers[key]?.name {
                info.name = existing
            } else if info.name == nil, info.source == .mic, let userName {
                info.name = userName
            }
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
        diarizationTask?.cancel()
        diarizationTask = nil
        let tasks = pumpTasks
        pumpTasks = []

        // Stop each source on its OWN detached task: finishing a source's AsyncStream lets its
        // pump loop drain the buffered backlog and exit on its own. Detached and per-source so a
        // wedged capture API (SCStream.stopCapture can hang mid-call) can't stall the others or
        // hang finish().
        for source in sources {
            Task.detached { await source.stop() }
        }

        // Bounded drain: wait for the pump loops to finish draining, but a watchdog cancels them
        // after 8 s. Cancelling a pump Task makes its `for await` return, so `.value` resolves —
        // the group returns promptly whether the drain completed or the cap fired.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for t in tasks { _ = await t.value } }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                for t in tasks { t.cancel() }
            }
            _ = await group.next()
            group.cancelAll()
        }
        for task in tasks { task.cancel() }
    }
}
