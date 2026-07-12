import Foundation
import AVFoundation

/// Converts arbitrary-format AVAudioPCMBuffers to 16 kHz mono Float32 sample arrays.
/// One instance per input stream (the converter is stateful across calls).
public final class AudioResampler: @unchecked Sendable {
    public static let targetRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!
    private let lock = NSLock()

    public init() {}

    public func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }

        // Fast path: already 16k mono float.
        if buffer.format == outputFormat, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var served = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if served {
                outStatus.pointee = .noDataNow
                return nil
            }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        if convError != nil { return [] }
        guard let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Builds an AVAudioPCMBuffer (16k mono) from raw samples — for feeding APIs that want buffers.
    public static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
