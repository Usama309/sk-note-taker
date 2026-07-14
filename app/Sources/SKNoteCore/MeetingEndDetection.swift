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

    /// Feed one FINAL transcript utterance.
    public mutating func noteUtterance(now: Double, text: String) {
        if FarewellMatcher.matches(text) {
            farewellAt = now
        }
    }

    /// True while a prompt is outstanding (fired but not resolved).
    public var isPrompting: Bool { prompted }

    /// Evaluate the current state. Returns a trigger at most once; the engine then holds
    /// until `snooze` (user keeps recording) or `cancelPrompt` (audio resumed).
    public mutating func evaluate(now: Double) -> Trigger? {
        guard !prompted, now >= snoozedUntil, heardAnyAudio, let lastAudioAt else { return nil }
        let quiet = now - lastAudioAt

        if let farewellAt, now - farewellAt <= farewellWindow, quiet >= farewellQuiet,
           lastAudioAt <= farewellAt + 2 {   // nobody spoke meaningfully after the farewell
            prompted = true
            return .farewell
        }
        if quiet >= silenceTimeout {
            prompted = true
            return .silence(seconds: quiet)
        }
        return nil
    }

    /// User chose "Keep Recording" (or the grace period should not re-fire immediately):
    /// suppress for `snoozeSeconds` and require fresh evidence.
    public mutating func snooze(now: Double) {
        prompted = false
        farewellAt = nil
        lastAudioAt = now          // silence countdown restarts from here
        snoozedUntil = now + snoozeSeconds
    }

    /// Audio resumed while the prompt/countdown was showing — the meeting clearly continues.
    /// Re-arms without a long snooze (a fresh silence must accumulate from scratch anyway).
    public mutating func cancelPrompt(now: Double) {
        prompted = false
        farewellAt = nil
        lastAudioAt = now
    }
}
