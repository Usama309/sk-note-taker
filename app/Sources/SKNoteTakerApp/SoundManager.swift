import AVFoundation
import AppKit

/// The app's three UI sounds: very soft, very short, and generated in code (no bundled audio, so
/// nothing to license). Off in one click via Settings.
///
/// Deliberately NOT exposed to the notes editor: notes autosave on every keystroke, so a "saved"
/// cue there would fire constantly. `noteSaved` is only for deliberate saves (speaker names,
/// project memory, a finished import). That is the "never during typing" rule, enforced by which
/// call sites exist rather than by a debounce that could drift.
@MainActor
final class SoundManager {
    static let shared = SoundManager()

    /// Mirrors AppSettings.uiSounds; the app pushes changes here so playback stays a cheap check.
    var enabled = true

    private var players: [Cue: AVAudioPlayer] = [:]

    enum Cue {
        case noteSaved
        case recordingStarted
        case recordingStopped
    }

    private init() {}

    func play(_ cue: Cue) {
        guard enabled else { return }
        let player: AVAudioPlayer?
        if let cached = players[cue] {
            player = cached
        } else {
            player = Self.makePlayer(for: cue)
            players[cue] = player
        }
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: Tone synthesis

    /// Each cue is a short sine blip (or two, for the record cues) with a quick fade in and out so
    /// there is no click. Peak amplitude stays low: these should sit under a conversation.
    private static func makePlayer(for cue: Cue) -> AVAudioPlayer? {
        let tones: [(freq: Double, start: Double, length: Double)]
        let total: Double
        switch cue {
        case .noteSaved:
            tones = [(1_320, 0, 0.085)]
            total = 0.11
        case .recordingStarted:
            tones = [(660, 0, 0.075), (990, 0.075, 0.105)]
            total = 0.20
        case .recordingStopped:
            tones = [(880, 0, 0.075), (587, 0.075, 0.115)]
            total = 0.21
        }

        let rate = 44_100.0
        let frames = Int(total * rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { channel[i] = 0 }

        let peak: Float = 0.16   // soft on purpose
        for tone in tones {
            let start = Int(tone.start * rate)
            let count = Int(tone.length * rate)
            let fade = max(1, Int(0.012 * rate))   // 12ms in/out, kills the click
            for n in 0..<count where start + n < frames {
                let t = Double(n) / rate
                var envelope = 1.0
                if n < fade { envelope = Double(n) / Double(fade) }
                if n > count - fade { envelope = Double(count - n) / Double(fade) }
                let value = sin(2 * .pi * tone.freq * t) * envelope
                channel[start + n] += Float(value) * peak
            }
        }

        // AVAudioPlayer wants a file, so write the buffer to a temporary WAV once per cue.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sknote-cue-\(String(describing: cue)).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.5
            player.prepareToPlay()
            return player
        } catch {
            return nil
        }
    }
}
