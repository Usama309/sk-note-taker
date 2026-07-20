import Foundation
import AVFoundation
import Synchronization

/// Live microphone capture via AVAudioEngine. Emits 16 kHz mono chunks stamped against the
/// shared session clock.
///
/// NOTE on voice processing: `setVoiceProcessingEnabled(true)` turns the input node into a
/// duplex VPIO unit that only delivers input buffers while the engine's OUTPUT render chain
/// is also active. We capture input only (no output graph), so enabling it yields pure
/// silence — the original v1 bug. We therefore default to the raw input tap. Echo isn't a
/// problem in practice: the system-audio tap is a clean digital signal captured separately,
/// and headphone users have no acoustic bleed. `voiceProcessing: true` is kept for
/// experimentation but wires up a silent output tap so VPIO actually renders.
public final class MicAudioSource: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .mic

    private let engine = AVAudioEngine()
    private let clock: SessionClock
    private let voiceProcessing: Bool
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    /// Last chunk RMS, for a live input-level meter in the UI.
    private let lastLevel = Mutex<Float>(0)

    public init(clock: SessionClock, voiceProcessing: Bool = false) {
        self.clock = clock
        self.voiceProcessing = voiceProcessing
    }

    /// 0…1 RMS level of the most recent mic chunk (for a UI meter).
    public var inputLevel: Float { lastLevel.withLock { $0 } }

    public static func permissionGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.permissionGranted() else {
            throw AudioSourceError.permissionDenied("microphone")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }

        let input = engine.inputNode
        if voiceProcessing {
            // Only safe with an active output render chain (see type doc). Wire the input
            // through the main mixer to a silent output so VPIO actually renders.
            do {
                try input.setVoiceProcessingEnabled(true)
                let mixer = engine.mainMixerNode
                engine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
                engine.mainMixerNode.outputVolume = 0   // don't echo the mic to speakers
            } catch {
                SKLog.error(.micStartFailed, .mic, "Voice processing unavailable on the mic input — echo cancellation is off", error: error)
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.deviceUnavailable("no microphone input (format \(format))")
        }

        let resampler = AudioResampler()
        let clock = self.clock
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            let samples = resampler.resample(buffer)
            guard !samples.isEmpty else { return }
            let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            lastLevel.withLock { $0 = rms }
            let duration = Double(samples.count) / AudioResampler.targetRate
            let start = clock.advance(channel: .mic, by: duration)
            state.withLock { $0 }?.yield(
                AudioChunk(channel: .mic, samples: samples, startTime: start))
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
    }
}

/// Shared session clock. Each channel advances its own cursor by the audio it has produced,
/// anchored to a common start — keeps mic and system timelines aligned for diarization merge.
public final class SessionClock: Sendable {
    private let cursors = Mutex<[AudioChannel: Double]>([:])

    public init() {}

    /// Returns the chunk's start time and advances the channel cursor.
    public func advance(channel: AudioChannel, by duration: Double) -> Double {
        cursors.withLock { c in
            let start = c[channel] ?? 0
            c[channel] = start + duration
            return start
        }
    }

    public func position(of channel: AudioChannel) -> Double {
        cursors.withLock { $0[channel] ?? 0 }
    }

    public var elapsed: Double {
        cursors.withLock { $0.values.max() ?? 0 }
    }
}
