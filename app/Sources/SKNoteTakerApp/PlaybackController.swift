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
        self.player = player
        duration = player.duration
        currentTime = 0
        ready = true
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
