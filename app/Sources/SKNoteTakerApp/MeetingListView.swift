import SwiftUI
import SKNoteCore

struct MeetingListView: View {
    @Environment(AppState.self) private var app
    @FocusState private var searchFocused: Bool
    /// How many rows are rendered. Grows as the user reaches the end, so a long history does not
    /// build every row up front. Search resets it.
    @State private var windowSize = 30
    private static let pageSize = 30

    /// The slice of the filtered list that is actually rendered.
    private var windowed: [Meeting] {
        Array(app.visibleMeetings.prefix(windowSize))
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // Cmd+F focuses the search field from anywhere in the app.
            .onChange(of: app.focusSearch) { searchFocused = true }
            // A new search starts from the top of a fresh window.
            .onChange(of: app.searchText) { windowSize = Self.pageSize }
            .onChange(of: app.libraryFilter) { windowSize = Self.pageSize }

            if app.visibleMeetings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accentGradient)
                    Text(app.searchText.isEmpty ? "No meetings yet" : "No matches")
                        .font(.skHeadline)
                    if app.searchText.isEmpty {
                        Text("Hit Start Meeting to record your first one.")
                            .font(.skCallout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else {
                List(selection: $app.selectedMeetingId) {
                    ForEach(windowed) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .draggable(meeting.id.uuidString)   // drag onto a sidebar folder to file it
                            .contextMenu {
                                MoveToFolderMenu(meetingId: meeting.id)
                                Button("Delete Meeting", role: .destructive) {
                                    Task { await app.delete(meetingId: meeting.id) }
                                }
                            }
                            .onAppear {
                                // Reached the end of the rendered window: extend it.
                                if meeting.id == windowed.last?.id,
                                   windowSize < app.visibleMeetings.count {
                                    windowSize += Self.pageSize
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Rows added or removed (new recording, delete, filter change) slide in instead of
                // popping. Paging the window in does not change this count, so scrolling stays instant.
                .animation(Theme.Motion.standard, value: app.visibleMeetings.count)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if app.session == nil {
                RecordButton()
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle("")
    }
}

/// Right-click "Move to Folder" submenu — the keyboard/precise counterpart to dragging a
/// meeting onto a sidebar folder.
struct MoveToFolderMenu: View {
    @Environment(AppState.self) private var app
    let meetingId: UUID

    var body: some View {
        Menu("Move to Folder") {
            Button("All Meetings (unfiled)") {
                Task { await app.move(meetingId: meetingId, to: nil) }
            }
            let clients = app.folders.filter { $0.parentId == nil }
            if !clients.isEmpty {
                Divider()
                ForEach(clients) { folder in
                    Button(folder.name) {
                        Task { await app.move(meetingId: meetingId, to: folder.id) }
                    }
                }
            }
        }
    }
}

struct MeetingRow: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    @State private var hovering = false
    /// Flipped on once the LIVE badge exists so its opacity has something to breathe between.
    @State private var livePulse = false

    private var isLive: Bool { app.session?.meeting.id == meeting.id }
    // The selected row's background is the accent fill (blue when focused, grey when not), on which
    // the tinted speaker chips are unreadable; switch them to a solid card pill there.
    private var isSelected: Bool { app.selectedMeetingId == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meeting.title)
                    .font(.skSubtitle)
                    .lineLimit(1)
                Spacer()
                if isLive {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.recording).frame(width: 7, height: 7)
                        Text("LIVE").font(.skBadge)
                    }
                    .foregroundStyle(Theme.recording)
                    // Slow breath while this row is the one recording. The badge only exists while
                    // live, so the pulse starts and stops with the session.
                    .opacity(livePulse ? 0.55 : 1)
                    .animation(Theme.Motion.breathe, value: livePulse)
                    .onAppear { livePulse = Theme.Motion.breathingEnabled }
                    .onDisappear { livePulse = false }
                }
            }
            HStack(spacing: 6) {
                Text(meeting.createdAt.formatted(.relative(presentation: .named)))
                if meeting.durationSec > 0 {
                    Text("·")
                    Text(Theme.timestamp(meeting.durationSec))
                }
                if meeting.hasRecording {
                    Image(systemName: "waveform").font(.system(size: 9))
                }
            }
            .font(.skCaption)
            .foregroundStyle(.secondary)

            if !meeting.speakers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.speakers.keys.sorted(), id: \.self) { key in
                        Text(meeting.displayName(forSpeakerKey: key))
                            .font(.skFootnote)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                isSelected ? Theme.card : Theme.speakerColor(key).opacity(0.16),
                                in: Capsule())
                            .foregroundStyle(Theme.speakerColor(key))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // Hover lift. Skipped while selected, where the list's own selection fill owns the row.
        .background(Theme.surface.opacity(hovering && !isSelected ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snap, value: hovering)
    }
}
