import SwiftUI
import SKNoteCore

/// First-run setup, as a guided one-step-at-a-time wizard. Each screen has a single clear action
/// with live status, so a new user can't silently end up with no microphone (the "I never saw the
/// prompt" failure) and always knows exactly what to do next.
struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable { case welcome, mic, system, calendar, ready }

    private var isLast: Bool { step == .ready }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                switch step {
                case .welcome:  welcomeStep
                case .mic:      micStep
                case .system:   systemStep
                case .calendar: calendarStep
                case .ready:    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 540, height: 580)
        .onAppear { app.refreshPermissions() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 11) {
            LogoMark(size: 30)
            Text("SK Note Taker").font(.skTitle)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s == step ? Theme.mint : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 22 : 7, height: 7)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if step != .welcome {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                } label: { Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button("Skip setup") { app.showOnboarding = false }
                .buttonStyle(.plain).foregroundStyle(.tertiary).font(.skCallout)
            Spacer()
            Button {
                if isLast { app.showOnboarding = false }
                else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        step = Step(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
            } label: {
                Text(isLast ? "Start Using SK Note Taker" : "Continue")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.accentGradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    /// Shared layout for a step: a big icon, a title, a one-line subtitle, then the step's controls.
    private func scaffold<Content: View>(
        icon: String, tint: Color = Theme.mint, title: String, subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(tint)
            }
            VStack(spacing: 7) {
                Text(title).font(.custom("Plus Jakarta Sans", size: 24).weight(.bold))
                    .multilineTextAlignment(.center)
                Text(subtitle).font(.skBody).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
            }
            content()
            Spacer(minLength: 8)
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        scaffold(icon: "hand.wave.fill", title: "Welcome to SK Note Taker",
                 subtitle: "Records your calls, labels who said what, and writes the summary the moment the meeting ends. Everything stays on your Mac.") {
            VStack(spacing: 8) {
                Text("What should we call you?").font(.skLabel).foregroundStyle(.secondary)
                TextField("Your name", text: Binding(
                    get: { app.settings.defaultSpeakerName ?? "" },
                    set: { app.setUserName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .multilineTextAlignment(.center)
                Text("Labels everything you say, instead of “Speaker 1”.")
                    .font(.skCaption).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    private var micStep: some View {
        scaffold(icon: "mic.fill", title: "Hear your voice",
                 subtitle: "SK Note Taker needs your microphone to transcribe what you say. macOS will ask once.") {
            VStack(spacing: 12) {
                StatusBadge(status: app.micStatus)
                if app.micStatus == .granted {
                    Label("Microphone is on. You're set.", systemImage: "checkmark.seal.fill")
                        .font(.skCallout).foregroundStyle(Theme.mint)
                } else {
                    Button {
                        if app.micStatus == .denied { app.openMicSettings() }
                        else { Task { await app.requestMic() } }
                    } label: {
                        Text(app.micStatus == .denied ? "Open System Settings" : "Allow Microphone")
                            .fontWeight(.semibold).padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Theme.mint, in: Capsule()).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    if app.micStatus == .denied {
                        Text("Turn on SK Note Taker under Microphone, then come back.")
                            .font(.skCaption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var systemStep: some View {
        scaffold(icon: "speaker.wave.2.fill", title: "Hear everyone else",
                 subtitle: "To transcribe the people you're meeting with, macOS asks for “System Audio Recording”. This one lives in System Settings.") {
            VStack(spacing: 12) {
                StatusBadge(status: app.systemAudioStatus)
                if app.systemAudioStatus == .granted {
                    Label("System audio is on. Everyone will be transcribed.", systemImage: "checkmark.seal.fill")
                        .font(.skCallout).foregroundStyle(Theme.mint).multilineTextAlignment(.center)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            app.openSystemAudioSettings()
                        } label: {
                            Text("Open System Settings")
                                .fontWeight(.semibold).padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Theme.mint, in: Capsule()).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        Button("I've enabled it") { app.probeSystemAudio() }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        stepHint(1, "Click Open System Settings above")
                        stepHint(2, "Under “Screen & System Audio Recording”, turn on SK Note Taker")
                        stepHint(3, "Come back and click “I've enabled it”")
                    }
                    .padding(12)
                    .frame(maxWidth: 400, alignment: .leading)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 4)
        }
    }

    private func stepHint(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.skCaptionStrong).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Theme.mint, in: Circle())
            Text(text).font(.skCaption).foregroundStyle(.secondary)
        }
    }

    private var calendarStep: some View {
        scaffold(icon: "calendar", tint: Theme.accent, title: "See your meetings",
                 subtitle: "Connect Google Calendar (optional) so your upcoming meetings appear on Home and you can start notes in one click. Read-only, and it stays on your Mac.") {
            VStack(spacing: 12) {
                if app.calendarConnected {
                    Label(app.calendarEmail.map { "Connected as \($0)" } ?? "Calendar connected",
                          systemImage: "checkmark.seal.fill")
                        .font(.skCallout).foregroundStyle(Theme.mint)
                } else {
                    Button {
                        Task { await app.connectCalendar() }
                    } label: {
                        HStack(spacing: 8) {
                            if app.calendarBusy { ProgressView().controlSize(.small) }
                            Text(app.calendarBusy ? "Connecting…" : "Connect Google Calendar")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule()).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).disabled(app.calendarBusy)
                    if let err = app.calendarError {
                        Text(err).font(.skCaption).foregroundStyle(.orange)
                            .multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    Text("You can also do this later in Settings. Skip if you'd rather not.")
                        .font(.skCaption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var readyStep: some View {
        scaffold(icon: "sparkles", title: "You're ready",
                 subtitle: "Here's what's set up. You can change any of it later in Settings.") {
            VStack(alignment: .leading, spacing: 10) {
                readyRow("Microphone", app.micStatus == .granted)
                readyRow("System audio", app.systemAudioStatus == .granted)
                readyRow("Google Calendar", app.calendarConnected, optional: true)
                readyRow("Your name: \(app.userDisplayName)", (app.settings.defaultSpeakerName ?? "").isEmpty == false)
            }
            .padding(16)
            .frame(width: 340)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 4)
        }
    }

    private func readyRow(_ label: String, _ done: Bool, optional: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "minus.circle" : "circle"))
                .foregroundStyle(done ? Theme.mint : (optional ? Color.secondary : Color.orange))
            Text(label).font(.skBody)
            Spacer()
            if !done && !optional {
                Text("optional now").font(.skCaption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: Permission.Status

    private var config: (String, Color, String) {
        switch status {
        case .granted: ("checkmark.circle.fill", Theme.mint, "Granted")
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
