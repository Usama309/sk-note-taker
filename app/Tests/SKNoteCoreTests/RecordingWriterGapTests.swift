import Foundation
import Testing
@testable import SKNoteCore

/// Regression tests for the "remote plays while you speak → your mic goes blank in the recording"
/// bug (Jul 2026). Root cause: the RecordingWriter advanced a single shared write frontier to the
/// FASTER channel's position (`latestSample()` used `max`), so a mic chunk that arrived a beat
/// after the system channel was stamped "already flushed" and silently dropped. The fix is a
/// staleness-guarded MIN frontier plus a drain-everything finish().
@Suite("Recording writer — no channel is dropped when the other leads")
struct RecordingWriterGapTests {
    final class FakeNanos: @unchecked Sendable {
        private let lock = NSLock(); private var v: UInt64 = 0
        var value: UInt64 { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    static func tone(_ seconds: Double = 0.1) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { 0.3 * sinf(2 * .pi * 440 * Float($0) / 16_000) }
    }
    static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }
    static func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-rw-\(UUID().uuidString).m4a")
    }

    @Test("a channel that arrives after the other leads is NOT dropped (the mic-blank bug)")
    func laggingChannelIsRetained() async throws {
        let url = Self.tmpURL(); defer { try? FileManager.default.removeItem(at: url) }
        let writer = RecordingWriter(url: url)
        try await writer.start()
        let tone = Self.tone()
        // System is appended across 0..8s FIRST (it leads), then mic across 0..8s (arrives late).
        // The old max-frontier dragged the write cursor to 8s on the system pass and dropped the
        // whole mic pass; the min-frontier holds until both have delivered.
        for i in 0..<80 {
            await writer.append(AudioChunk(channel: .system, samples: tone, startTime: Double(i) * 0.1))
        }
        for i in 0..<80 {
            await writer.append(AudioChunk(channel: .mic, samples: tone, startTime: Double(i) * 0.1))
        }
        await writer.finish()

        let (micOpt, system) = try RecordingLoader.channels(at: url)
        let mic = micOpt ?? []
        #expect(Self.rms(mic) > 0.05, "mic must be retained despite arriving after system, rms \(Self.rms(mic))")
        #expect(Self.rms(system) > 0.05, "system retained, rms \(Self.rms(system))")
        #expect(await writer.droppedSampleCount(.mic) == 0, "no mic samples should be dropped")
    }

    @Test("finish() drains the tail after the other channel stops (missing-tail bug)")
    func tailIsRecordedAfterOtherChannelStops() async throws {
        let url = Self.tmpURL(); defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeNanos()
        let writer = RecordingWriter(url: url, now: { fake.value })
        try await writer.start()
        let tone = Self.tone()
        // Both channels 0..5s.
        for i in 0..<50 {
            fake.value = UInt64(Double(i) * 0.1 * 1e9)
            await writer.append(AudioChunk(channel: .system, samples: tone, startTime: Double(i) * 0.1))
            await writer.append(AudioChunk(channel: .mic, samples: tone, startTime: Double(i) * 0.1))
        }
        // System stops; mic continues 5..15s. Advancing the injected clock past the 6s stale
        // window means the dead system channel stops gating the frontier.
        for i in 50..<150 {
            fake.value = UInt64(Double(i) * 0.1 * 1e9)
            await writer.append(AudioChunk(channel: .mic, samples: tone, startTime: Double(i) * 0.1))
        }
        await writer.finish()

        let (micOpt, _) = try RecordingLoader.channels(at: url)
        let mic = micOpt ?? []
        #expect(Double(mic.count) / 16_000 > 14, "mic should be ~15s, got \(Double(mic.count) / 16_000)s")
        #expect(Self.rms(Array(mic.suffix(16_000 * 4))) > 0.05, "the mic tail after system stopped must be recorded")
    }

    @Test("a chunk genuinely far behind the write frontier is still dropped + counted (backstop)")
    func genuineRegressionIsDropped() async throws {
        let url = Self.tmpURL(); defer { try? FileManager.default.removeItem(at: url) }
        let writer = RecordingWriter(url: url)
        try await writer.start()
        let tone = Self.tone()
        for i in 0..<100 {   // drive both to ~10s so the frontier flushes past ~8s
            await writer.append(AudioChunk(channel: .mic, samples: tone, startTime: Double(i) * 0.1))
            await writer.append(AudioChunk(channel: .system, samples: tone, startTime: Double(i) * 0.1))
        }
        let before = await writer.droppedSampleCount(.mic)
        await writer.append(AudioChunk(channel: .mic, samples: tone, startTime: 1.0)) // way behind
        let after = await writer.droppedSampleCount(.mic)
        #expect(after > before, "a chunk far behind the flushed frontier must be dropped and counted")
        await writer.finish()
    }
}
