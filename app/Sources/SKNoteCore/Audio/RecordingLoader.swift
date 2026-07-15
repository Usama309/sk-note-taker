import Foundation
import AVFoundation

/// Loads a saved meeting recording back into 16 kHz float samples for re-diarization.
public enum RecordingLoader {

    /// Both capture channels at 16 kHz. `mic` is nil for legacy mono recordings; `system`
    /// is the right channel for stereo, or the single mix for mono.
    public static func channels(at url: URL) throws -> (mic: [Float]?, system: [Float]) {
        let per = try load(url)
        if per.count >= 2 { return (per[0], per[1]) }
        return (nil, per[0])
    }

    /// The audio to feed the diarizer for post-meeting speaker detection.
    ///
    /// - New stereo recordings (mic-L / system-R): returns the **system** channel alone — the
    ///   clean remote stream, free of the local mic and its echo.
    /// - Legacy mono recordings: returns the single mixed channel (best-effort).
    public static func systemChannel(at url: URL) throws -> (samples: [Float], isStereo: Bool) {
        let per = try load(url)
        if per.count >= 2 { return (per[1], true) }
        return (per[0], false)
    }

    /// Decode every channel of the file to 16 kHz float arrays.
    private static func load(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let channels = file.processingFormat.channelCount
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw NSError(domain: "RecordingLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot open \(url.lastPathComponent) at 16 kHz"])
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)!
        var perChannel = [[Float]](repeating: [], count: Int(channels))
        var done = false
        while !done {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32_768) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                inBuf.frameLength = 0
                try? file.read(into: inBuf, frameCount: 32_768)
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if convError != nil { break }
            if outBuf.frameLength > 0 {
                for ch in 0..<Int(channels) {
                    perChannel[ch].append(contentsOf: UnsafeBufferPointer(
                        start: outBuf.floatChannelData![ch], count: Int(outBuf.frameLength)))
                }
            }
            done = status == .endOfStream || (status == .haveData && outBuf.frameLength == 0)
        }
        return perChannel
    }
}
