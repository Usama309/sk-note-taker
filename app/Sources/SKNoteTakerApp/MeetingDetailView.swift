import SwiftUI
import AVFoundation
import AVKit
import AppKit
import SKNoteCore

/// A finished meeting, redesigned: a header with title/star/actions and participant avatars, a
/// WhatsApp-style waveform player (speed + volume), tabbed content, and a right rail with action
/// items and participants.
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
    /// False until load() finishes, so the pane shows a skeleton instead of flashing the
    /// "No transcript" empty state on every open.
    @State private var loaded = false
    @State private var summary: SummaryData?
    @State private var notes = ""
    @State private var title = ""
    @State private var showSpeakers = false
    @State private var playback = PlaybackController()

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            DetailTopBar(meeting: meeting, title: $title, playback: playback,
                         summary: summary, transcript: transcript,
                         onSaveTitle: saveTitle, onRenameSpeakers: { showSpeakers = true })
            DetailMetaRow(meeting: meeting, onParticipants: { showSpeakers = true })

            if meeting.hasRecording {
                WaveformPlayer(playback: playback)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    DetailTabBar(tab: $tab)
                    Divider()
                    Group {
                        switch tab {
                        case .summary:
                            SummaryTab(meeting: meeting, summary: summary, notes: notes,
                                       onGenerate: generateSummary)
                        case .transcript:
                            TranscriptTab(meeting: meeting, transcript: transcript,
                                          onRenameSpeakers: { showSpeakers = true },
                                          onSeek: meeting.hasRecording
                                              ? { playback.seek(to: $0, andPlay: true) } : nil,
                                          loading: !loaded)
                        case .notes:
                            NotesTab(notes: $notes, onSave: saveNotes)
                        case .chat:
                            ChatTab(meeting: meeting)
                        }
                    }
                    .transition(.opacity)
                    .animation(Theme.Motion.standard, value: tab)
                }
                .frame(maxWidth: .infinity)

                Divider()
                DetailRightRail(meeting: meeting, summary: summary,
                                onRenameSpeakers: { showSpeakers = true })
                    .frame(width: 292)
            }
        }
        .task(id: "\(meeting.id)-\(app.transcriptRevision)") { await load() }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet(meetingId: meeting.id, speakers: meeting.speakers,
                          canRedo: meeting.hasRecording)
        }
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
        loaded = true
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

// MARK: - Top bar

struct DetailTopBar: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    @Binding var title: String
    @Bindable var playback: PlaybackController
    let summary: SummaryData?
    let transcript: Transcript?
    let onSaveTitle: () -> Void
    let onRenameSpeakers: () -> Void

    private var siblings: [Meeting] { app.visibleMeetings }
    private func adjacent(_ offset: Int) -> Meeting? {
        guard let i = siblings.firstIndex(where: { $0.id == meeting.id }) else { return nil }
        let j = i + offset
        return siblings.indices.contains(j) ? siblings[j] : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                navButton("chevron.left", to: adjacent(-1))
                navButton("chevron.right", to: adjacent(1))
            }

            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.skHero)
                .onSubmit(onSaveTitle)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button { app.toggleStar(meeting.id) } label: {
                Image(systemName: app.isStarred(meeting.id) ? "star.fill" : "star")
                    .foregroundStyle(app.isStarred(meeting.id) ? Theme.star : Color.secondary)
                    .scaleEffect(app.isStarred(meeting.id) ? 1.14 : 1)
                    .symbolEffect(.bounce, value: app.isStarred(meeting.id))
                    .animation(Theme.Motion.spring, value: app.isStarred(meeting.id))
            }
            .buttonStyle(.plain)
            .help(app.isStarred(meeting.id) ? "Unstar" : "Star")

            Menu {
                Button { onRenameSpeakers() } label: { Label("Rename speakers", systemImage: "person.2") }
                MoveToFolderMenu(meetingId: meeting.id)
                Divider()
                Button(role: .destructive) {
                    Task { await app.delete(meetingId: meeting.id) }
                } label: { Label("Delete meeting", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.skSection)
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button { Task { await app.startMeeting() } } label: {
                Label("New recording", systemImage: "record.circle")
                    .font(.skLabel)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(app.session != nil)

            Menu {
                if let summary {
                    Button("Copy summary") { copy(SummaryTab.summaryText(summary)) }
                }
                if let transcript, !transcript.segments.isEmpty {
                    Button("Copy transcript") { copy(transcript.rendered(with: meeting)) }
                }
                if meeting.hasRecording {
                    Button("Show recording in Finder") { playback.revealInFinder() }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func navButton(_ icon: String, to target: Meeting?) -> some View {
        Button { if let target { app.selectedMeetingId = target.id } } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .disabled(target == nil)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Metadata row

struct DetailMetaRow: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let onParticipants: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            meta("calendar", meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
            meta("clock", meeting.createdAt.formatted(date: .omitted, time: .shortened))
            if meeting.durationSec > 0 {
                meta("timer", Theme.timestamp(meeting.durationSec))
            }
            FolderMenu(meeting: meeting)

            Spacer()

            Button(action: onParticipants) {
                HStack(spacing: -6) {
                    ForEach(meeting.speakers.keys.sorted().prefix(4), id: \.self) { key in
                        SpeakerAvatar(meeting: meeting, key: key, size: 24)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    }
                    if !meeting.speakers.isEmpty {
                        Text("Edit")
                            .font(.skCaption)
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 12)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Rename speakers")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func meta(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.skCallout)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Waveform player

struct WaveformPlayer: View {
    @Bindable var playback: PlaybackController
    @State private var showVolume = false

    private var progress: Double {
        playback.duration > 0 ? min(1, playback.currentTime / playback.duration) : 0
    }

    /// Media keys for the player: Space toggles, arrows seek 5s. Mounted as zero-sized buttons so
    /// they only fire while a recording is open and never steal keys from a focused text field.
    private var playbackKeys: some View {
        Group {
            Button("") { playback.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { playback.seek(to: max(0, playback.currentTime - 5), andPlay: playback.playing) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { playback.seek(to: min(playback.duration, playback.currentTime + 5), andPlay: playback.playing) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0)
        .disabled(!playback.ready)
        .accessibilityHidden(true)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .font(.skSection)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(playback.ready ? AnyShapeStyle(Theme.accentGradient)
                                : AnyShapeStyle(Color.secondary), in: Circle())
                    .shadow(color: Theme.accent.opacity(playback.ready ? 0.35 : 0), radius: 6, y: 2)
                    .animation(Theme.Motion.spring, value: playback.playing)
            }
            .buttonStyle(.plain)
            .disabled(!playback.ready)
            .background(playbackKeys)

            Text(Theme.timestamp(playback.currentTime))
                .font(.skMonoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            Group {
                if playback.waveform.isEmpty {
                    ProgressBarLine(progress: progress) { playback.seek(to: $0 * playback.duration) }
                } else {
                    WaveformView(bars: playback.waveform, progress: progress) {
                        playback.seek(to: $0 * playback.duration)
                    }
                }
            }
            .frame(height: 34)
            .frame(maxWidth: .infinity)

            Text(Theme.timestamp(playback.duration))
                .font(.skMonoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Menu {
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        playback.rate = speed
                    } label: {
                        HStack {
                            Text(String(format: "%g×", speed))
                            if playback.rate == speed { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Text(String(format: "%g×", playback.rate))
                    .font(.skLabel)
                    .frame(width: 34, height: 24)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")

            Button { showVolume.toggle() } label: {
                Image(systemName: playback.volume == 0 ? "speaker.slash.fill"
                      : playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!playback.ready)
            .popover(isPresented: $showVolume, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $playback.volume, in: 0...1).frame(width: 130)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .help("Volume")
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// WhatsApp-style amplitude bars. Played portion is tinted; the rest is muted. Click/drag seeks.
struct WaveformView: View {
    let bars: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let count = max(bars.count, 1)
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    let played = Double(i) / Double(count) <= progress
                    Capsule()
                        .fill(played ? AnyShapeStyle(Theme.accentTextGradient)
                              : AnyShapeStyle(Theme.textSecondary.opacity(0.55)))
                        .frame(height: max(3, CGFloat(bars[i]) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(Theme.Motion.snap, value: progress)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { onSeek(min(1, max(0, $0.location.x / geo.size.width))) })
        }
    }
}

struct ProgressBarLine: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textSecondary.opacity(0.22)).frame(height: 5)
                Capsule().fill(Theme.accentTextGradient)
                    .frame(width: geo.size.width * progress, height: 5)
            }
            .animation(Theme.Motion.snap, value: progress)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { onSeek(min(1, max(0, $0.location.x / geo.size.width))) })
        }
    }
}

// MARK: - Tab bar (underline)

struct DetailTabBar: View {
    @Binding var tab: MeetingDetailView.Tab
    /// Lets the single underline capsule slide between tabs instead of blinking on and off.
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 24) {
            ForEach(MeetingDetailView.Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    VStack(spacing: 7) {
                        Text(t.rawValue)
                            .font(tab == t ? .skSubtitle : .skBody)
                            .foregroundStyle(tab == t ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        ZStack {
                            Capsule().fill(Color.clear)
                            if tab == t {
                                Capsule()
                                    .fill(Theme.accentTextGradient)
                                    .matchedGeometryEffect(id: "detailTabUnderline", in: underline)
                            }
                        }
                        .frame(height: 2.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .animation(Theme.Motion.standard, value: tab)
    }
}

// MARK: - Right rail (action items + participants)

struct DetailRightRail: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let summary: SummaryData?
    let onRenameSpeakers: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if meeting.recordedScreen {
                    ScreenRecordingCard(meeting: meeting)
                }
                ActionItemsCard(meeting: meeting, items: summary?.actionItems ?? [])
                ParticipantsCard(meeting: meeting, onRename: onRenameSpeakers)
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Theme.bg)
    }
}

/// AVKit's AppKit player view, wrapped for SwiftUI.
///
/// We deliberately avoid SwiftUI's `VideoPlayer`: its `_AVKit_SwiftUI` backing aborts with a
/// Swift metadata fatal error (`getSuperclassMetadata`) when instantiated on this macOS build,
/// which crashed the whole app whenever a meeting with a recording was opened. `AVPlayerView`
/// is a plain `NSView` and never touches that framework.
private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// The meeting's screen recording, if one was captured.
struct ScreenRecordingCard: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    @State private var player: AVPlayer?
    @State private var fileURL: URL?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Screen recording", systemImage: "rectangle.on.rectangle")
                    .font(.skSubtitle)
                Spacer()
                if let fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.skCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            if let player {
                RecordingPlayerView(player: player)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if missing {
                Text("The recording file could not be found.")
                    .font(.skCaption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skCard()
        .task {
            let url = await app.screenRecordingURL(for: meeting.id)
            if FileManager.default.fileExists(atPath: url.path) {
                fileURL = url
                player = AVPlayer(url: url)
            } else {
                missing = true
            }
        }
    }
}

struct ActionItemsCard: View {
    let meeting: Meeting
    let items: [SummaryData.ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Action items").font(.skSection)
                Spacer()
                Text("\(items.count)")
                    .font(.skCaptionStrong)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            if items.isEmpty {
                Text("No action items yet. Generate a summary to extract them.")
                    .font(.skCallout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.text).font(.skCallout).fixedSize(horizontal: false, vertical: true)
                            if let owner = item.owner, !owner.isEmpty {
                                HStack(spacing: 5) {
                                    OwnerBadge(meeting: meeting, owner: owner)
                                    Text(owner).font(.skCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if item.text != items.last?.text { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skCard()
    }
}

struct ParticipantsCard: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let onRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Participants").font(.skSection)
                Spacer()
                Button(action: onRename) {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Rename speakers")
            }
            if meeting.speakers.isEmpty {
                Text("No speakers detected.").font(.skCallout).foregroundStyle(.secondary)
            } else {
                ForEach(meeting.speakers.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 9) {
                        SpeakerAvatar(meeting: meeting, key: key, size: 26)
                        Text(participantName(key)).font(.skCallout)
                        Spacer()
                        if meeting.speakers[key]?.source == .mic {
                            Text("Host")
                                .font(.skFootnoteStrong)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .skCard()
    }

    private func participantName(_ key: String) -> String {
        let info = meeting.speakers[key]
        if let name = info?.name, !name.isEmpty { return name }
        if info?.source == .mic { return app.userDisplayName }
        return meeting.displayName(forSpeakerKey: key)
    }
}

/// Circular initials avatar coloured by speaker.
struct SpeakerAvatar: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let key: String
    var size: CGFloat = 24

    private var short: String {
        let info = meeting.speakers[key]
        if info?.source == .mic {
            let name = (info?.name?.isEmpty == false ? info!.name! : app.userDisplayName)
            return String(name.prefix(1)).uppercased()
        }
        return key   // "S2", "S3"
    }

    var body: some View {
        Text(short)
            .font(.system(size: size * (short.count > 1 ? 0.36 : 0.46), weight: .bold))
            // The avatar fill is speakerColor, which is dark on light and BRIGHT on dark, so the
            // ink has to invert with it: white initials on the bright dark-mode fills were ~2:1.
            .foregroundStyle(Color(light: .white, dark: Theme.charcoal))
            .frame(width: size, height: size)
            .background(Theme.speakerColor(key), in: Circle())
    }
}

struct OwnerBadge: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let owner: String

    /// Match the owner string to a speaker key when possible (for the right colour), else the accent.
    private var key: String? {
        meeting.speakers.first { (k, info) in
            (info.name?.caseInsensitiveCompare(owner) == .orderedSame)
            || (info.source == .mic && app.userDisplayName.caseInsensitiveCompare(owner) == .orderedSame)
            || k.caseInsensitiveCompare(owner) == .orderedSame
        }?.key
    }

    var body: some View {
        Text(String(owner.prefix(1)).uppercased())
            .font(.skBadge)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(key.map(Theme.speakerColor) ?? Theme.accent, in: Circle())
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
            .font(.skCallout)
            .foregroundStyle(.secondary)
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
        if !s.body.isEmpty { lines.append(s.body); lines.append("") }
        if !s.decisions.isEmpty {
            lines.append("DECISIONS:"); s.decisions.forEach { lines.append("- \($0)") }; lines.append("")
        }
        if !s.actionItems.isEmpty {
            lines.append("ACTION ITEMS:")
            for i in s.actionItems { lines.append("- \(i.owner.map { "\($0): " } ?? "")\(i.text)") }
            lines.append("")
        }
        if !s.remember.isEmpty {
            lines.append("THINGS TO REMEMBER:"); s.remember.forEach { lines.append("- \($0)") }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            if let summary {
                VStack(alignment: .leading, spacing: 24) {
                    MarkdownBlock(text: summary.body)

                    if !summary.decisions.isEmpty {
                        section("Decisions", tint: Theme.mint) {
                            ForEach(summary.decisions, id: \.self) { d in
                                bullet(icon: "checkmark.circle.fill", tint: Theme.mint, text: d)
                            }
                        }
                    }
                    if !summary.remember.isEmpty {
                        section("Things to remember", tint: Theme.warning) {
                            ForEach(summary.remember, id: \.self) { r in
                                bullet(icon: "sparkle", tint: Theme.warning, text: r)
                            }
                        }
                    }

                    HStack {
                        Text("Generated \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.skCaption).foregroundStyle(.tertiary)
                        Spacer()
                        CopyButton(label: "Copy summary") { Self.summaryText(summary) }
                        regenerateButton(label: "Regenerate")
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 34))
                        .foregroundStyle(Theme.accentTextGradient)
                    Text("No summary yet").font(.skTitle)
                    Text("Generate an intelligent summary with an overview, decisions,\nand action items — powered by Claude.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .font(.skBody)
                    regenerateButton(label: "Generate Summary")
                }
                .frame(maxWidth: .infinity).padding(.top, 70)
            }
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, tint: Color = Theme.accent,
                                               @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Capsule().fill(tint).frame(width: 3, height: 16)
                Text(title).font(.skHeadline)
            }
            content()
        }
    }

    private func bullet(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).padding(.top, 2)
            Text(text).font(.skBody).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func regenerateButton(label: String) -> some View {
        Button(action: onGenerate) {
            HStack(spacing: 6) {
                if app.busy.contains("summary") {
                    ProgressView().controlSize(.small); Text("Summarizing…")
                } else {
                    Image(systemName: "sparkles"); Text(label).fontWeight(.semibold)
                }
            }
            .font(.skCallout)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.accentGradient, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(app.busy.contains("summary") || !app.claudeAvailable)
    }
}

/// Lightweight markdown rendering via AttributedString (headings split manually).
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("# ") {
                    Text(line.dropFirst(2)).font(.skTitle).padding(.top, 6)
                } else if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.skHeadline).padding(.top, 4)
                } else if line.hasPrefix("### ") {
                    Text(line.dropFirst(4)).font(.skSubtitle).padding(.top, 2)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text((try? AttributedString(markdown: String(line))) ?? AttributedString(line))
                        .font(.skBody).textSelection(.enabled).lineSpacing(2)
                }
            }
        }
    }
}

// MARK: - Copy button

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
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.skCaption)
                .contentTransition(.opacity)
                .symbolEffect(.bounce, value: copied)
                .animation(Theme.Motion.spring, value: copied)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Transcript tab

struct TranscriptTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let transcript: Transcript?
    let onRenameSpeakers: () -> Void
    var onSeek: ((Double) -> Void)?
    /// True until the meeting's data has loaded, so we show a skeleton rather than flashing the
    /// "No transcript" empty state on every open.
    var loading = false
    @State private var selected: Set<Int> = []

    private func transcriptText(_ t: Transcript) -> String { t.rendered(with: meeting) }

    private func label(forKey key: String) -> String {
        let info = meeting.speakers[key]
        if let name = info?.name, !name.isEmpty { return name }
        if info?.source == .mic { return app.userDisplayName }
        return meeting.displayName(forSpeakerKey: key)
    }

    private func selectedText(_ t: Transcript) -> String {
        t.segments.filter { selected.contains($0.id) }.map { seg in
            let m = Int(seg.start) / 60, s = Int(seg.start) % 60
            let name = meeting.displayName(forSpeakerKey: seg.speaker)
            return String(format: "[%02d:%02d] %@: %@", m, s, name, seg.text)
        }.joined(separator: "\n")
    }

    var body: some View {
        if loading {
            SkeletonTranscript()
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let transcript, !transcript.segments.isEmpty {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(meeting.speakers.keys.sorted(), id: \.self) { key in
                                Button(action: onRenameSpeakers) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Theme.speakerColor(key)).frame(width: 7, height: 7)
                                        Text(label(forKey: key)).font(.skCaptionStrong)
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Theme.speakerColor(key).opacity(0.16), in: Capsule())
                                }
                                .buttonStyle(.plain).help("Rename speakers")
                            }
                            Spacer()
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
                                    if selected.contains(segment.id) { selected.remove(segment.id) }
                                    else { selected.insert(segment.id) }
                                }
                        }
                        if !selected.isEmpty { Color.clear.frame(height: 46) }
                    }
                    .padding(16)
                }
                if !selected.isEmpty {
                    HStack(spacing: 10) {
                        Text("\(selected.count) selected").font(.skLabel)
                        CopyButton(label: "Copy selected") { selectedText(transcript) }
                        Button { selected.removeAll() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Clear selection")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(color: Theme.cardShadow, radius: 8, y: 2)
                    .padding(.bottom, 12)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("No transcript for this meeting").foregroundStyle(.secondary)
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
            .padding(.horizontal, 14).padding(.top, 10)
            TextEditor(text: $notes)
                .font(.skBody)
                .scrollContentBackground(.hidden)
                .padding(14)
                .onChange(of: notes) { onSave() }
        }
    }
}
