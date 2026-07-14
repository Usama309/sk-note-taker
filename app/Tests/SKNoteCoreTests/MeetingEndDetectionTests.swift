import Foundation
import Testing
@testable import SKNoteCore

@Suite("Farewell matcher")
struct FarewellMatcherTests {
    @Test func matchesCommonFarewells() {
        #expect(FarewellMatcher.matches("Okay, thanks, bye!"))
        #expect(FarewellMatcher.matches("Take care, talk soon."))
        #expect(FarewellMatcher.matches("Alright — see you tomorrow"))
        #expect(FarewellMatcher.matches("BYE BYE"))
        #expect(FarewellMatcher.matches("Thanks everyone, have a good day"))
        #expect(FarewellMatcher.matches("Theek hai, Allah Hafiz"))
    }

    @Test func ignoresNormalConversation() {
        #expect(!FarewellMatcher.matches("Let's review the budget for next quarter"))
        #expect(!FarewellMatcher.matches("The bypass surgery went well"))     // "bye" inside a word
        #expect(!FarewellMatcher.matches("A bystander reported the issue"))
        #expect(!FarewellMatcher.matches("We should buy new laptops"))
        #expect(!FarewellMatcher.matches(""))
    }
}

@Suite("Meeting end engine")
struct MeetingEndEngineTests {
    /// Feed continuous loud audio from `from` to `to` at 1 s steps.
    private func speak(_ engine: inout MeetingEndEngine, from: Double, to: Double) {
        var t = from
        while t <= to {
            engine.noteAudio(now: t, rms: 0.1)
            t += 1
        }
    }

    /// Feed silent chunks (mic stays open, delivers near-zero RMS) and evaluate each second.
    /// Returns the first trigger, if any.
    private func silence(_ engine: inout MeetingEndEngine, from: Double, to: Double)
        -> MeetingEndEngine.Trigger? {
        var t = from
        while t <= to {
            engine.noteAudio(now: t, rms: 0.0001)
            if let trigger = engine.evaluate(now: t) { return trigger }
            t += 1
        }
        return nil
    }

    @Test func silenceTriggersAtTimeout() {
        var engine = MeetingEndEngine(silenceTimeout: 120)
        speak(&engine, from: 0, to: 60)
        let trigger = silence(&engine, from: 61, to: 200)
        guard case .silence(let seconds)? = trigger else {
            Issue.record("expected silence trigger, got \(String(describing: trigger))")
            return
        }
        #expect(seconds >= 120)
    }

    @Test func noTriggerWhileAudioContinues() {
        // Urdu speech: transcriber yields nothing, but audio energy keeps flowing.
        var engine = MeetingEndEngine(silenceTimeout: 120)
        speak(&engine, from: 0, to: 600)
        #expect(engine.evaluate(now: 600) == nil)
    }

    @Test func noTriggerBeforeAnyAudio() {
        // A meeting that never produced audio shouldn't self-end (slow start, wrong device).
        var engine = MeetingEndEngine(silenceTimeout: 120)
        #expect(silence(&engine, from: 0, to: 400) == nil)
    }

    @Test func firesOnlyOnceUntilResolved() {
        var engine = MeetingEndEngine(silenceTimeout: 120)
        speak(&engine, from: 0, to: 10)
        #expect(silence(&engine, from: 11, to: 200) != nil)
        // Still silent — but the prompt is outstanding, so no re-fire.
        #expect(engine.isPrompting)
        #expect(silence(&engine, from: 201, to: 400) == nil)
    }

    @Test func farewellPlusQuietTriggersEarly() {
        var engine = MeetingEndEngine(silenceTimeout: 120, farewellQuiet: 20)
        speak(&engine, from: 0, to: 300)
        engine.noteUtterance(now: 300, text: "Okay thanks, bye, take care")
        // Only 25 s of quiet — far less than the 120 s silence timeout.
        let trigger = silence(&engine, from: 301, to: 325)
        #expect(trigger == .farewell)
    }

    @Test func farewellFollowedByMoreTalkDoesNotTrigger() {
        var engine = MeetingEndEngine(silenceTimeout: 120, farewellQuiet: 20)
        speak(&engine, from: 0, to: 300)
        engine.noteUtterance(now: 300, text: "bye for now")
        speak(&engine, from: 301, to: 330)      // "…oh wait, one more thing"
        // Quiet after the resumed talk: farewell is stale, silence timeout not reached.
        #expect(silence(&engine, from: 331, to: 380) == nil)
    }

    @Test func farewellExpiresAfterWindow() {
        var engine = MeetingEndEngine(silenceTimeout: 300, farewellQuiet: 20, farewellWindow: 60)
        speak(&engine, from: 0, to: 100)
        engine.noteUtterance(now: 100, text: "goodbye")
        // No evaluation for 90 s (past the 60 s window) → farewell no longer hot,
        // and 300 s silence not yet reached.
        #expect(engine.evaluate(now: 190) == nil)
    }

    @Test func transcriptionActivityResetsSilenceTimer() {
        // The remote client speaks on the system channel; their voice is transcribed but
        // its RMS sits below the activity gate (listener on low volume). Transcription must
        // keep the meeting alive even though noteAudio never sees loud-enough audio.
        var engine = MeetingEndEngine(silenceTimeout: 120)
        speak(&engine, from: 0, to: 10)
        var t = 11.0
        while t <= 400 {
            engine.noteAudio(now: t, rms: 0.002)          // sub-gate system audio
            if Int(t) % 15 == 0 { engine.noteActivity(now: t) }  // a transcript result lands
            if engine.evaluate(now: t) != nil {
                Issue.record("silence fired at t=\(t) despite ongoing transcription")
                return
            }
            t += 1
        }
    }

    @Test func firesOnlyOncePerMeeting() {
        // "Once is enough" — after the single prompt, no amount of further silence,
        // snoozing, or resumed-then-quiet audio produces another prompt.
        var engine = MeetingEndEngine(silenceTimeout: 120, snoozeSeconds: 300)
        speak(&engine, from: 0, to: 10)
        #expect(silence(&engine, from: 11, to: 200) != nil)   // the one prompt

        engine.snooze(now: 200)
        #expect(!engine.isPrompting)
        #expect(silence(&engine, from: 201, to: 800) == nil)  // never nags again

        // Even a fresh talk-then-silence cycle stays quiet.
        engine.cancelPrompt(now: 800)
        speak(&engine, from: 800, to: 860)
        #expect(silence(&engine, from: 861, to: 1100) == nil)
    }
}
