import SwiftUI
import SKNoteCore

struct MeetingListView: View {
    @Environment(AppState.self) private var app
    @FocusState private var searchFocused: Bool

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
                    ForEach(app.visibleMeetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .draggable(meeting.id.uuidString)   // drag onto a sidebar folder to file it
                            .contextMenu {
                                MoveToFolderMenu(meetingId: meeting.id)
                                Button("Delete Meeting", role: .destructive) {
                                    Task { await app.delete(meetingId: meeting.id) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
    }
}
