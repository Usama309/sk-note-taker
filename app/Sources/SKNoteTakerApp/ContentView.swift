import SwiftUI
import SKNoteCore

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.compactMode, let session = app.session {
                CompactLiveView(session: session)
            } else {
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
            }
        }
        .frame(minWidth: app.compactMode ? 260 : 1080,
               minHeight: app.compactMode ? 360 : 680)
        .background(WindowAccessor { app.mainWindow = $0 })
        .alert("Something went wrong", isPresented: .init(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var newFolderName = ""
    @State private var addingFolder = false
    /// "all" / "starred" / a folder uuid string while a meeting is dragged over (for highlight).
    @State private var dropTarget: String?

    private var clients: [Folder] { app.folders.filter { $0.parentId == nil } }
    private var starredCount: Int {
        app.meetings.reduce(0) { $0 + (app.starred.contains($1.id) ? 1 : 0) }
    }
    private var initials: String { String(app.userDisplayName.prefix(1)).uppercased() }

    /// Row background reflecting both the current filter selection and an active drag-over.
    private func rowBackground(token: String, selected: Bool) -> Color {
        if dropTarget == token { return Theme.teal.opacity(0.30) }
        return selected ? Theme.indigo.opacity(0.14) : .clear
    }

    private func setDrop(_ token: String, _ over: Bool) {
        if over { dropTarget = token } else if dropTarget == token { dropTarget = nil }
    }

    /// A meeting (or several) was dropped onto a folder (nil = unfile to All Meetings).
    private func dropMeetings(_ items: [String], to folderId: UUID?) -> Bool {
        let ids = items.compactMap { UUID(uuidString: $0) }
        guard !ids.isEmpty else { return false }
        Task { for id in ids { await app.move(meetingId: id, to: folderId) } }
        return true
    }

    /// Stable colour per project (UUID hashValue is per-run, so seed from the string).
    private func folderColor(_ folder: Folder) -> Color {
        let palette: [Color] = [Theme.indigo, Theme.teal, .orange, .pink, .blue, .green, .purple]
        let seed = folder.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[seed % palette.count]
    }

    var body: some View {
        // Rows are Buttons, not `List(selection:)` — selection-driven sidebar rows don't register
        // clicks reliably. A Button always fires; the current filter shows as a row highlight.
        List {
            Section("Library") {
                Button { app.libraryFilter = .all } label: {
                    rowLabel(icon: AnyView(Image(systemName: "tray.full")
                        .foregroundStyle(Theme.accentGradient)),
                        title: "All Meetings", count: app.meetings.count)
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBackground(token: "all", selected: app.libraryFilter == .all))
                .dropDestination(for: String.self, action: { items, _ in dropMeetings(items, to: nil) },
                                 isTargeted: { setDrop("all", $0) })

                Button { app.libraryFilter = .starred } label: {
                    rowLabel(icon: AnyView(Image(systemName: "star.fill").foregroundStyle(Color.yellow)),
                             title: "Starred", count: starredCount)
                }
                .buttonStyle(.plain)
                .listRowBackground(rowBackground(token: "starred", selected: app.libraryFilter == .starred))
            }

            Section {
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
                if clients.isEmpty {
                    Text("No projects yet — drag a meeting here or tap +")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { addingFolder = true } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New project")
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
            VStack(spacing: 8) {
                if addingFolder {
                    TextField("Project name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addFolder() }
                        .padding(.horizontal, 10)
                }
                Divider()
                HStack(spacing: 9) {
                    Circle().fill(Theme.accentGradient).frame(width: 30, height: 30)
                        .overlay(Text(initials).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.userDisplayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("Local workspace").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Settings")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func rowLabel(icon: AnyView, title: String, count: Int) -> some View {
        HStack(spacing: 9) {
            icon.frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func folderRow(_ folder: Folder) -> some View {
        Button { app.libraryFilter = .folder(folder.id) } label: {
            HStack(spacing: 9) {
                Circle().fill(folderColor(folder)).frame(width: 9, height: 9)
                Text(folder.name).font(.system(size: 13)).lineLimit(1)
                Spacer()
                Text("\(app.meetings.filter { $0.folderId == folder.id }.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(token: folder.id.uuidString,
                                         selected: app.libraryFilter == .folder(folder.id)))
        .dropDestination(for: String.self, action: { items, _ in dropMeetings(items, to: folder.id) },
                         isTargeted: { setDrop(folder.id.uuidString, $0) })
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
        .accessibilityLabel("Start Meeting")
    }
}
