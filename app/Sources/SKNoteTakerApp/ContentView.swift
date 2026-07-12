import SwiftUI
import SKNoteCore

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } content: {
            MeetingListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if let session = app.session {
                LiveMeetingView(session: session)
            } else if let meeting = app.selectedMeeting {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                EmptyDetailView()
            }
        }
        .alert("Something went wrong", isPresented: .init(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var newFolderName = ""
    @State private var addingFolder = false

    private var clients: [Folder] { app.folders.filter { $0.parentId == nil } }

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedFolderId) {
            Section {
                Label {
                    Text("All Meetings")
                } icon: {
                    Image(systemName: "tray.full")
                        .foregroundStyle(Theme.accentGradient)
                }
                .tag(nil as UUID?)
                .badge(app.meetings.count)
            }

            Section("Projects & Clients") {
                ForEach(clients) { client in
                    let children = app.folders.filter { $0.parentId == client.id }
                    if children.isEmpty {
                        folderRow(client)
                    } else {
                        DisclosureGroup {
                            ForEach(children) { folderRow($0) }
                        } label: {
                            folderRow(client)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            BrandTitle()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if addingFolder {
                    TextField("Client or project name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addFolder() }
                        .padding(.horizontal, 10)
                }
                Button {
                    if addingFolder { addFolder() } else { addingFolder = true }
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: folder.kind == .client ? "building.2" : "folder")
                .foregroundStyle(folder.kind == .client ? Theme.indigo : Theme.teal)
        }
        .tag(folder.id as UUID?)
        .badge(app.meetings.filter { $0.folderId == folder.id }.count)
        .contextMenu {
            Button("Delete Folder", role: .destructive) {
                Task {
                    try? await app.folderStore.remove(id: folder.id)
                    await app.refresh()
                }
            }
        }
    }

    private func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { addingFolder = false; return }
        Task {
            _ = try? await app.folderStore.add(
                Folder(name: name, kind: .client, parentId: nil))
            newFolderName = ""
            addingFolder = false
            await app.refresh()
        }
    }
}

// MARK: - Empty state

struct EmptyDetailView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 72)
                .shadow(color: Theme.indigo.opacity(0.35), radius: 18, y: 6)
            Text("Ready when you are")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Start a meeting to capture mic and system audio\nwith live, speaker-aware transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            RecordButton()
                .padding(.top, 6)
            if !app.claudeAvailable {
                Label("Claude Code CLI not detected — AI features disabled",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button {
            Task { await app.startMeeting() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                Text("Start Meeting")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Theme.accentGradient, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(app.session != nil)
        .keyboardShortcut("n", modifiers: [.command])
    }
}
