import SwiftUI
import SKNoteCore

struct MeetingListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: $app.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if app.visibleMeetings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accentGradient)
                    Text(app.searchText.isEmpty ? "No meetings yet" : "No matches")
                        .font(.headline)
                    if app.searchText.isEmpty {
                        Text("Hit Start Meeting to record your first one.")
                            .font(.callout)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isLive {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("LIVE").font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(.red)
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if !meeting.speakers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.speakers.keys.sorted(), id: \.self) { key in
                        Text(meeting.displayName(forSpeakerKey: key))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.speakerColor(key).opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.speakerColor(key))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
