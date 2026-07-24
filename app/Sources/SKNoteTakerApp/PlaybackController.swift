import Foundation
import AVFoundation
import AppKit
import Observation

/// Wraps AVAudioPlayer for the meeting-recording player bar: play/pause, scrubbing,
/// playback speed, and a Finder reveal. Owned per MeetingDetailView.
@Observable
@MainActor
final class PlaybackController {
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    private(set) var ready = false
    private(set) var playing = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1.0 {
        didSet { if playing { player?.rate = rate } }
    }
    var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }
    /// Normalized 0…1 amplitude bars for the WhatsApp-style waveform (computed off-thread).
    private(set) var waveform: [Float] = []
    private(set) var url: URL?

    func load(url: URL) {
        guard self.url != url else { return }
        stop()
        self.url = url
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            ready = false
            return
        }
        player.enableRate = true
        player.volume = volume
        self.player = player
        duration = player.duration
        currentTime = 0
        ready = true
        waveform = []
        Task { [weak self] in
            let bars = await Self.computeWaveform(url: url, bins: 88)
            await MainActor.run { if self?.url == url { self?.waveform = bars } }
        }
    }

    /// Reads the recording off the main thread and reduces it to `bins` normalized peak bars.
    nonisolated static func computeWaveform(url: URL, bins: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard bins > 0, let file = try? AVAudioFile(forReading: url) else { return [] }
            let total = file.length
            guard total > 0 else { return [] }
            let framesPerBin = max(1, Int(total) / bins)
            var peaks = [Float](repeating: 0, count: bins)
            let cap = AVAudioFrameCount(min(Int(total), 65_536))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap)
            else { return [] }
            var pos = 0
            while file.framePosition < total {
                guard (try? file.read(into: buf)) != nil, buf.frameLength > 0,
                      let ch = buf.floatChannelData else { break }
                let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
                for i in 0..<n {
                    var amp: Float = 0
                    for c in 0..<channels { amp = max(amp, abs(ch[c][i])) }
                    let bin = min(bins - 1, (pos + i) / framesPerBin)
                    if amp > peaks[bin] { peaks[bin] = amp }
                }
                pos += n
            }
            let maxPeak = peaks.max() ?? 0
            if maxPeak > 0 { for i in peaks.indices { peaks[i] = min(1, peaks[i] / maxPeak) } }
            return peaks
        }.value
    }

    func toggle() {
        playing ? pause() : play()
    }

    func play() {
        guard let player else { return }
        player.rate = rate
        player.play()
        playing = true
        startTicker()
    }

    func pause() {
        player?.pause()
        playing = false
        stopTicker()
        currentTime = player?.currentTime ?? currentTime
    }

    /// Jump to a moment (e.g. a transcript timestamp) and start playing from there.
    func seek(to time: Double, andPlay: Bool = false) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, duration - 0.1))
        currentTime = player.currentTime
        if andPlay, !playing { play() }
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func stop() {
        player?.stop()
        player = nil
        stopTicker()
        playing = false
        ready = false
        currentTime = 0
        duration = 0
        url = nil
    }

    private func startTicker() {
        stopTicker()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {          // reached the end
            playing = false
            stopTicker()
        }
    }
}
