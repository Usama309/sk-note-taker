import Foundation
import AVFoundation
import Synchronization

/// Reads a WAV/M4A file and emits it as chunks on the session clock — the test double for
/// live capture. `realtime: false` pushes the whole file as fast as possible;
/// `realtime: true` paces chunks at playback speed (for live-UI demos).
public final class FileAudioSource: AudioSource, Sendable {
    public let channel: AudioChannel
    private let url: URL
    private let realtime: Bool
    private let chunkSeconds: Double
    private let isStopped = Mutex(false)

    public init(url: URL, channel: AudioChannel, realtime: Bool = false, chunkSeconds: Double = 0.5) {
        self.url = url
        self.channel = channel
        self.realtime = realtime
        self.chunkSeconds = chunkSeconds
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AudioSourceError.fileUnreadable(url)
        }
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let channel = self.channel
        let realtime = self.realtime
        let chunkSeconds = self.chunkSeconds

        Task.detached { [self] in
            let resampler = AudioResampler()
            let framesPerChunk = AVAudioFrameCount(file.processingFormat.sampleRate * chunkSeconds)
            var clock: Double = 0

            while !isStopped.withLock({ $0 }) {
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: framesPerChunk) else { break }
                do { try file.read(into: buf, frameCount: framesPerChunk) } catch { break }
                if buf.frameLength == 0 { break }

                let samples = resampler.resample(buf)
                if !samples.isEmpty {
                    continuation.yield(AudioChunk(channel: channel, samples: samples, startTime: clock))
                    clock += Double(samples.count) / AudioResampler.targetRate
                }
                if realtime {
                    try? await Task.sleep(for: .seconds(chunkSeconds))
                }
                if buf.frameLength < framesPerChunk { break } // EOF
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() async {
        isStopped.withLock { $0 = true }
    }
}
