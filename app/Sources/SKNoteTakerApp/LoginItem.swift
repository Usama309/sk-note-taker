import Foundation
import ServiceManagement

/// Manages "launch SK Note Taker at login" via the modern ServiceManagement API
/// (SMAppService, macOS 13+). Registering adds the app as a login item; on first enable macOS
/// may list it under System Settings → General → Login Items for the user to confirm.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .notRegistered: "Off"
        case .requiresApproval: "Needs approval in System Settings"
        case .notFound: "Unavailable"
        @unknown default: "Unknown"
        }
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            FileHandle.standardError.write(
                Data("SKNoteTaker: login item \(enabled ? "register" : "unregister") failed: \(error)\n".utf8))
            return false
        }
    }

    /// Opens the Login Items pane so the user can approve if macOS is holding it.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
