import Foundation
import Testing
@testable import SKNoteCore

@Suite("Meeting app registry")
struct MeetingAppRegistryTests {
    @Test func recognizesDedicatedApps() {
        #expect(MeetingAppRegistry.meetingApp(amongRunning: ["us.zoom.xos"]) == "Zoom")
        #expect(MeetingAppRegistry.meetingApp(amongRunning: ["com.microsoft.teams2"]) == "Microsoft Teams")
        #expect(MeetingAppRegistry.meetingApp(amongRunning: ["net.whatsapp.WhatsApp"]) == "WhatsApp")
    }

    @Test func ignoresUnknownApps() {
        #expect(MeetingAppRegistry.meetingApp(amongRunning:
            ["com.apple.finder", "com.apple.mail"]) == nil)
    }

    @Test func dedicatedAppWinsOverBrowser() {
        // A browser AND Zoom running → report Zoom (stronger signal).
        let result = MeetingAppRegistry.meetingApp(
            amongRunning: ["com.google.Chrome", "us.zoom.xos"])
        #expect(result == "Zoom")
    }

    @Test func browserCountsWhenAlone() {
        #expect(MeetingAppRegistry.meetingApp(amongRunning: ["com.google.Chrome"]) == "Chrome")
    }
}

@Suite("Meeting detection engine")
struct MeetingDetectionEngineTests {
    @Test func firesAfterDebounceWhenMicActiveAndMeetingApp() {
        var engine = MeetingDetectionEngine(cooldownSeconds: 300, debounceHits: 2)
        // First positive poll — debounced, no fire yet.
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: false) == nil)
        // Second consecutive poll — fires.
        #expect(engine.evaluate(now: 2, micActive: true, meetingApp: "Zoom", isRecording: false) == "Zoom")
    }

    @Test func firesOnlyOncePerCall() {
        var engine = MeetingDetectionEngine(debounceHits: 1)
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: false) == "Zoom")
        // Subsequent polls during the same call do not re-fire.
        #expect(engine.evaluate(now: 2, micActive: true, meetingApp: "Zoom", isRecording: false) == nil)
        #expect(engine.evaluate(now: 4, micActive: true, meetingApp: "Zoom", isRecording: false) == nil)
    }

    @Test func reArmsAfterCallEnds() {
        var engine = MeetingDetectionEngine(debounceHits: 1)
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: false) == "Zoom")
        // Mic released — call ended.
        #expect(engine.evaluate(now: 2, micActive: false, meetingApp: nil, isRecording: false) == nil)
        // New call → fires again.
        #expect(engine.evaluate(now: 4, micActive: true, meetingApp: "Teams", isRecording: false) == "Teams")
    }

    @Test func suppressedWhileRecording() {
        var engine = MeetingDetectionEngine(debounceHits: 1)
        // SK Note Taker is recording (holds the mic) — never self-trigger.
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: true) == nil)
        #expect(engine.evaluate(now: 2, micActive: true, meetingApp: "Zoom", isRecording: true) == nil)
    }

    @Test func snoozeSuppressesUntilCooldownElapses() {
        var engine = MeetingDetectionEngine(cooldownSeconds: 300, debounceHits: 1)
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: false) == "Zoom")
        engine.snooze(now: 10)                       // user dismissed
        // End the call so armed resets, but we're within cooldown.
        _ = engine.evaluate(now: 12, micActive: false, meetingApp: nil, isRecording: false)
        #expect(engine.evaluate(now: 100, micActive: true, meetingApp: "Zoom", isRecording: false) == nil,
                "still snoozed at t=100 (<310)")
        #expect(engine.evaluate(now: 320, micActive: true, meetingApp: "Zoom", isRecording: false) == "Zoom",
                "cooldown elapsed by t=320")
    }

    @Test func noMeetingAppMeansNoFire() {
        var engine = MeetingDetectionEngine(debounceHits: 1)
        // Mic active (e.g. Voice Memos) but no meeting app → nothing.
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: nil, isRecording: false) == nil)
    }

    @Test func debounceResetsIfAppChangesMidStreak() {
        var engine = MeetingDetectionEngine(debounceHits: 2)
        #expect(engine.evaluate(now: 0, micActive: true, meetingApp: "Zoom", isRecording: false) == nil)
        // App switched before the streak completed — restart the count for the new app.
        #expect(engine.evaluate(now: 2, micActive: true, meetingApp: "Teams", isRecording: false) == nil)
        #expect(engine.evaluate(now: 4, micActive: true, meetingApp: "Teams", isRecording: false) == "Teams")
    }
}

@Suite("Auto-detect setting")
struct AutoDetectSettingTests {
    @Test func defaultsOn() {
        #expect(AppSettings().autoDetectMeetings == true)
    }

    @Test func legacySettingsJSONWithoutFieldDefaultsOn() throws {
        let legacy = #"{"claudeModel":"sonnet","locale":"en-US"}"#
        let decoded = try SKJSON.decoder.decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.autoDetectMeetings == true)
        #expect(decoded.claudeModel == "sonnet")
    }

    @Test func roundTripsWhenDisabled() throws {
        var s = AppSettings()
        s.autoDetectMeetings = false
        let data = try SKJSON.encoder.encode(s)
        let back = try SKJSON.decoder.decode(AppSettings.self, from: data)
        #expect(back.autoDetectMeetings == false)
    }
}
