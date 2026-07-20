import SwiftUI
import AVFoundation
import SKNoteCore

/// A finished meeting: Summary / Transcript / Notes / Chat tabs, speaker naming,
/// folder assignment, audio playback.
struct MeetingDetailView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    enum Tab: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"
        case chat = "Chat"
    }

    @State private var tab: Tab = .summary
    @State private var transcript: Transcript?
    @State private var summary: SummaryData?
    @State private var notes = ""
    @State private var title = ""
    @State private var showSpeakers = false
    @State private var playback = PlaybackController()

    var body: some View {
        VStack(spacing: 0) {
            header
            if meeting.hasRecording {
                PlayerBar(playback: playback)
            }
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 60)
            .padding(.vertical, 10)

            switch tab {
            case .summary: SummaryTab(meeting: meeting, summary: summary, notes: notes,
                                      onGenerate: generateSummary)
            case .transcript: TranscriptTab(meeting: meeting, transcript: transcript,
                                            onRenameSpeakers: { showSpeakers = true },
                                            onSeek: meeting.hasRecording
                                                ? { playback.seek(to: $0, andPlay: true) }
                                                : nil)
            case .notes: NotesTab(notes: $notes, onSave: saveNotes)
            case .chat: ChatTab(meeting: meeting)
            }
        }
        // Re-runs when the meeting changes AND when a stored transcript is rewritten
        // underneath us (Redo speaker detection), so the pane never shows stale attribution.
        .task(id: "\(meeting.id)-\(app.transcriptRevision)") { await load() }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet(meetingId: meeting.id, speakers: meeting.speakers,
                          canRedo: meeting.hasRecording)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .onSubmit { saveTitle() }
                HStack(spacing: 8) {
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if meeting.durationSec > 0 { Text("· \(Theme.timestamp(meeting.durationSec))") }
                    FolderMenu(meeting: meeting)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { showSpeakers = true } label: {
                Label("Speakers", systemImage: "person.2")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data

    private func load() async {
        title = meeting.title
        transcript = try? await app.store.transcript(for: meeting.id)
        summary = await app.store.summary(for: meeting.id)
        notes = await app.store.notes(for: meeting.id)
        if meeting.hasRecording {
            playback.load(url: await app.store.recordingURL(for: meeting.id))
        }
    }

    private func generateSummary() {
        Task {
            await app.generateSummary(for: meeting.id, notes: notes)
            summary = await app.store.summary(for: meeting.id)
        }
    }

    private func saveNotes() {
        let text = notes
        Task { try? await app.store.saveNotes(text, for: meeting.id) }
    }

    private func saveTitle() {
        guard var updated = app.meetings.first(where: { $0.id == meeting.id }),
              updated.title != title, !title.isEmpty else { return }
        updated.title = title
        Task {
            try? await app.store.save(updated)
            await app.refresh()
        }
    }

}

// MARK: - Player bar

/// Full playback controls for the meeting recording: play/pause, scrubber, speed, Finder.
struct PlayerBar: View {
    @Bindable var playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(playback.ready
                                     ? AnyShapeStyle(Theme.accentGradient)
                                     : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!playback.ready)
            .help(playback.playing ? "Pause" : "Play meeting audio")

            Text(Theme.timestamp(playback.currentTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }),
                in: 0...max(1, playback.duration))
                .controlSize(.small)
                .disabled(!playback.ready)

            Text(Theme.timestamp(playback.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Menu {
                ForEach([Float(1.0), 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        playback.rate = speed
                    } label: {
                        HStack {
                            Text(speed == 1.0 ? "1×" : String(format: "%g×", speed))
                            if playback.rate == speed { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Text(playback.rate == 1.0 ? "1×" : String(format: "%g×", playback.rate))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")

            Button {
                playback.revealInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!playback.ready)
            .help("Show recording in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.background.secondary.opacity(0.5))
    }
}

// MARK: - Folder menu

struct FolderMenu: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    var body: some View {
        Menu {
            Button("None") { Task { await app.move(meetingId: meeting.id, to: nil) } }
            Divider()
            ForEach(app.folders.filter { $0.parentId == nil }) { client in
                let children = app.folders.filter { $0.parentId == client.id }
                Button(client.name) { Task { await app.move(meetingId: meeting.id, to: client.id) } }
                ForEach(children) { child in
                    Button("  \(client.name) / \(child.name)") {
                        Task { await app.move(meetingId: meeting.id, to: child.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                Text(folderLabel)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var folderLabel: String {
        guard let folderId = meeting.folderId,
              let folder = app.folders.first(where: { $0.id == folderId }) else {
            return "Unfiled"
        }
        if let parentId = folder.parentId,
           let parent = app.folders.first(where: { $0.id == parentId }) {
            return "\(parent.name) / \(folder.name)"
        }
        return folder.name
    }
}

// MARK: - Summary tab

struct SummaryTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let summary: SummaryData?
    let notes: String
    let onGenerate: () -> Void

    static func summaryText(_ s: SummaryData) -> String {
        var lines: [String] = []
        if !s.actionItems.isEmpty {
            lines.append("ACTION ITEMS:")
            for i in s.actionItems { lines.append("- \(i.owner.map { "\($0): " } ?? "")\(i.text)") }
            lines.append("")
        }
        if !s.decisions.isEmpty {
            lines.append("DECISIONS:"); s.decisions.forEach { lines.append("- \($0)") }; lines.append("")
        }
        if !s.remember.isEmpty {
            lines.append("THINGS TO REMEMBER:"); s.remember.forEach { lines.append("- \($0)") }; lines.append("")
        }
        if !s.body.isEmpty { lines.append(s.body) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary {
                    if !summary.actionItems.isEmpty {
                        SummaryCard(title: "Action Items", icon: "checklist", tint: Theme.teal) {
                            ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.teal)
                                        .padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.text).font(.system(size: 13))
                                        if let owner = item.owner {
                                            Text(owner)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Theme.indigo)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !summary.decisions.isEmpty {
                        SummaryCard(title: "Decisions", icon: "hammer", tint: Theme.indigo) {
                            ForEach(summary.decisions, id: \.self) { decision in
                                Label { Text(decision).font(.system(size: 13)) } icon: {
                                    Image(systemName: "checkmark.seal")
                                        .foregroundStyle(Theme.indigo)
                                }
                            }
                        }
                    }
                    if !summary.remember.isEmpty {
                        SummaryCard(title: "Things to Remember", icon: "brain",
                                    tint: .orange) {
                            ForEach(summary.remember, id: \.self) { item in
                                Label { Text(item).font(.system(size: 13)) } icon: {
                                    Image(systemName: "sparkle").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    MarkdownBlock(text: summary.body)
                        .padding(.horizontal, 4)

                    HStack {
                        Text("Generated \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        CopyButton(label: "Copy summary") { Self.summaryText(summary) }
                        regenerateButton(label: "Regenerate")
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.accentGradient)
                        Text("No summary yet")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("Generate an intelligent summary with action items,\ndecisions, and things to remember — powered by Claude.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        regenerateButton(label: "Generate Summary")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func regenerateButton(label: String) -> some View {
        Button {
            onGenerate()
        } label: {
            HStack(spacing: 6) {
                if app.busy.contains("summary") {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…")
                } else {
                    Image(systemName: "sparkles")
                    Text(label).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.accentGradient, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(app.busy.contains("summary") || !app.claudeAvailable)
    }
}

struct SummaryCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(tint)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.18)))
    }
}

/// Lightweight markdown rendering via AttributedString (headings split manually).
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("# ") {
                    Text(line.dropFirst(2))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .padding(.top, 6)
                } else if line.hasPrefix("## ") {
                    Text(line.dropFirst(3))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .padding(.top, 4)
                } else if line.hasPrefix("### ") {
                    Text(line.dropFirst(4))
                        .font(.system(size: 13, weight: .bold))
                        .padding(.top, 2)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text((try? AttributedString(markdown: String(line))) ?? AttributedString(line))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Transcript tab

/// Copies text to the macOS pasteboard and briefly confirms.
struct CopyButton: View {
    let label: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Label(copied ? "Copied" : label,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct TranscriptTab: View {
    let meeting: Meeting
    let transcript: Transcript?
    let onRenameSpeakers: () -> Void
    /// Present when the meeting has a recording — clicking a timestamp jumps playback there.
    var onSeek: ((Double) -> Void)?
    @State private var selected: Set<Int> = []

    private func transcriptText(_ t: Transcript) -> String { t.rendered(with: meeting) }

    /// The mic speaker is the machine owner: label it "Me" unless the user assigned a real
    /// name. Remote speakers keep their assigned name or generic "Speaker N".
    private func label(forKey key: String) -> String {
        let info = meeting.speakers[key]
        if let name = info?.name, !name.isEmpty { return name }
        if info?.source == .mic { return "Me" }
        return meeting.displayName(forSpeakerKey: key)
    }

    /// Just the selected messages, in transcript order, in the same rendered format.
    private func selectedText(_ t: Transcript) -> String {
        t.segments.filter { selected.contains($0.id) }.map { seg in
            let m = Int(seg.start) / 60, s = Int(seg.start) % 60
            let name = meeting.displayName(forSpeakerKey: seg.speaker)
            return String(format: "[%02d:%02d] %@: %@", m, s, name, seg.text)
        }.joined(separator: "\n")
    }

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(meeting.speakers.keys.sorted(), id: \.self) { key in
                                Button {
                                    onRenameSpeakers()
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle().fill(Theme.speakerColor(key))
                                            .frame(width: 7, height: 7)
                                        Text(label(forKey: key))
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Theme.speakerColor(key).opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Rename speakers")
                            }
                            Spacer()
                            Text("Click messages to select")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            CopyButton(label: "Copy all") { transcriptText(transcript) }
                        }
                        .padding(.bottom, 4)

                        ForEach(transcript.segments) { segment in
                            UtteranceBubble(
                                name: label(forKey: segment.speaker),
                                color: Theme.speakerColor(segment.speaker),
                                time: segment.start,
                                text: segment.text,
                                volatile: false,
                                selected: selected.contains(segment.id),
                                isMe: segment.source == .mic,
                                onTimeTap: onSeek.map { seek in { seek(segment.start) } })
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selected.contains(segment.id) {
                                        selected.remove(segment.id)
                                    } else {
                                        selected.insert(segment.id)
                                    }
                                }
                        }
                        // Keep the last messages reachable above the floating selection bar.
                        if !selected.isEmpty {
                            Color.clear.frame(height: 46)
                        }
                    }
                    .padding(16)
                }

                // Floating selection bar — always visible while messages are selected, no
                // matter how far the transcript is scrolled.
                if !selected.isEmpty {
                    HStack(spacing: 10) {
                        Text("\(selected.count) selected")
                            .font(.system(size: 12, weight: .semibold))
                        CopyButton(label: "Copy selected") { selectedText(transcript) }
                        Button {
                            selected.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear selection")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 12)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No transcript for this meeting")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Notes tab

struct NotesTab: View {
    @Binding var notes: String
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CopyButton(label: "Copy notes") { notes }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(14)
                .onChange(of: notes) { onSave() }
        }
    }
}
