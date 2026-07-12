import Foundation
import AVFoundation

/// Writes the meeting's mixed audio (mic + system, both 16 kHz mono) to an AAC .m4a file —
/// Granola discards audio; keeping it is one of our upgrades. Chunks from both channels are
/// summed into a single mono track (they're on the same session clock).
public actor RecordingWriter {
    private var file: AVAudioFile?
    private let url: URL
    /// Mix buffer keyed by absolute sample index on the session clock.
    private var pending: [Int: [Float]] = [:]
    private var writtenThrough = 0   // absolute sample index flushed to disk
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// How far behind the newest audio we keep unflushed (lets late chunks from the other
    /// channel still mix in). 2 s at 16 kHz.
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
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ chunk: AudioChunk) {
        guard file != nil else { return }
        let startSample = Int((chunk.startTime * 16_000).rounded())
        mix(chunk.samples, at: startSample)
        flush(upTo: latestSample() - holdbackSamples)
    }

    public func finish() {
        flush(upTo: latestSample())
        file = nil
    }

    // MARK: - Mixing

    /// Accumulate samples into 1024-sample blocks, summing overlaps from the two channels.
    private let blockSize = 1024

    private func mix(_ samples: [Float], at startSample: Int) {
        guard startSample >= writtenThrough else { return } // too late, already flushed
        var index = 0
        while index < samples.count {
            let absolute = startSample + index
            let block = absolute / blockSize
            let offset = absolute % blockSize
            var blockSamples = pending[block] ?? [Float](repeating: 0, count: blockSize)
            let count = min(blockSize - offset, samples.count - index)
            for i in 0..<count {
                blockSamples[offset + i] += samples[index + i]
            }
            pending[block] = blockSamples
            index += count
        }
    }

    private func latestSample() -> Int {
        ((pending.keys.max() ?? 0) + 1) * blockSize
    }

    private func flush(upTo limitSample: Int) {
        guard let file else { return }
        let limitBlock = limitSample / blockSize
        let blocks = pending.keys.filter { $0 < limitBlock }.sorted()
        for block in blocks {
            guard var samples = pending.removeValue(forKey: block) else { continue }
            // Soft clip.
            for i in samples.indices where abs(samples[i]) > 1.0 {
                samples[i] = samples[i] > 0 ? 1.0 : -1.0
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(blockSize)) else { continue }
            buf.frameLength = AVAudioFrameCount(blockSize)
            let dst = buf.floatChannelData![0]
            for i in 0..<blockSize { dst[i] = samples[i] }
            do { try file.write(from: buf) } catch {
                FileHandle.standardError.write(
                    Data("SKNoteTaker: recording write failed: \(error)\n".utf8))
            }
            writtenThrough = (block + 1) * blockSize
        }
    }
}
