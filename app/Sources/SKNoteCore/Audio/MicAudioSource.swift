import Foundation
import AVFoundation
import Synchronization

/// Live microphone capture via AVAudioEngine with Apple voice processing (echo cancellation +
/// noise suppression) so remote voices playing through the speakers don't bleed into this
/// stream. Emits 16 kHz mono chunks stamped against the shared session clock.
public final class MicAudioSource: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .mic

    private let engine = AVAudioEngine()
    private let clock: SessionClock
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

    public init(clock: SessionClock) {
        self.clock = clock
    }

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
        // AEC/noise suppression/AGC; must be set while the engine is stopped. Non-fatal if
        // unsupported on the current device — the raw signal still works.
        do { try input.setVoiceProcessingEnabled(true) } catch {
            FileHandle.standardError.write(Data("SKNoteTaker: voice processing unavailable: \(error)\n".utf8))
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioSourceError.deviceUnavailable("no microphone input")
        }

        let resampler = AudioResampler()
        let clock = self.clock
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            let samples = resampler.resample(buffer)
            guard !samples.isEmpty else { return }
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
