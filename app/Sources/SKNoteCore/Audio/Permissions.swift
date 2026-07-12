import Foundation
import AVFoundation
import CoreAudio

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

    /// There is no public status API for system-audio capture, so we probe: try to create a
    /// process tap. Success ⇒ granted. On first attempt for an undetermined app this also
    /// triggers the prompt. We can't distinguish "denied" from "not yet asked" reliably, so
    /// callers treat non-granted as "needs attention".
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

    // MARK: System Settings deep links

    public static let micSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let systemAudioSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
