import Foundation
import UserNotifications
import AppKit

/// Bridges detected meetings to a macOS notification with a "Start Notes" action. Tapping the
/// notification (or its action button) calls `onStart`; dismissing calls `onDismiss`.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let categoryId = "SK_MEETING_DETECTED"
    static let startActionId = "SK_START_NOTES"
    static let dismissActionId = "SK_DISMISS"
    static let endedCategoryId = "SK_MEETING_ENDED"
    static let endNowActionId = "SK_END_MEETING"
    static let keepRecordingActionId = "SK_KEEP_RECORDING"

    var onStart: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// End-prompt actions ("has the meeting ended?" notification).
    var onEndMeeting: (() -> Void)?
    var onKeepRecording: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: Self.startActionId, title: "Start Notes",
            options: [.foreground])
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionId, title: "Not now",
            options: [])
        let detected = UNNotificationCategory(
            identifier: Self.categoryId, actions: [start, dismiss],
            intentIdentifiers: [], options: [])
        let endNow = UNNotificationAction(
            identifier: Self.endNowActionId, title: "End Meeting",
            options: [])
        let keep = UNNotificationAction(
            identifier: Self.keepRecordingActionId, title: "Keep Recording",
            options: [])
        let ended = UNNotificationCategory(
            identifier: Self.endedCategoryId, actions: [endNow, keep],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([detected, ended])
    }

    /// Requests notification permission (once). Returns whether it's authorized.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func authorizationStatusString() async -> String {
        switch await authorizationStatus() {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }

    /// Shows the "you're in a meeting" prompt.
    func notifyMeetingDetected(app: String) {
        let content = UNMutableNotificationContent()
        content.title = "You're in a \(app) meeting"
        content.body = "Start taking notes with SK Note Taker?"
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        let request = UNNotificationRequest(
            identifier: "sk-meeting-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        center.add(request)
    }

    /// Shows the "has the meeting ended?" prompt (auto-ends after the grace period).
    func notifyMeetingMayHaveEnded(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Has the meeting ended?"
        content.body = "\(reason) Recording stops in 1 minute unless you keep it going."
        content.sound = .default
        content.categoryIdentifier = Self.endedCategoryId
        let request = UNNotificationRequest(
            identifier: "sk-meeting-end-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        center.add(request)
    }

    /// Clears any outstanding end prompts (the countdown resolved in-app).
    func clearEndPrompts() {
        let endedId = Self.endedCategoryId
        center.getDeliveredNotifications { notes in
            let ids = notes
                .filter { $0.request.content.categoryIdentifier == endedId }
                .map(\.request.identifier)
            if !ids.isEmpty {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show the banner even while SK Note Taker is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            if category == Self.endedCategoryId {
                switch action {
                case Self.endNowActionId:
                    onEndMeeting?()
                case Self.keepRecordingActionId, UNNotificationDismissActionIdentifier:
                    // Explicitly dismissing = "leave it running." Honors the user's ask that
                    // the prompt be a single notification they can wave away.
                    onKeepRecording?()
                case UNNotificationDefaultActionIdentifier:
                    // Clicked the body → surface the app so the user can decide there.
                    NSApp.activate(ignoringOtherApps: true)
                default:
                    break
                }
                return
            }
            switch action {
            case Self.startActionId, UNNotificationDefaultActionIdentifier:
                NSApp.activate(ignoringOtherApps: true)
                onStart?()
            case Self.dismissActionId, UNNotificationDismissActionIdentifier:
                onDismiss?()
            default:
                break
            }
        }
    }
}
