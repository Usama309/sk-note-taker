import Foundation
import ScreenCaptureKit
import SKNoteCore

/// One-shot carrier to move a non-Sendable `SCContentFilter` from the picker's callback to the main
/// actor. Safe because the value is produced once and consumed once.
private struct SendableFilterBox: @unchecked Sendable {
    let value: SCContentFilter?
}

/// Presents the native macOS screen-share picker (the same system panel Zoom's "Share Screen" uses)
/// so the user can choose a window, an app, or the whole screen to record. Delivers the chosen
/// `SCContentFilter` back on the main actor, or nil if they cancel.
@MainActor
final class ScreenSourcePicker: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared
    private var onPick: ((SCContentFilter?) -> Void)?

    /// Show the picker. `completion` fires once with the chosen source, or nil on cancel/failure.
    func present(completion: @escaping (SCContentFilter?) -> Void) {
        onPick = completion
        picker.add(self)
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
        picker.configuration = config
        picker.maximumStreamCount = 1
        picker.isActive = true
        picker.present()
    }

    private func finish(_ filter: SCContentFilter?) {
        let cb = onPick
        onPick = nil
        picker.remove(self)
        picker.isActive = false
        cb?(filter)
    }

    // MARK: SCContentSharingPickerObserver (system may call off the main thread → hop to main)

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is not Sendable; it is handed off exactly once from this callback to the
        // main actor, so carrying it through a box is safe.
        let boxed = SendableFilterBox(value: filter)
        Task { @MainActor in self.finish(boxed.value) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        SKLog.error(.captureStartFailed, .capture, "Screen source picker failed", error: error)
        Task { @MainActor in self.finish(nil) }
    }
}
