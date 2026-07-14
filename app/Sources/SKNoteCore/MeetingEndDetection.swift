import Foundation

/// Detects farewell talk in transcript text — the "okay, thanks, bye, take care" cluster that
/// ends most calls. Word-boundary matched so "bye" never fires inside "bystander".
public enum FarewellMatcher {
    /// Phrases that signal the call is wrapping up. English plus the Urdu farewells Saqib's
    /// calls actually end with (romanized, which is how the transcriber renders them).
    static let phrases: [String] = [
        "bye", "bye-bye", "goodbye", "good bye",
        "take care", "see you", "talk soon", "talk to you later",
        "thanks everyone", "thank you everyone", "thanks all",
        "have a good one", "have a good day", "have a good night", "have a great day",
        "catch you later", "khuda hafiz", "allah hafiz",
    ]

    private static let regex: NSRegularExpression = {
        let alternatives = phrases
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "\\b(\(alternatives))\\b", options: [.caseInsensitive])
    }()

    public static func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// Pure decision engine for meeting-END detection — the counterpart to
/// `MeetingDetectionEngine`. No I/O, fully unit-testable; `MeetingSession` feeds it and acts
/// on its verdicts.
///
/// Two triggers:
/// - **Silence**: no audio energy on any channel for `silenceTimeout`. Judged from RMS, not
///   from transcription — speech the transcriber can't understand (Urdu, crosstalk) still
///   counts as an active meeting.
/// - **Farewell**: a recent final utterance matched a farewell phrase and `farewellQuiet`
///   seconds of audio silence followed it.
///
/// All times are seconds on the session clock (monotonic while recording).
public struct MeetingEndEngine: Sendable {
    public enum Trigger: Equatable, Sendable {
        case silence(seconds: Double)
        case farewell
    }

    /// RMS at/above this counts as audio activity (same bar as the UI's channelHasAudio).
    public static let activityRMS: Float = 0.01

    public var silenceTimeout: Double
    public var farewellQuiet: Double
    /// A farewell only stays "hot" this long after it was spoken.
    public var farewellWindow: Double
    public var snoozeSeconds: Double

    private var lastAudioAt: Double?
    private var heardAnyAudio = false
    private var farewellAt: Double?
    private var prompted = false
    private var hasFired = false          // one prompt per meeting — "once is enough"
    private var snoozedUntil: Double = 0

    public init(silenceTimeout: Double = 120, farewellQuiet: Double = 20,
                farewellWindow: Double = 60, snoozeSeconds: Double = 300) {
        self.silenceTimeout = silenceTimeout
        self.farewellQuiet = farewellQuiet
        self.farewellWindow = farewellWindow
        self.snoozeSeconds = snoozeSeconds
    }

    /// Feed one audio chunk's RMS (any channel).
    public mutating func noteAudio(now: Double, rms: Float) {
        if rms >= Self.activityRMS {
            lastAudioAt = now
            heardAnyAudio = true
        }
    }

    /// Feed a transcription result (any channel, volatile or final) as proof the meeting is
    /// live. The remote participant's voice arrives on the system channel and is routinely
    /// transcribed BELOW the RMS activity gate (a listener on headphones / low volume), so
    /// transcription must reset the silence timer too — otherwise the client talking while
    /// the local user stays quiet reads as silence.
    public mutating func noteActivity(now: Double) {
        lastAudioAt = now
        heardAnyAudio = true
    }

    /// Feed one FINAL transcript utterance for farewell detection. Also counts as activity.
    public mutating func noteUtterance(now: Double, text: String) {
        noteActivity(now: now)
        if FarewellMatcher.matches(text) {
            farewellAt = now
        }
    }

    /// True while a prompt is outstanding (fired but not resolved).
    public var isPrompting: Bool { prompted }

    /// Evaluate the current state. Fires at most ONCE per meeting — after the single prompt
    /// the engine stays latched, so resumed-then-quiet audio never nags again.
    public mutating func evaluate(now: Double) -> Trigger? {
        guard !prompted, !hasFired, now >= snoozedUntil, heardAnyAudio,
              let lastAudioAt else { return nil }
        let quiet = now - lastAudioAt

        if let farewellAt, now - farewellAt <= farewellWindow, quiet >= farewellQuiet,
           lastAudioAt <= farewellAt + 2 {   // nobody spoke meaningfully after the farewell
            prompted = true; hasFired = true
            return .farewell
        }
        if quiet >= silenceTimeout {
            prompted = true; hasFired = true
            return .silence(seconds: quiet)
        }
        return nil
    }

    /// User chose "Keep Recording" / dismissed the prompt. Clears the outstanding banner but
    /// keeps the once-per-meeting latch — we won't prompt again this meeting.
    public mutating func snooze(now: Double) {
        prompted = false
        farewellAt = nil
        lastAudioAt = now
        snoozedUntil = now + snoozeSeconds
    }

    /// Audio/transcription resumed while the prompt/countdown was showing — the meeting
    /// clearly continues. Clears the banner; the latch still prevents a second prompt.
    public mutating func cancelPrompt(now: Double) {
        prompted = false
        farewellAt = nil
        lastAudioAt = now
    }
}
