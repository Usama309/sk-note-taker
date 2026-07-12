import Foundation
import CoreAudio
#if canImport(AppKit)
import AppKit
#endif

/// Known video/voice-call apps, by bundle id → display name. When one of these is running and
/// the microphone is in use, we treat it as an active meeting.
public enum MeetingAppRegistry {
    public static let apps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams.wrapper": "Microsoft Teams",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
    ]

    /// Browsers only count as a "meeting" when the mic is in use (Meet/Zoom-web in a tab).
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "company.thebrowser.Browser",
    ]

    /// The display name of the highest-priority meeting app among the given running bundle ids.
    /// Dedicated meeting apps win over browsers (a browser is a weaker signal).
    public static func meetingApp(amongRunning bundleIds: [String]) -> String? {
        let dedicated = bundleIds.first { apps[$0] != nil && !browsers.contains($0) }
        if let dedicated { return apps[dedicated] }
        let browser = bundleIds.first { browsers.contains($0) }
        return browser.flatMap { apps[$0] }
    }
}

/// Pure decision engine for meeting auto-detection — no I/O, fully unit-testable.
///
/// Fires at most once per call (`armed`), requires two consecutive positive polls (debounce
/// against transient mic blips like a notification chime), suppresses while SK Note Taker is
/// itself recording, and honours a cooldown after the user dismisses.
public struct MeetingDetectionEngine: Sendable {
    public var cooldownSeconds: Double
    public var debounceHits: Int

    private var armed = false
    private var snoozedUntil: Double = 0
    private var consecutiveHits = 0
    private var lastApp: String?

    public init(cooldownSeconds: Double = 300, debounceHits: Int = 2) {
        self.cooldownSeconds = cooldownSeconds
        self.debounceHits = debounceHits
    }

    /// Evaluate one poll. Returns the meeting app name when a fresh notification should fire.
    public mutating func evaluate(
        now: Double, micActive: Bool, meetingApp: String?, isRecording: Bool
    ) -> String? {
        // We hold the mic while recording — never self-trigger.
        if isRecording {
            armed = false
            consecutiveHits = 0
            return nil
        }
        guard micActive, let app = meetingApp else {
            // Call ended (mic released) → re-arm for the next one.
            if !micActive {
                armed = false
                consecutiveHits = 0
                lastApp = nil
            }
            return nil
        }
        // Reset the debounce streak if the app identity changed.
        if app != lastApp { consecutiveHits = 0; lastApp = app }
        consecutiveHits += 1

        if armed || now < snoozedUntil { return nil }
        if consecutiveHits < debounceHits { return nil }
        armed = true
        return app
    }

    /// Called when the user dismisses/ignores the prompt — suppress re-firing for a while.
    public mutating func snooze(now: Double, seconds: Double? = nil) {
        snoozedUntil = now + (seconds ?? cooldownSeconds)
        armed = false
        consecutiveHits = 0
    }

    /// Called once the user accepts (starts a meeting) — arm-latch until the call ends.
    public mutating func accepted() {
        armed = true
        consecutiveHits = 0
    }
}

/// Reads whether the default input device is currently running (i.e. some app is capturing the
/// mic). This is device *state*, not audio content, so it needs no microphone permission —
/// which is what lets us detect a meeting before the user has granted anything.
public enum MicActivity {
    public static func micInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr, device != kAudioObjectUnknown else { return false }

        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return err == noErr && running != 0
    }
}

#if canImport(AppKit)
/// Live meeting detector: polls mic activity + running apps on a timer and calls back when a
/// meeting is detected. Owned by the app; started when auto-detect is enabled.
@MainActor
public final class MeetingDetector {
    private var engine: MeetingDetectionEngine
    private var timer: Timer?
    private let interval: TimeInterval

    /// Called with the meeting app's display name when a fresh meeting is detected.
    public var onDetected: ((String) -> Void)?
    /// Queried each tick — return true while SK Note Taker is recording (suppresses detection).
    public var isRecording: () -> Bool = { false }

    public init(interval: TimeInterval = 2.0, cooldownSeconds: Double = 300) {
        self.interval = interval
        self.engine = MeetingDetectionEngine(cooldownSeconds: cooldownSeconds)
    }

    public func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func snooze() {
        engine.snooze(now: Date().timeIntervalSince1970)
    }

    public func accepted() {
        engine.accepted()
    }

    private func tick() {
        let bundleIds = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let app = MeetingAppRegistry.meetingApp(amongRunning: bundleIds)
        let detected = engine.evaluate(
            now: Date().timeIntervalSince1970,
            micActive: MicActivity.micInUse(),
            meetingApp: app,
            isRecording: isRecording())
        if let detected { onDetected?(detected) }
    }
}
#endif
