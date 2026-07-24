import Foundation
import Testing
@testable import SKNoteCore

/// Regression tests for the "remote voices collapse onto the mic" bug (Jul 2026): the system
/// channel's per-channel cursor fell behind the mic after ScreenCaptureKit restart gaps, so
/// `RecordingWriter` dropped every later system sample as "too late" and the recording's system
/// channel came out digitally silent. Live capture must re-anchor a gapped channel to wall time.
@Suite("Session clock")
struct SessionClockTests {
    /// A controllable monotonic clock so tests don't depend on real time.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _t: Double = 0
        var t: Double {
            get { lock.withLock { _t } }
            set { lock.withLock { _t = newValue } }
        }
        func read() -> Double { t }
    }

    @Test("live: a channel idle through a gap re-anchors to wall time (not stuck behind)")
    func systemChannelResyncsAfterGap() {
        let fake = FakeClock()
        let clock = SessionClock(anchorToWallClock: true, now: { fake.read() })

        // Mic streams continuously for ~5 s (100 chunks of 50 ms), advancing wall in lockstep.
        var micStart = 0.0
        for _ in 0..<100 {
            micStart = clock.advance(channel: .mic, by: 0.05)
            fake.t += 0.05
        }
        #expect(abs(micStart - 4.95) < 1e-6)

        // The system channel produced nothing during those 5 s (a restart gap). Its first
        // chunk arrives at wall ≈ 5 s and MUST be stamped near 5 s so it lines up with the mic
        // frontier — not at ~0, which is what made the recorder discard all system audio.
        let sysStart = clock.advance(channel: .system, by: 0.05)
        #expect(sysStart > 4.9,
                "system chunk after a 5 s gap must re-anchor to wall time, got \(sysStart)")
    }

    @Test("live: steady state is smooth, gap-free accumulation (no jitter)")
    func steadyStateIsSmooth() {
        let fake = FakeClock()
        let clock = SessionClock(anchorToWallClock: true, now: { fake.read() })
        var starts: [Double] = []
        for _ in 0..<4 {
            starts.append(clock.advance(channel: .mic, by: 0.05))
            fake.t += 0.05
        }
        for (i, s) in starts.enumerated() {
            #expect(abs(s - Double(i) * 0.05) < 1e-6, "chunk \(i) start \(s)")
        }
    }

    @Test("offline: timestamps follow audio content, ignoring wall time")
    func offlineIgnoresWallClock() {
        let fake = FakeClock()
        let clock = SessionClock(now: { fake.read() })   // anchorToWallClock defaults false
        _ = clock.advance(channel: .system, by: 0.05)
        fake.t += 100                                     // huge wall jump (fast offline pass)
        let next = clock.advance(channel: .system, by: 0.05)
        #expect(abs(next - 0.05) < 1e-6,
                "offline reprocess must timestamp from audio content, not wall time, got \(next)")
    }

    @Test("pause freezes the timeline and excludes paused time on resume")
    func pauseFreezesAndExcludesTime() {
        let fake = FakeClock()
        let clock = SessionClock(anchorToWallClock: true, now: { fake.read() })
        var last = 0.0
        for _ in 0..<100 { last = clock.advance(channel: .mic, by: 0.05); fake.t += 0.05 }
        #expect(abs(last - 4.95) < 1e-6)              // reached ~5 s

        clock.setPaused(true)
        let frozen = clock.position(of: .mic)
        fake.t += 10                                  // 10 s of real time passes while paused
        let during = clock.advance(channel: .mic, by: 0.05)
        #expect(abs(during - frozen) < 1e-6, "paused advance must return the frozen cursor, got \(during)")

        clock.setPaused(false)
        let after = clock.advance(channel: .mic, by: 0.05)
        #expect(after < 5.2, "after resume the timeline continues from the pause point, not +10s, got \(after)")
    }
}
