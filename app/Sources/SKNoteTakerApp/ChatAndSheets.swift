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
                                    .foregroundStyle(Theme.accentTextGradient)
                                Text("Ask anything about this meeting")
                                    .font(.skHeadline)
                                Text("Try: \"What did \(exampleSpeaker) say about the deadline?\"")
                                    .font(.skCallout)
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
                                Text("Thinking…").font(.skCallout).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 8)
                            .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(16)
                    .animation(Theme.Motion.standard, value: chat.messages.count)
                    .animation(Theme.Motion.standard, value: app.busy.contains("chat"))
                }
                .onChange(of: chat.messages.count) {
                    withAnimation(Theme.Motion.standard) { proxy.scrollTo("chat-bottom") }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.skBody)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(question.isEmpty ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(Theme.accentTextGradient))
                }
                .buttonStyle(SendPressStyle())
                .disabled(question.isEmpty || app.busy.contains("chat"))
                .animation(Theme.Motion.snap, value: question.isEmpty)
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
                    .font(.skBody)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 60) }
        }
        // New replies slide up a hair as they fade in; inert unless the list animates.
        .transition(.opacity.combined(with: .offset(y: 8)))
    }
}

/// A plain button that dips while held, so sending a message feels physical.
struct SendPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.Motion.snap, value: configuration.isPressed)
    }
}

// MARK: - Speakers sheet (S2 = Kainat)

struct SpeakersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let meetingId: UUID
    let speakers: [String: SpeakerInfo]
    /// When true (finished meeting with a recording), offer "Redo speaker detection".
    var canRedo: Bool = false
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LogoMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Name the Speakers")
                        .font(.skHeadline)
                    Text("Transcripts, summaries, and chat use these names.")
                        .font(.skCaption)
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
                            .font(.skLabel)
                        Text(speakers[key]?.source == .mic ? "Your microphone" : "System audio")
                            .font(.skFootnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 110, alignment: .leading)
                    TextField("Name (e.g. Kainat)", text: binding(for: key))
                        .textFieldStyle(.roundedBorder)
                }
            }

            if canRedo {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Speakers merged together?")
                            .font(.skLabel)
                        Text("Re-run detection on the recording to separate remote voices.")
                            .font(.skFootnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await app.redoSpeakerDetection(meetingId: meetingId); dismiss() }
                    } label: {
                        if app.busy.contains("redoSpeakers") {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Redo Detection")
                        }
                    }
                    .controlSize(.small)
                    .disabled(app.busy.contains("redoSpeakers"))
                    .animation(Theme.Motion.snap, value: app.busy.contains("redoSpeakers"))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    save()
                    SoundManager.shared.play(.noteSaved)
                } label: {
                    Text("Save Names").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
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
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
        }
        .frame(width: 500, height: 590)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("You") {
                TextField("Your name", text: Binding(
                    get: { app.settings.defaultSpeakerName ?? "" },
                    set: { app.setUserName($0) }),
                          prompt: Text("Me"))
                    .textFieldStyle(.roundedBorder)
                Text("Used to label everything captured from your microphone, in the live "
                     + "transcript and in saved meetings. Leave blank to just show \"Me\".")
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
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
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Section("Speaker tags") {
                LabeledContent("Zoom") {
                    HStack(spacing: 8) {
                        if app.accessibilityStatus == .granted {
                            Label(app.speakerTagsActive ? "Connected" : "Ready",
                                  systemImage: "checkmark.circle.fill")
                                .font(.skCaption).foregroundStyle(Theme.success)
                        } else {
                            Button("Set up") { app.setUpSpeakerTags() }.controlSize(.small)
                        }
                    }
                    .onAppear { app.refreshAccessibility() }
                }
                Text("Reads participant names and the active speaker from the Zoom desktop app via macOS Accessibility, so the transcript shows real names instead of Speaker 1/2/3. SK Note Taker only reads Zoom's window; it never controls it. Names apply to Zoom calls recorded after this is set up.")
                    .font(.skFootnote).foregroundStyle(.tertiary)
                if app.accessibilityStatus == .granted {
                    Button("Dump Zoom accessibility tree (debug)") { app.dumpZoomTree() }
                        .controlSize(.small)
                }
                LabeledContent("Google Meet") {
                    Button("Get extension") { app.revealMeetExtension() }.controlSize(.small)
                }
                Text("For Google Meet, install the SK Note Taker browser extension (Load unpacked in Chrome from the revealed folder). It reads the active speaker from your Meet tab and sends names to the app while you record.")
                    .font(.skFootnote).foregroundStyle(.tertiary)
            }
            Section("AI (Codex CLI)") {
                TextField("Model override (optional)", text: $app.settings.codexModel)
                Text("Leave blank to use the Codex CLI default model.")
                    .font(.skFootnote).foregroundStyle(.tertiary)
                LabeledContent("CLI status") {
                    Label(app.codexAvailable ? "Ready" : "Not ready",
                          systemImage: app.codexAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(app.codexAvailable ? Theme.success : Theme.error)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { app.settings.launchAtLogin },
                    set: { app.setLaunchAtLogin($0) }))
                if LoginItem.needsApproval {
                    HStack {
                        Text("Approve in System Settings → Login Items")
                            .font(.skFootnote).foregroundStyle(Theme.warning)
                        Button("Open") { LoginItem.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
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
                            .font(.skCaption)
                            .foregroundStyle(app.notificationStatus == "authorized" ? Theme.success : Theme.warning)
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
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
                Toggle("Detect when the meeting ends", isOn: $app.settings.autoEndDetection)
                if app.settings.autoEndDetection {
                    Picker("End prompt after silence of",
                           selection: $app.settings.autoEndSilenceMinutes) {
                        Text("1 minute").tag(1.0)
                        Text("2 minutes").tag(2.0)
                        Text("3 minutes").tag(3.0)
                        Text("5 minutes").tag(5.0)
                    }
                }
                Text("When the call goes quiet (or everyone says goodbye), SK Note Taker asks if the meeting has ended and stops recording a minute later unless you keep it going.")
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
            Section("After the meeting") {
                Toggle("Generate summary automatically", isOn: $app.settings.autoSummarize)
                Text("The AI summary (action items, decisions, things to remember) is created right after each meeting ends.")
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
            Section("Screen recording") {
                Toggle("Ask to record my screen when a meeting starts", isOn: $app.settings.askToRecordScreen)
                Text("When on, a prompt lets you record a window, an app, or the whole screen with the meeting. You can always start it later with the Record screen button.")
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
            Section("Sounds") {
                Toggle("Play soft sounds for recording and saves", isOn: $app.settings.uiSounds)
                Text("Very short cues when a recording starts or stops, and when something is saved. Never while you are typing.")
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
            Section("Live assistant") {
                Toggle("Suggest an answer when someone asks me a question", isOn: $app.settings.assistantAutoSuggest)
                Toggle("Let the assistant search the web for answers", isOn: $app.settings.assistantWebSearch)
                Text("The assistant draws on the meeting's project memory (right-click a project → Project memory) and the live transcript to give you the exact wording to say.")
                    .font(.skFootnote)
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
                        .font(.skMonoSmall)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .animation(Theme.Motion.snap, value: app.settings.autoEndDetection)
        .animation(Theme.Motion.snap, value: app.accessibilityStatus)
        .onAppear { app.refreshPermissions() }
        .onChange(of: app.settings) {
            Task { await app.saveSettings() }
        }
    }
}

/// The Calendar settings page: display toggles + a per-calendar visibility list (or the
/// connect/credentials flow when not yet signed in).
struct CalendarSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var gClientID = ""
    @State private var gClientSecret = ""
    @State private var showAdvancedGoogle = false

    var body: some View {
        Form {
            if app.calendarConnected {
                Section("Display") {
                    Toggle("Show upcoming meetings in menu bar", isOn: Binding(
                        get: { app.settings.showUpcomingInMenuBar },
                        set: { app.setShowUpcomingInMenuBar($0) }))
                    Text("Display your next meeting and time until it starts in the macOS menu bar.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
                    Toggle("Show events with no participants", isOn: Binding(
                        get: { app.settings.showEventsWithoutParticipants },
                        set: { app.setShowEventsWithoutParticipants($0) }))
                    Text("Include events without participants or a video link in the Upcoming list.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
                }
                Section {
                    if app.calendarList.isEmpty {
                        Text("Loading calendars…").font(.skCaption).foregroundStyle(.tertiary)
                    }
                    ForEach(app.calendarList) { cal in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(cal.colorHex.map { Color(hex: $0) } ?? Theme.textSecondary)
                                .frame(width: 12, height: 12)
                            Text(cal.displayName).font(.skBody).lineLimit(1)
                            if cal.isPrimary {
                                Text("Primary")
                                    .font(.skFootnote).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.border, in: Capsule())
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { app.isCalendarVisible(cal.id) },
                                set: { app.setCalendarVisible(cal.id, $0) }))
                                .labelsHidden()
                        }
                        .padding(.vertical, 1)
                    }
                    Text("Don't see the calendar you want? Add it in Google Calendar first, then Refresh.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
                } header: {
                    HStack {
                        Text("Visible calendars")
                        Spacer()
                        Button("Reset") { app.resetCalendarVisibility() }
                            .buttonStyle(.plain).font(.skCaption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Section {
                    LabeledContent("Signed in") {
                        Label(app.calendarEmail ?? "Connected", systemImage: "checkmark.circle.fill")
                            .font(.skCaption).foregroundStyle(Theme.success)
                    }
                    HStack {
                        Button("Refresh") { Task { await app.loadCalendarList(); await app.refreshUpcoming() } }
                            .controlSize(.small)
                        Button("Disconnect", role: .destructive) { app.disconnectCalendar() }
                            .controlSize(.small)
                    }
                }
            } else {
                Section("Connect Google Calendar") {
                    // One click for a normal user — the app ships with its own Google client, so
                    // there is nothing to create or paste.
                    Button {
                        Task { await app.connectCalendar() }
                    } label: {
                        if app.calendarBusy {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for browser…") }
                        } else {
                            Label("Connect Google Calendar", systemImage: "globe")
                        }
                    }
                    .disabled(!app.googleCredentialsSaved || app.calendarBusy)
                    if app.calendarBusy {
                        Button("Cancel", role: .cancel) { app.cancelCalendarConnect() }
                            .controlSize(.small)
                    }
                    if let err = app.calendarError {
                        Text(err).font(.skFootnote).foregroundStyle(Theme.error).textSelection(.enabled)
                    }
                    Text("Your browser opens Google's sign-in. SK only reads your upcoming events; your calendar data and tokens stay in your macOS Keychain, never in the app's files or on a server.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
                    if app.usesBuiltInGoogleClient {
                        Text("While Google finishes reviewing the app, you may see a “Google hasn't verified this app” notice. Click Advanced, then “Go to SK Note Taker”, to continue — it's safe; you're signing in to your own account.")
                            .font(.skFootnote).foregroundStyle(.secondary)
                    }

                    // Power users can point the app at their own OAuth client instead.
                    DisclosureGroup("Advanced: use your own OAuth client", isExpanded: $showAdvancedGoogle) {
                        TextField("OAuth Client ID", text: $gClientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                            .textFieldStyle(.roundedBorder)
                            .onAppear { if gClientID.isEmpty { gClientID = app.savedGoogleClientID } }
                        SecureField("OAuth Client Secret", text: $gClientSecret, prompt: Text("GOCSPX-..."))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save credentials") {
                                app.setGoogleCredentials(clientID: gClientID, clientSecret: gClientSecret)
                            }
                            .controlSize(.small)
                            .disabled(gClientID.isEmpty || gClientSecret.isEmpty)
                            Button("Open Google Cloud Credentials") {
                                NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            }
                            .controlSize(.small)
                        }
                        Text("Create a free OAuth client (type: Desktop app) in Google Cloud, enable the Calendar API, then paste its ID and secret. Overrides the built-in client. Stored only in your Keychain.")
                            .font(.skFootnote).foregroundStyle(.tertiary)
                    }
                    .font(.skFootnote)
                }
            }
        }
        .formStyle(.grouped)
        .animation(Theme.Motion.snap, value: app.calendarBusy)
        .task {
            if app.calendarConnected && app.calendarList.isEmpty { await app.loadCalendarList() }
        }
    }
}
