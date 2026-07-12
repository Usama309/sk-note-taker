import SwiftUI
import SKNoteCore

/// First-run permission walkthrough. Guides the user through the two grants SK Note Taker
/// needs, with live status, so the "I never saw the mic prompt" failure can't happen silently.
struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                LogoMark(size: 60)
                    .shadow(color: Theme.indigo.opacity(0.35), radius: 14, y: 5)
                Text("Welcome to SK Note Taker")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Two quick permissions and you're ready to record.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            PermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                subtitle: "Transcribes your voice (Speaker 1).",
                status: app.micStatus,
                actionTitle: app.micStatus == .denied ? "Open Settings" : "Allow",
                action: {
                    if app.micStatus == .denied { app.openMicSettings() }
                    else { Task { await app.requestMic() } }
                })

            PermissionRow(
                icon: "speaker.wave.2.fill",
                title: "System Audio Recording",
                subtitle: "Transcribes everyone else in the meeting.",
                status: app.systemAudioStatus,
                actionTitle: app.systemAudioStatus == .granted ? "Granted" : "Check / Open Settings",
                action: {
                    app.probeSystemAudio()
                    if app.systemAudioStatus != .granted { app.openSystemAudioSettings() }
                })

            Text("System audio uses macOS “System Audio Recording”. If you don't see a prompt, grant it in System Settings → Privacy & Security → Screen & System Audio Recording.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip for now") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(app.micStatus == .granted ? "Start Using SK Note Taker" : "Continue")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accentGradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { app.refreshPermissions() }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let status: Permission.Status
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: status)
            Button(actionTitle, action: action)
                .controlSize(.small)
                .disabled(status == .granted)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatusBadge: View {
    let status: Permission.Status

    private var config: (String, Color, String) {
        switch status {
        case .granted: ("checkmark.circle.fill", .green, "Granted")
        case .denied: ("xmark.circle.fill", .orange, "Off")
        case .notDetermined: ("questionmark.circle", .secondary, "Not set")
        }
    }

    var body: some View {
        Label(config.2, systemImage: config.0)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(config.1)
    }
}
