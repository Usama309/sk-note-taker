import Foundation
import Observation

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

    public init(title: String, store: MeetingStore, sources: [any AudioSource],
                clock: SessionClock, recordAudio: Bool = true) {
        self.meeting = Meeting(title: title)
        self.store = store
        self.sources = sources
        self.clock = clock
        self.recordAudio = recordAudio
    }

    /// Convenience: live meeting with mic + system tap on a fresh clock.
    public static func live(title: String, store: MeetingStore) -> MeetingSession {
        let clock = SessionClock()
        return MeetingSession(
            title: title, store: store,
            sources: [MicAudioSource(clock: clock), SystemAudioSource(clock: clock)],
            clock: clock)
    }

    // MARK: - Lifecycle

    public func start() async {
        phase = .preparing
        do {
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

        await teardownSources()
        for service in services.values {
            await service.finish()
        }

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

    private func pump(_ chunk: AudioChunk, into service: TranscriptionService) async {
        // Elapsed time comes from the audio itself (works for live and file sources alike).
        elapsed = max(elapsed, chunk.endTime)
        await service.feed(chunk)
        if chunk.channel == .system {
            await diarizer.feed(chunk)
            if let refreshed = await diarizer.incrementalPass() {
                rebuild(with: refreshed)
            }
        }
        await recorder?.append(chunk)
    }

    private func ingest(_ result: TranscriptionResult) {
        if result.isFinal {
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
