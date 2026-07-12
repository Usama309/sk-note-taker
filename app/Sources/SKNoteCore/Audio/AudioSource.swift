import Foundation
import AVFoundation

/// A chunk of 16 kHz mono Float32 audio stamped with its position on the session clock.
public struct AudioChunk: Sendable {
    public let channel: AudioChannel
    public let samples: [Float]      // 16 kHz mono
    public let startTime: Double     // seconds from session start

    public init(channel: AudioChannel, samples: [Float], startTime: Double) {
        self.channel = channel
        self.samples = samples
        self.startTime = startTime
    }

    public var duration: Double { Double(samples.count) / 16_000 }
    public var endTime: Double { startTime + duration }
}

/// Abstraction over live capture (mic / system tap) and file playback (tests).
/// Implementations emit AudioChunks on their stream until stopped.
public protocol AudioSource: Sendable {
    var channel: AudioChannel { get }
    /// Starts capture. Chunks arrive on the returned stream; the stream finishes on stop().
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

public enum AudioSourceError: Error, LocalizedError {
    case permissionDenied(String)
    case deviceUnavailable(String)
    case fileUnreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): "Permission denied: \(what)"
        case .deviceUnavailable(let what): "Audio device unavailable: \(what)"
        case .fileUnreadable(let url): "Cannot read audio file \(url.lastPathComponent)"
        }
    }
}
