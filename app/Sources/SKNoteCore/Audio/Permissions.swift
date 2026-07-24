import Foundation
import AVFoundation
import CoreAudio
import ApplicationServices

/// Microphone + system-audio permission status and requests, plus the deep links the UI
/// uses to send the user to the right System Settings pane.
public enum Permission: Sendable {
    public enum Status: String, Sendable {
        case granted
        case denied
        case notDetermined
    }

    // MARK: Microphone (kTCCServiceMicrophone)

    public static func micStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Triggers the system prompt if undetermined; returns the resulting status.
    @discardableResult
    public static func requestMic() async -> Status {
        if micStatus() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return micStatus()
    }

    // MARK: System audio (kTCCServiceAudioCapture)

    /// System audio now flows through ScreenCaptureKit (device-independent, unlike the Core
    /// Audio process tap it replaced), so the Screen Recording grant is what actually gates
    /// it. `CGPreflightScreenCaptureAccess` reports it without prompting.
    public static func screenRecordingStatus() -> Status {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Fires the Screen Recording prompt (or opens the pane) once.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Legacy process-tap probe, kept as the fallback path's status check.
    public static func systemAudioStatus() -> Status {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        let err = AudioHardwareCreateProcessTap(desc, &tapID)
        if err == noErr, tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            return .granted
        }
        return .denied
    }

    // MARK: Accessibility (kTCCServiceAccessibility)

    /// Reading another app's UI (Zoom's participant list + active-speaker highlight) for speaker
    /// tags requires the Accessibility grant. Reported without prompting.
    public static func accessibilityStatus() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Shows the system Accessibility prompt if not yet trusted; returns current trust.
    /// The option key is the literal value of kAXTrustedCheckOptionPrompt (a non-Sendable global).
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: System Settings deep links

    public static let micSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let systemAudioSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
