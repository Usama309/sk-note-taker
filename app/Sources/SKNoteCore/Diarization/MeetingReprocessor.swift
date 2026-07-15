import Foundation

/// Rebuilds a finished meeting's transcript from its recording — the correct "redo speaker
/// detection": re-transcribe (fresh word timings) + re-diarize + re-assemble.
///
/// Segment-level re-attribution of the saved transcript can't fix under-splitting, because the
/// live pass already coalesced the system audio into long single-speaker blocks with no word
/// timings to split on. Reprocessing from audio regenerates those timings, so speaker changes
/// inside a block become real boundaries.
///
/// - New stereo recordings (mic-L / system-R): mic → S1, system → diarized S2/S3/… — clean.
/// - Legacy mono recordings: the single mix is treated as the system stream (best-effort; the
///   local speaker isn't separable from the remote mix).
public enum MeetingReprocessor {

    /// Captures finalized ASR results straight off the (synchronous) transcription callback —
    /// a lock, not a spawned task, so no result is lost to scheduling before we read them.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [TranscriptionResult] = []
        func add(_ r: TranscriptionResult) {
            guard r.isFinal else { return }
            lock.lock(); results.append(r); lock.unlock()
        }
        var finals: [TranscriptionResult] {
            lock.lock(); defer { lock.unlock() }; return results
        }
    }

    public static func reprocess(
        recordingURL: URL,
        chunkSeconds: Double = 0.5
    ) async throws -> (transcript: Transcript, speakers: [String: SpeakerInfo]) {
        let channels = try RecordingLoader.channels(at: recordingURL)
        try await TranscriptionService.ensureModel()

        let diarizer = DiarizationService()
        try await diarizer.prepare()

        var finals: [TranscriptionResult] = []
        // System channel → ASR + diarization.
        finals += try await transcribe(
            channels.system, channel: .system, chunkSeconds: chunkSeconds, diarizer: diarizer)
        // Mic channel (stereo only) → ASR, always S1.
        if let mic = channels.mic {
            finals += try await transcribe(
                mic, channel: .mic, chunkSeconds: chunkSeconds, diarizer: nil)
        }

        let speakerSegments = await diarizer.finalPass()
        let assembler = TranscriptAssembler()
        let (segments, speakers) = assembler.assemble(
            finals: finals, speakerSegments: speakerSegments)
        return (Transcript(segments: segments), speakers)
    }

    /// Feed one channel's samples through a TranscriptionService (and optionally the diarizer),
    /// returning its finalized results.
    private static func transcribe(
        _ samples: [Float], channel: AudioChannel, chunkSeconds: Double,
        diarizer: DiarizationService?
    ) async throws -> [TranscriptionResult] {
        guard samples.count > 8_000 else { return [] }
        let collector = Collector()
        let service = TranscriptionService(channel: channel)
        try await service.start { collector.add($0) }

        let chunkSize = max(1, Int(chunkSeconds * 16_000))
        var start = 0
        while start < samples.count {
            let end = min(start + chunkSize, samples.count)
            let chunk = AudioChunk(
                channel: channel, samples: Array(samples[start..<end]),
                startTime: Double(start) / 16_000)
            await service.feed(chunk)
            await diarizer?.feed(chunk)
            start = end
        }
        // finish() finalizes and DRAINS the transcriber's result stream (awaits the consumer),
        // so every final result has reached the collector by the time it returns.
        await service.finish()
        return collector.finals
    }
}
