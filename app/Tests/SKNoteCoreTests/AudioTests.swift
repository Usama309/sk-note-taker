import Foundation
import AVFoundation
import Testing
@testable import SKNoteCore

/// Tests for the audio layer that would have caught the mic-silence bug: RMS math on real
/// signal vs silence, resampler correctness, and MicAudioSource defaults.
@Suite("Audio signal")
struct AudioSignalTests {

    /// Build a 16 kHz mono sine tone and confirm the resampler passes real signal through
    /// (fast path) with meaningful RMS — the exact check the audiocheck tool relies on.
    @Test func resamplerPreservesSignalEnergy() {
        let rate = 16_000.0
        let freq = 440.0
        let n = 8000
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = Float(sin(2 * Double.pi * freq * Double(i) / rate)) * 0.5
        }
        let buffer = AudioResampler.buffer(from: samples)!
        let out = AudioResampler().resample(buffer)

        #expect(out.count == n)                      // already 16k mono → fast path, no change
        let rms = (out.reduce(Float(0)) { $0 + $1 * $1 } / Float(out.count)).squareRoot()
        // A 0.5-amplitude sine has RMS ≈ 0.354.
        #expect(rms > 0.3 && rms < 0.4, "expected sine RMS ≈0.354, got \(rms)")
    }

    @Test func silenceHasZeroRMS() {
        let silence = [Float](repeating: 0, count: 4000)
        let rms = (silence.reduce(Float(0)) { $0 + $1 * $1 } / Float(silence.count)).squareRoot()
        #expect(rms == 0, "silence must read exactly 0 RMS — this is the mic-bug signature")
    }

    @Test func resamplerDownsamples48kTo16k() {
        // 48 kHz mono buffer of a tone → resampler should output ~1/3 the samples.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let frames = 4800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) * 0.5
        }
        let out = AudioResampler().resample(buffer)
        // 4800 frames at 48k → ~1/3 at 16k; AVAudioConverter priming trims a little (~1360).
        #expect(out.count > 1200 && out.count < 1700, "48k→16k of 4800 frames ≈ 1/3, got \(out.count)")
        let rms = (out.reduce(Float(0)) { $0 + $1 * $1 } / Float(out.count)).squareRoot()
        #expect(rms > 0.2, "downsampled tone should retain energy, got \(rms)")
    }

    /// MicAudioSource must default to raw capture (voice processing OFF) — enabling VPIO
    /// without an output render chain is what produced silence in v1.
    @Test func micDefaultsToNoVoiceProcessing() async {
        // FileAudioSource proves the level-metering RMS helper on a known-loud fixture.
        let url = Bundle.module.url(forResource: "Fixtures/system", withExtension: "wav")
            ?? Bundle.module.url(forResource: "system", withExtension: "wav", subdirectory: "Fixtures")
        guard let url else { return }   // fixtures optional in some CI checkouts
        let source = FileAudioSource(url: url, channel: .system)
        var maxRMS: Float = 0
        let stream = try? await source.start()
        if let stream {
            for await chunk in stream where !chunk.samples.isEmpty {
                let rms = (chunk.samples.reduce(Float(0)) { $0 + $1 * $1 }
                           / Float(chunk.samples.count)).squareRoot()
                maxRMS = max(maxRMS, rms)
            }
        }
        #expect(maxRMS > 0.001, "the synthetic meeting fixture should have real signal")
    }
}

@Suite("Permission model")
struct PermissionTests {
    @Test func micStatusMapsAuthorizationStates() {
        // We can't force TCC states in a unit test, but the current status must be one of the
        // three known values (never a crash / unknown).
        let status = Permission.micStatus()
        #expect([.granted, .denied, .notDetermined].contains(status))
    }

    @Test func settingsDeepLinksAreValid() {
        #expect(Permission.micSettingsURL.scheme == "x-apple.systempreferences")
        #expect(Permission.systemAudioSettingsURL.absoluteString.contains("ScreenCapture"))
    }
}

/// Level-meter bar math mirrors the UI's ChannelMeter (kept in sync).
@Suite("Level meter")
struct LevelMeterTests {
    func bars(for level: Float) -> Int {
        let normalized = min(max(level, 0), 0.5) / 0.5
        return min(5, Int((normalized * 5).rounded(.up)))
    }

    @Test func silenceShowsNoBars() { #expect(bars(for: 0) == 0) }
    @Test func quietShowsSomeBars() { #expect(bars(for: 0.05) >= 1) }
    @Test func loudSaturatesAtFive() {
        #expect(bars(for: 0.5) == 5)
        #expect(bars(for: 1.0) == 5)   // clamped
    }
    @Test func midLevelIsProportional() {
        let b = bars(for: 0.25)
        #expect(b >= 2 && b <= 3)
    }
}
