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
                    .font(.skHero)
                Text("Tell us your name, grant two permissions, and you're ready to record.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            // Asked first because it's the one thing only the user can answer — everything
            // captured on the mic is labelled with this instead of a generic "Speaker 1".
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your name").font(.skSubtitle)
                        Text("Labels everything you say in the transcript.")
                            .font(.skCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Me", text: Binding(
                        get: { app.settings.defaultSpeakerName ?? "" },
                        set: { app.setUserName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

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
                .font(.skCaption)
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
                Text(title).font(.skSubtitle)
                Text(subtitle).font(.skCaption).foregroundStyle(.secondary)
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
            .font(.skCaption)
            .foregroundStyle(config.1)
    }
}
