import Foundation
import AVFoundation

/// Writes the meeting's audio to an AAC .m4a file — Granola discards audio; keeping it is one
/// of our upgrades. The two capture channels are kept SEPARATE as stereo: mic on the left,
/// system (remote participants) on the right. That isolation is what lets post-meeting speaker
/// detection re-diarize the clean remote stream — mixing them to mono pollutes diarization with
/// the local mic and its echo. Both channels are 16 kHz; they share the session clock.
///
/// FLUSH FRONTIER: the write frontier only advances to where EVERY still-active channel has
/// delivered audio (a staleness-guarded minimum), NOT the faster channel's position. The old
/// max-based frontier let the faster channel (system) drag the shared write cursor past the
/// slower one (mic), so a mic chunk that arrived a beat late was stamped "already flushed" and
/// silently dropped — the remote-plays-while-you-speak blank. A channel that stops delivering
/// for longer than the grace window stops gating the frontier (its side is zero-filled) so a
/// stopped or dead source can't freeze the writer or grow `pending` without bound.
public actor RecordingWriter {
    private var file: AVAudioFile?
    private let url: URL
    /// Per-channel sample buffers keyed by absolute block index on the session clock.
    private var pending: [AudioChannel: [Int: [Float]]] = [.mic: [:], .system: [:]]
    private var writtenThrough = 0   // absolute sample index flushed to disk
    /// Highest absolute sample index delivered per channel, and the monotonic time of the last
    /// delivery. Together they gate the flush frontier.
    private var producedThrough: [AudioChannel: Int] = [:]
    private var lastAppendNanos: [AudioChannel: UInt64] = [:]
    /// Samples discarded because they arrived behind the already-flushed frontier — with the
    /// min-frontier this should essentially never fire; kept as a loud backstop for a genuine
    /// clock regression.
    private var droppedLate: [AudioChannel: Int] = [.mic: 0, .system: 0]
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!

    /// Jitter slack kept unflushed below the frontier (handles slightly out-of-order arrival
    /// within a channel). 2 s at 16 kHz.
    private let holdbackSamples = 32_000
    /// A channel silent (no new samples) longer than this stops gating the flush frontier.
    private let staleAfterNanos: UInt64 = 6_000_000_000   // 6 s
    /// A channel whose delivered position falls this far behind the leading channel stops gating
    /// the frontier too — a safety valve so a chronically (not merely idle) slow channel can't
    /// grow `pending` without bound on a long call. It should only ever trip under a severe
    /// throughput failure; the drop-log makes that loud.
    private let maxLagSamples = 480_000   // 30 s at 16 kHz
    private let blockSize = 1024
    /// Monotonic nanosecond source; injectable so the staleness logic is deterministic in tests.
    private let now: @Sendable () -> UInt64

    public init(url: URL,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.url = url
        self.now = now
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
        // Both channels are expected (stereo). Marking them active-at-0 makes the frontier wait
        // for BOTH to deliver (up to the grace window) rather than letting whichever appends
        // first race the write cursor past the other's not-yet-delivered start.
        let t = now()
        producedThrough = [.mic: 0, .system: 0]
        lastAppendNanos = [.mic: t, .system: t]
    }

    public func append(_ chunk: AudioChunk) {
        guard file != nil else { return }
        let startSample = Int((chunk.startTime * 16_000).rounded())
        place(chunk.samples, channel: chunk.channel, at: startSample)
        let t = now()
        lastAppendNanos[chunk.channel] = t
        producedThrough[chunk.channel] =
            max(producedThrough[chunk.channel] ?? 0, startSample + chunk.samples.count)
        flush(upTo: flushableFrontier(now: t) - holdbackSamples)
    }

    public func finish() {
        // The meeting is over: drain to the furthest sample any channel reached, gaps zero-filled.
        flush(upTo: maxProducedSample())
        file = nil
        let sys = droppedLate[.system] ?? 0, mic = droppedLate[.mic] ?? 0
        if sys + mic > 0 {
            let msg = "Recording dropped late samples — mic \(String(format: "%.1f", Double(mic)/16_000))s, "
                + "system \(String(format: "%.1f", Double(sys)/16_000))s "
                + "(with the min-frontier this should be ~0; a large drop means either a real "
                + "session-clock regression OR a channel that ran >30s behind and hit the lag "
                + "safety-valve — the clock-check cursor gap tells which)"
            if sys + mic > holdbackSamples { SKLog.warn(.recording, msg) } else { SKLog.info(.recording, msg) }
        }
    }

    // MARK: - Frontier

    /// The furthest sample to which every still-ACTIVE channel has delivered. A channel that
    /// hasn't delivered within the grace window (stopped/dead) is excluded so it can't stall the
    /// frontier; a channel that has never delivered doesn't gate it either.
    private func flushableFrontier(now: UInt64) -> Int {
        let lead = producedThrough.values.max() ?? 0
        let active = producedThrough.filter { ch, pos in
            guard let t = lastAppendNanos[ch] else { return false }
            if now &- t > staleAfterNanos { return false }      // fully idle → stops gating
            if lead - pos > maxLagSamples { return false }      // chronically far behind → cap memory
            return true
        }
        if active.isEmpty { return maxProducedSample() }
        return active.values.min() ?? 0
    }

    private func maxProducedSample() -> Int {
        let fromProduced = producedThrough.values.max() ?? 0
        let micBlock = pending[.mic]?.keys.max() ?? -1
        let sysBlock = pending[.system]?.keys.max() ?? -1
        let fromPending = (max(micBlock, sysBlock) + 1) * blockSize
        return max(fromProduced, fromPending)
    }

    // MARK: - Placement

    /// Accumulate samples into 1024-sample blocks per channel (overlaps within a channel sum,
    /// which only happens on tiny chunk-boundary overlaps).
    private func place(_ samples: [Float], channel: AudioChannel, at startSample: Int) {
        guard startSample >= writtenThrough else {
            droppedLate[channel, default: 0] += samples.count   // backstop: a genuine regression
            return
        }
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

    /// Flush every contiguous block from the current write cursor up to (but not including)
    /// `limitSample`'s block. Missing blocks are written as silence so the recording timeline
    /// always matches sample indices — never compressed by a gap. O(blocks flushed).
    private func flush(upTo limitSample: Int) {
        guard let file, limitSample > writtenThrough else { return }
        let limitBlock = limitSample / blockSize
        var block = writtenThrough / blockSize
        while block < limitBlock {
            var mic = pending[.mic]?.removeValue(forKey: block)
                ?? [Float](repeating: 0, count: blockSize)
            var system = pending[.system]?.removeValue(forKey: block)
                ?? [Float](repeating: 0, count: blockSize)
            softClip(&mic)
            softClip(&system)
            if let buf = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(blockSize)) {
                buf.frameLength = AVAudioFrameCount(blockSize)
                let left = buf.floatChannelData![0], right = buf.floatChannelData![1]
                for i in 0..<blockSize { left[i] = mic[i]; right[i] = system[i] }
                do { try file.write(from: buf) } catch {
                    SKLog.error(.recordingWriteFailed, .recording,
                                "Failed to write a recording block — the saved audio will have a gap",
                                error: error)
                }
            }
            block += 1
            writtenThrough = block * blockSize
        }
    }

    private func softClip(_ samples: inout [Float]) {
        for i in samples.indices where abs(samples[i]) > 1.0 {
            samples[i] = samples[i] > 0 ? 1.0 : -1.0
        }
    }

    /// Samples dropped as "too late" for a channel (diagnostics / tests).
    public func droppedSampleCount(_ channel: AudioChannel) -> Int { droppedLate[channel] ?? 0 }
}
