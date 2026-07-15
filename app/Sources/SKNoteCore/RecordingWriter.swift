import Foundation
import AVFoundation

/// Writes the meeting's audio to an AAC .m4a file — Granola discards audio; keeping it is one
/// of our upgrades. The two capture channels are kept SEPARATE as stereo: mic on the left,
/// system (remote participants) on the right. That isolation is what lets post-meeting speaker
/// detection re-diarize the clean remote stream — mixing them to mono pollutes diarization with
/// the local mic and its echo. Both channels are 16 kHz; they share the session clock.
public actor RecordingWriter {
    private var file: AVAudioFile?
    private let url: URL
    /// Per-channel sample buffers keyed by absolute sample index on the session clock.
    private var pending: [AudioChannel: [Int: [Float]]] = [.mic: [:], .system: [:]]
    private var writtenThrough = 0   // absolute sample index flushed to disk
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!

    /// How far behind the newest audio we keep unflushed (lets late chunks from the other
    /// channel still line up). 2 s at 16 kHz.
    private let holdbackSamples = 32_000

    public init(url: URL) {
        self.url = url
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ chunk: AudioChunk) {
        guard file != nil else { return }
        let startSample = Int((chunk.startTime * 16_000).rounded())
        place(chunk.samples, channel: chunk.channel, at: startSample)
        flush(upTo: latestSample() - holdbackSamples)
    }

    public func finish() {
        flush(upTo: latestSample())
        file = nil
    }

    // MARK: - Placement

    /// Accumulate samples into 1024-sample blocks per channel (overlaps within a channel sum,
    /// which only happens on tiny chunk-boundary overlaps).
    private let blockSize = 1024

    private func place(_ samples: [Float], channel: AudioChannel, at startSample: Int) {
        guard startSample >= writtenThrough else { return } // too late, already flushed
        var index = 0
        while index < samples.count {
            let absolute = startSample + index
            let block = absolute / blockSize
            let offset = absolute % blockSize
            var blockSamples = pending[channel]?[block] ?? [Float](repeating: 0, count: blockSize)
            let count = min(blockSize - offset, samples.count - index)
            for i in 0..<count {
                blockSamples[offset + i] += samples[index + i]
            }
            pending[channel]?[block] = blockSamples
            index += count
        }
    }

    private func latestSample() -> Int {
        let micMax = pending[.mic]?.keys.max() ?? -1
        let sysMax = pending[.system]?.keys.max() ?? -1
        return (max(micMax, sysMax) + 1) * blockSize
    }

    private func flush(upTo limitSample: Int) {
        guard let file else { return }
        let limitBlock = limitSample / blockSize
        let blocks = Set((pending[.mic]?.keys ?? [:].keys))
            .union(pending[.system]?.keys ?? [:].keys)
            .filter { $0 < limitBlock }
            .sorted()
        for block in blocks {
            var mic = pending[.mic]?.removeValue(forKey: block)
                ?? [Float](repeating: 0, count: blockSize)
            var system = pending[.system]?.removeValue(forKey: block)
                ?? [Float](repeating: 0, count: blockSize)
            softClip(&mic)
            softClip(&system)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(blockSize)) else { continue }
            buf.frameLength = AVAudioFrameCount(blockSize)
            let left = buf.floatChannelData![0], right = buf.floatChannelData![1]
            for i in 0..<blockSize { left[i] = mic[i]; right[i] = system[i] }
            do { try file.write(from: buf) } catch {
                FileHandle.standardError.write(
                    Data("SKNoteTaker: recording write failed: \(error)\n".utf8))
            }
            writtenThrough = (block + 1) * blockSize
        }
    }

    private func softClip(_ samples: inout [Float]) {
        for i in samples.indices where abs(samples[i]) > 1.0 {
            samples[i] = samples[i] > 0 ? 1.0 : -1.0
        }
    }
}
