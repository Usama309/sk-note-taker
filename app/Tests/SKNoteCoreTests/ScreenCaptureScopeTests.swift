import Foundation
import Testing
@testable import SKNoteCore

@Suite("Screen capture scope")
struct ScreenCaptureScopeTests {

    // MARK: meeting app bundle id

    @Test("a dedicated meeting app is preferred over a browser")
    func dedicatedWins() {
        #expect(MeetingAppRegistry.meetingAppBundleId(
            amongRunning: ["com.google.Chrome", "us.zoom.xos"]) == "us.zoom.xos")
    }

    @Test("a browser is used when it is the only meeting app (Google Meet)")
    func browserFallback() {
        #expect(MeetingAppRegistry.meetingAppBundleId(
            amongRunning: ["com.apple.Finder", "com.google.Chrome"]) == "com.google.Chrome")
    }

    @Test("no meeting app among the running apps yields nil (record full display)")
    func none() {
        #expect(MeetingAppRegistry.meetingAppBundleId(amongRunning: ["com.apple.Finder"]) == nil)
        #expect(MeetingAppRegistry.meetingAppBundleId(amongRunning: []) == nil)
    }

    // MARK: window picking

    private let zoom = "us.zoom.xos"

    @Test("the meeting-titled window is chosen over the app's other windows")
    func picksMeetingWindow() {
        let windows = [
            CaptureWindow(bundleId: zoom, title: "Zoom Workplace", area: 900_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: "Zoom Meeting", area: 500_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: nil, area: 1_000, onScreen: true), // toolbar
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: zoom, from: windows) == 1)
    }

    @Test("with no distinctive call title, the front-most window is chosen")
    func picksFrontmost() {
        let windows = [  // front-to-back z-order
            CaptureWindow(bundleId: zoom, title: "A", area: 300_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: "B", area: 800_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: zoom, from: windows) == 0)
    }

    @Test("a Meet call tab beats a 'Team meeting notes' doc tab (no bare-keyword false positive)")
    func meetBeatsDocsDistractor() {
        let chrome = "com.google.Chrome"
        let windows = [
            CaptureWindow(bundleId: chrome, title: "Team meeting notes - Google Docs", area: 900_000, onScreen: true),
            CaptureWindow(bundleId: chrome, title: "standup | Google Meet", area: 850_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: chrome, from: windows) == 1)
    }

    @Test("a Teams call window (front-most) beats a larger Teams home window behind it")
    func teamsCallFrontmostBeatsHome() {
        let teams = "com.microsoft.teams2"
        let windows = [  // the just-joined call is front-most; the big Chat/home window is behind
            CaptureWindow(bundleId: teams, title: "Weekly Sync | Microsoft Teams", area: 800_000, onScreen: true),
            CaptureWindow(bundleId: teams, title: "Chat | Microsoft Teams", area: 2_000_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: teams, from: windows) == 0)
    }

    @Test("tiny and off-screen windows are ignored")
    func ignoresTinyAndOffscreen() {
        let windows = [
            CaptureWindow(bundleId: zoom, title: "tiny", area: 1_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: "hidden", area: 900_000, onScreen: false),
            CaptureWindow(bundleId: zoom, title: "good", area: 500_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: zoom, from: windows) == 2)
    }

    @Test("only windows owned by the target app are considered")
    func filtersByBundle() {
        let windows = [
            CaptureWindow(bundleId: "com.apple.Safari", title: "Zoom Meeting", area: 900_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: "Zoom Meeting", area: 500_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: zoom, from: windows) == 1)
    }

    @Test("the browser window running Meet is picked for a Meet call")
    func picksMeetBrowserWindow() {
        let chrome = "com.google.Chrome"
        let windows = [
            CaptureWindow(bundleId: chrome, title: "Inbox (3) - Gmail", area: 900_000, onScreen: true),
            CaptureWindow(bundleId: chrome, title: "Meet – standup | Google Meet", area: 850_000, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: chrome, from: windows) == 1)
    }

    @Test("an app with no suitable window yields nil (fall back to full display)")
    func noWindow() {
        let windows = [
            CaptureWindow(bundleId: "com.other.app", title: "x", area: 900_000, onScreen: true),
            CaptureWindow(bundleId: zoom, title: "toolbar", area: 500, onScreen: true),
        ]
        #expect(ScreenCaptureScope.pickWindowIndex(bundleId: zoom, from: windows) == nil)
    }
}
