import SwiftUI
import SKNoteCore

// MARK: - Chat tab ("What did Kainat say?")

struct ChatTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    @State private var chat = ChatLog()
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 30))
                                    .foregroundStyle(Theme.accentGradient)
                                Text("Ask anything about this meeting")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text("Try: \"What did \(exampleSpeaker) say about the deadline?\"")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { index, message in
                            ChatBubble(message: message)
                                .id(index)
                        }
                        if app.busy.contains("chat") {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation { proxy.scrollTo("chat-bottom") }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(question.isEmpty ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(question.isEmpty || app.busy.contains("chat"))
            }
            .padding(12)
        }
        .task { chat = await app.store.chat(for: meeting.id) }
    }

    private var exampleSpeaker: String {
        meeting.speakers.values.compactMap(\.name).first
            ?? meeting.speakers.keys.sorted().last.map { meeting.displayName(forSpeakerKey: $0) }
            ?? "Speaker 2"
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !app.busy.contains("chat") else { return }
        question = ""
        Task {
            await app.ask(question: q, meetingId: meeting.id)
            chat = await app.store.chat(for: meeting.id)
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text((try? AttributedString(markdown: message.text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(message.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Speakers sheet (S2 = Kainat)

struct SpeakersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let meetingId: UUID
    let speakers: [String: SpeakerInfo]
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LogoMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Name the Speakers")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Transcripts, summaries, and chat use these names.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if speakers.isEmpty {
                Text("No speakers detected yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }

            ForEach(speakers.keys.sorted(), id: \.self) { key in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.speakerColor(key))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(speakers[key]?.label ?? key)
                            .font(.system(size: 12, weight: .semibold))
                        Text(speakers[key]?.source == .mic ? "Your microphone" : "System audio")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 110, alignment: .leading)
                    TextField("Name (e.g. Kainat)", text: binding(for: key))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    save()
                } label: {
                    Text("Save Names").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.indigo)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Save Names")
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            for (key, info) in speakers { names[key] = info.name ?? "" }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { names[key] ?? "" }, set: { names[key] = $0 })
    }

    private func save() {
        Task {
            for (key, name) in names {
                let current = speakers[key]?.name ?? ""
                if name != current {
                    await app.renameSpeaker(meetingId: meetingId, key: key, name: name)
                }
            }
            dismiss()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack(spacing: 8) {
                        StatusBadge(status: app.micStatus)
                        if app.micStatus == .notDetermined {
                            Button("Request") { Task { await app.requestMic() } }
                                .controlSize(.small)
                        } else if app.micStatus == .denied {
                            Button("Open Settings") { app.openMicSettings() }
                                .controlSize(.small)
                        }
                    }
                }
                LabeledContent("System Audio") {
                    HStack(spacing: 8) {
                        StatusBadge(status: app.systemAudioStatus)
                        Button(app.systemAudioStatus == .granted ? "Re-check" : "Open Settings") {
                            app.probeSystemAudio()
                            if app.systemAudioStatus != .granted { app.openSystemAudioSettings() }
                        }
                        .controlSize(.small)
                    }
                }
                Text("Both are required to record. If a prompt never appeared, use the buttons above or reset with: tccutil reset Microphone com.saqibkamran.sknotetaker")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Section("AI (Claude Code CLI)") {
                Picker("Model", selection: $app.settings.claudeModel) {
                    Text("Sonnet (recommended)").tag("sonnet")
                    Text("Opus (deepest)").tag("opus")
                    Text("Haiku (fastest)").tag("haiku")
                }
                LabeledContent("CLI status") {
                    Label(app.claudeAvailable ? "Available" : "Not found",
                          systemImage: app.claudeAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(app.claudeAvailable ? .green : .red)
                }
            }
            Section("Meeting Detection") {
                Toggle("Auto-detect meetings", isOn: Binding(
                    get: { app.settings.autoDetectMeetings },
                    set: { app.setAutoDetect($0) }))
                LabeledContent("Notifications") {
                    HStack(spacing: 8) {
                        Label(app.notificationStatus == "authorized" ? "On" : app.notificationStatus,
                              systemImage: app.notificationStatus == "authorized"
                                ? "checkmark.circle.fill" : "bell.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(app.notificationStatus == "authorized" ? .green : .orange)
                        if app.notificationStatus != "authorized" {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text("Pops up a native macOS notification when a Zoom, Teams, WhatsApp, or browser (Google Meet) call starts — click it to start taking notes.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Section("Speakers") {
                TextField("Your name (used for Speaker 1)", text: Binding(
                    get: { app.settings.defaultSpeakerName ?? "" },
                    set: { app.settings.defaultSpeakerName = $0.isEmpty ? nil : $0 }))
            }
            Section("Storage") {
                LabeledContent("Data folder") {
                    Text(MeetingStore.defaultDataDir().path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.bottom, 10)
        .onAppear { app.refreshPermissions() }
        .onChange(of: app.settings) {
            Task { await app.saveSettings() }
        }
    }
}
