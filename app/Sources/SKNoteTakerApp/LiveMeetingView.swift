import SwiftUI
import SKNoteCore

/// The in-meeting experience: live transcript with speaker attribution on the left,
/// the user's rough notes on the right (Granola's notepad model).
struct LiveMeetingView: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession
    @State private var notes = ""
    @State private var showSpeakers = false
    @State private var sidePane: SidePane = .notes

    enum SidePane: String, CaseIterable {
        case notes = "Notes"
        case assistant = "Assistant"
    }

    /// After ~4s of recording with the mic still silent, warn the user — this is exactly the
    /// failure mode where the mic looks "on" but no audio arrives.
    private var showMicWarning: Bool {
        session.phase == .recording
            && session.elapsed > 4
            && !(session.channelHasAudio[.mic] ?? false)
    }

    private var micWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
            Text("No microphone audio detected — your voice won't be transcribed. If a call started after recording began, stop and start the recording again; otherwise check your input device and mic access.")
                .font(.system(size: 12))
            Spacer()
            Button("Open Settings") { app.openMicSettings() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let prompt = session.endPrompt {
                EndPromptBanner(prompt: prompt, session: session)
            }
            if showMicWarning {
                micWarningBanner
            }
            HSplitView {
                transcriptPane
                    .frame(minWidth: 340)
                sidePaneView
                    .frame(minWidth: 300)
            }
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet(meetingId: session.meeting.id,
                          speakers: session.meeting.speakers)
        }
        .onChange(of: notes) {
            let id = session.meeting.id
            let text = notes
            Task { try? await app.store.saveNotes(text, for: id) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isPaused ? Color.orange : .red)
                    .frame(width: 10, height: 10)
                    .opacity(session.phase == .recording && !session.isPaused ? 1 : 0.4)
                Text(session.isPaused ? "Paused" :
                     session.phase == .preparing ? "Preparing…" :
                     session.phase == .finishing ? "Finishing…" : "Recording")
                    .font(.system(size: 13, weight: .semibold))
                Text(Theme.timestamp(session.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if session.phase == .recording {
                    // Audio is being saved to recording.m4a alongside the transcript.
                    Label("Saving audio", systemImage: "waveform.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .help("The full meeting audio is recorded and playable afterwards")
                }
            }

            Spacer()

            // Live input meters so the user can SEE audio arriving on each channel.
            if session.phase == .recording {
                ChannelMeter(label: "Mic", systemImage: "mic.fill",
                             level: session.levels[.mic] ?? 0,
                             hasAudio: session.channelHasAudio[.mic] ?? false)
                ChannelMeter(label: "System", systemImage: "speaker.wave.2.fill",
                             level: session.levels[.system] ?? 0,
                             hasAudio: session.channelHasAudio[.system] ?? false)
            }

            if session.phase == .recording {
                Button {
                    session.isPaused ? session.resume() : session.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause",
                          systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(session.isPaused ? "Resume recording" : "Pause recording — the paused time isn't recorded")

                Button {
                    Task {
                        if session.isRecordingScreen { await session.stopScreenRecording() }
                        else { await session.startScreenRecording() }
                    }
                } label: {
                    Label(session.isRecordingScreen ? "Recording screen" : "Record screen",
                          systemImage: session.isRecordingScreen
                            ? "record.circle.fill" : "rectangle.dashed.badge.record")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(session.isRecordingScreen ? .red : nil)
                .help(session.isRecordingScreen ? "Stop recording the screen"
                      : "Also record your screen to a video saved with this meeting")

                Button {
                    showSpeakers = true
                } label: {
                    Label("Speakers", systemImage: "person.2").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Rename speakers")

                Button {
                    app.setCompact(true)
                } label: {
                    Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Shrink to a floating transcript panel docked to the right")
            }

            Button {
                Task { await app.stopMeeting() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("End Meeting").fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.red.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .finishing)
            .keyboardShortcut("e", modifiers: [.command])
            .accessibilityLabel("End Meeting")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcriptPane: some View {
        LiveTranscriptList(session: session)
    }

    private var sidePaneView: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidePane) {
                ForEach(SidePane.allCases, id: \.self) { pane in
                    Label(pane.rawValue,
                          systemImage: pane == .notes ? "square.and.pencil" : "sparkles")
                        .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)

            switch sidePane {
            case .notes: notesPane
            case .assistant: LiveAssistantPane(session: session)
            }
        }
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jot rough bullets — they become anchors for the AI summary.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
        }
    }
}

/// The in-meeting AI assistant: ask questions about the LIVE transcript — catch up, decode
/// what someone means, or get suggested responses — without leaving the call.
struct LiveAssistantPane: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession
    @State private var chat = ChatLog()
    @State private var question = ""

    /// One-tap prompts for the moments that matter mid-call.
    private static let quickActions: [(label: String, icon: String, prompt: String)] = [
        ("Catch me up", "clock.arrow.circlepath",
         "Catch me up: briefly recap what has happened in this meeting so far — key topics, asks, and open questions."),
        ("What do they mean?", "questionmark.bubble",
         "Explain in plain language what the other participants are saying right now and what their last point means."),
        ("Suggest a response", "text.bubble",
         "Suggest 1–3 concise things I could say next in this conversation, written in my voice so I can say them directly."),
    ]

    private var thinking: Bool { app.busy.contains("liveChat") }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty && !thinking {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Theme.accentGradient)
                                Text("Ask AI while the meeting runs")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                Text("Catch up, decode what they mean, or get a suggested reply — from the live transcript.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { index, message in
                            ChatBubble(message: message)
                                .id(index)
                        }
                        if thinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                        Color.clear.frame(height: 1).id("live-chat-bottom")
                    }
                    .padding(12)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation { proxy.scrollTo("live-chat-bottom") }
                }
            }

            // Quick actions — the three questions that matter mid-call.
            HStack(spacing: 6) {
                ForEach(Self.quickActions, id: \.label) { action in
                    Button {
                        ask(action.prompt)
                    } label: {
                        Label(action.label, systemImage: action.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.indigo.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(thinking || session.liveSegments.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about what's being said…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { ask(question) }
                Button {
                    ask(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(question.isEmpty ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(question.isEmpty || thinking)
            }
            .padding(10)
        }
        .task { chat = await app.store.chat(for: session.meeting.id) }
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !thinking, !session.liveSegments.isEmpty else { return }
        question = ""
        let id = session.meeting.id
        Task {
            // Optimistically show the question while Claude thinks.
            chat.messages.append(ChatMessage(role: "user", text: q))
            await app.askLive(question: q)
            chat = await app.store.chat(for: id)
        }
    }
}

/// "Has the meeting ended?" banner with a live countdown — no response auto-ends the meeting.
struct EndPromptBanner: View {
    @Environment(AppState.self) private var app
    let prompt: MeetingSession.EndPrompt
    let session: MeetingSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.reason)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Ending automatically in \(remaining(at: context.date))s…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Keep Recording") { session.keepRecording() }
                    .controlSize(.small)
                Button {
                    Task { await app.stopMeeting() }
                } label: {
                    Text("End Now").fontWeight(.semibold)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.indigo.opacity(0.10))
        }
    }

    private func remaining(at date: Date) -> Int {
        max(0, Int(prompt.deadline.timeIntervalSince(date).rounded()))
    }
}

/// Compact live input-level meter for one audio channel. Grey when silent, gradient when hot.
struct ChannelMeter: View {
    let label: String
    let systemImage: String
    let level: Float          // 0…1 RMS
    let hasAudio: Bool

    private var bars: Int { LevelMeter.bars(forRMS: level) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: bars > 0 ? systemImage : systemImage + ".slash")
                .font(.system(size: 10))
                .foregroundStyle(bars > 0 ? AnyShapeStyle(Theme.accentGradient)
                                 : AnyShapeStyle(hasAudio ? AnyShapeStyle(.secondary)
                                                          : AnyShapeStyle(Color.orange)))
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < bars ? AnyShapeStyle(Theme.accentGradient)
                              : AnyShapeStyle(.quaternary))
                        .frame(width: 3, height: 5 + CGFloat(i) * 2.5)
                }
            }
        }
        .help("\(label) input level — \(bars)/5")
        .animation(.easeOut(duration: 0.12), value: bars)
    }
}

/// One utterance, rendered as a chat bubble. Messaging-app convention: what the MICROPHONE
/// captured is you, so it sits on the RIGHT; everyone coming through the system audio (the
/// remote participants) sits on the LEFT. That makes "me vs them" readable at a glance
/// without decoding speaker numbers.
struct UtteranceBubble: View {
    let name: String
    let color: Color
    let time: Double?
    let text: String
    let volatile: Bool
    var selected: Bool = false
    /// Mic channel — the machine owner. Right-aligned, tinted, labeled "Me".
    var isMe: Bool = false
    /// When set, the timestamp becomes a "jump playback here" button.
    var onTimeTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 56) }
            bubble
            if !isMe { Spacer(minLength: 56) }
        }
    }

    private var bubble: some View {
        // The BOX is pushed right for "me" (see body), but its CONTENTS always read
        // left-to-right — left-aligned text is how English is read, right-aligned body text
        // is harder to scan.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isMe, selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.indigo)
                }
                Text(name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                if let time {
                    if let onTimeTap {
                        Button(action: onTimeTap) {
                            HStack(spacing: 2) {
                                Image(systemName: "play.fill").font(.system(size: 7))
                                Text(Theme.timestamp(time))
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Play recording from here")
                    } else {
                        Text(Theme.timestamp(time))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !isMe, selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.indigo)
                }
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(volatile ? .secondary : .primary)
                .italic(volatile)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(volatile ? 0.05 : selected ? 0.16 : isMe ? 0.13 : 0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.indigo.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
    }
}

/// The scrolling live transcript (speaker-attributed bubbles + volatile in-flight text).
/// Shared by the full meeting view and the compact floating panel.
struct LiveTranscriptList: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession

    /// Mic speaker is the machine owner → their configured name, else "Me".
    private func liveLabel(for segment: TranscriptSegment) -> String {
        let info = session.meeting.speakers[segment.speaker]
        if let name = info?.name, !name.isEmpty { return name }
        if segment.source == .mic { return app.userDisplayName }
        return session.meeting.displayName(forSpeakerKey: segment.speaker)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.liveSegments.isEmpty && session.volatileText.values.allSatisfy(\.isEmpty) {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.accentGradient)
                            Text("Listening… start talking or play meeting audio.")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(session.liveSegments) { segment in
                        UtteranceBubble(
                            name: liveLabel(for: segment),
                            color: Theme.speakerColor(segment.speaker),
                            time: segment.start,
                            text: segment.text,
                            volatile: false,
                            isMe: segment.source == .mic)
                            .id(segment.id)
                    }
                    ForEach([AudioChannel.mic, .system], id: \.self) { channel in
                        if let text = session.volatileText[channel], !text.isEmpty {
                            UtteranceBubble(
                                name: channel == .mic ? app.userDisplayName : "…",
                                color: .secondary,
                                time: nil,
                                text: text,
                                volatile: true,
                                isMe: channel == .mic)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: session.liveSegments.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
        .background(.background.secondary.opacity(0.4))
    }
}

/// Compact "floating transcript" panel: a narrow right-docked window (on top of other apps)
/// with the live transcript and the Ask-AI pane, so the meeting can be followed in Zoom/Outlook
/// without the full app in the way. Recording keeps running.
struct CompactLiveView: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isPaused ? Color.orange : .red)
                    .frame(width: 8, height: 8)
                    .opacity(session.isPaused ? 0.5 : 1)
                Text(session.isPaused ? "Paused" : "REC")
                    .font(.system(size: 11, weight: .semibold))
                Text(Theme.timestamp(session.elapsed))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if session.phase == .recording {
                    Button {
                        session.isPaused ? session.resume() : session.pause()
                    } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.plain)
                    .help(session.isPaused ? "Resume" : "Pause")
                }
                Button { app.setCompact(false) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("Expand back to the full app")
                Button { Task { await app.stopMeeting() } } label: {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("End meeting")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            VSplitView {
                LiveTranscriptList(session: session)
                    .frame(minHeight: 160)
                LiveAssistantPane(session: session)
                    .frame(minHeight: 130)
            }
        }
    }
}
