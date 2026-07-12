import Foundation
import AVFoundation
import Testing
@testable import SKNoteCore

/// Debug harness: diarize an arbitrary audio file and print the speaker timeline.
/// Run: SKNOTE_DIARIZE_FILE=/path/to/audio.m4a swift test --filter DiarizeFileDebug
@Suite("DiarizeFileDebug",
       .enabled(if: ProcessInfo.processInfo.environment["SKNOTE_DIARIZE_FILE"] != nil))
struct DiarizeFileDebugTest {
    @Test(.timeLimit(.minutes(10)))
    func diarizeFile() async throws {
        let path = ProcessInfo.processInfo.environment["SKNOTE_DIARIZE_FILE"]!
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let resampler = AudioResampler()
        var samples: [Float] = []
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.5)
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: frames) else { break }
            try file.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            samples.append(contentsOf: resampler.resample(buf))
            if buf.frameLength < frames { break }
        }
        print("DIARIZE_DEBUG loaded \(Double(samples.count) / 16_000)s")

        let threshold = Float(ProcessInfo.processInfo
            .environment["SKNOTE_DIARIZE_THRESHOLD"] ?? "") ?? 0.6
        print("DIARIZE_DEBUG threshold \(threshold)")
        let service = DiarizationService(clusteringThreshold: threshold)
        try await service.prepare()
        await service.feed(AudioChunk(channel: .system, samples: samples, startTime: 0))
        let segments = await service.finalPass()
        print("DIARIZE_DEBUG segments:")
        for seg in segments {
            print(String(format: "DIARIZE_DEBUG   %@ %.1f-%.1f",
                         seg.speakerId, seg.start, seg.end))
        }
        let speakers = Set(segments.map(\.speakerId))
        print("DIARIZE_DEBUG distinct speakers: \(speakers.sorted())")
    }
}
