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

    var onStart: (() -> Void)?
    var onDismiss: (() -> Void)?

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
        let category = UNNotificationCategory(
            identifier: Self.categoryId, actions: [start, dismiss],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
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
        await MainActor.run {
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
