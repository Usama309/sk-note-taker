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
                    Group {
                        if app.libraryFilter == .upcoming {
                            UpcomingListView()
                        } else {
                            MeetingListView()
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 330)
                } detail: {
                    if let session = app.session {
                        LiveMeetingView(session: session)
                    } else if app.libraryFilter == .upcoming, let event = app.selectedEvent {
                        EventDetailView(event: event)
                            .id(event.id)
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
        .sheet(isPresented: $app.showScreenSourcePicker) {
            ScreenSourceSheet { filter in app.startScreenRecording(filter: filter) }
        }
        .sheet(item: $app.projectMemoryTarget) { ProjectMemorySheet(project: $0) }
        .sheet(isPresented: $app.showAppAssistant) { AppAssistantSheet() }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var newFolderName = ""
    @State private var addingFolder = false
    /// "all" / "starred" / a folder uuid string while a meeting is dragged over (for highlight).
    @State private var dropTarget: String?
    @State private var hoveredFolder: UUID?
    /// Folders currently expanded to reveal their recordings inline.
    @State private var expandedFolders: Set<UUID> = []

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
                Button { app.showAppAssistant = true } label: {
                    rowLabel(icon: AnyView(Image(systemName: "sparkles").foregroundStyle(Theme.indigo)),
                             title: "Assistant", count: 0)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)

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

                if app.calendarConnected {
                    Button { app.libraryFilter = .upcoming } label: {
                        rowLabel(icon: AnyView(Image(systemName: "calendar").foregroundStyle(Theme.teal)),
                                 title: "Upcoming", count: app.upcomingEvents.count)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(rowBackground(token: "upcoming", selected: app.libraryFilter == .upcoming))
                }
            }

            Section {
                ForEach(clients) { client in
                    folderGroup(client)
                }
                if clients.isEmpty {
                    Text("No projects yet. Drag a meeting here or click +.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
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
                        Text(app.userDisplayName).font(.skLabel).lineLimit(1)
                        Text("Local workspace").font(.skFootnote).foregroundStyle(.secondary)
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
            Text(title).font(.skBody)
            Spacer()
            countBadge(count)
        }
        .contentShape(Rectangle())
    }

    /// Subtle count chip shown on sidebar rows (hidden when zero, so empty rows stay clean).
    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.skCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }

    /// Meetings filed directly in a folder plus those in its sub-folders (matches the
    /// middle-column filter), so an expanded folder shows every recording under it.
    private func recordings(under folder: Folder) -> [Meeting] {
        let childIds = Set(app.folders.filter { $0.parentId == folder.id }.map(\.id))
        return app.meetings.filter { m in
            m.folderId == folder.id || (m.folderId.map { childIds.contains($0) } ?? false)
        }
    }

    /// A folder header row plus, when expanded, an indented row per recording inside it.
    @ViewBuilder
    private func folderGroup(_ folder: Folder) -> some View {
        let recs = recordings(under: folder)
        let isOpen = expandedFolders.contains(folder.id)
        folderHeaderRow(folder, count: recs.count, isOpen: isOpen)
        if isOpen {
            if recs.isEmpty {
                Text("No recordings yet")
                    .font(.skCaption).foregroundStyle(.tertiary)
                    .padding(.leading, 20)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(recs) { nestedMeetingRow($0) }
            }
        }
    }

    private func folderHeaderRow(_ folder: Folder, count: Int, isOpen: Bool) -> some View {
        // Whole-row click opens the folder (and filters the middle list); the chevron shows state.
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expandedFolders.contains(folder.id) {
                    expandedFolders.remove(folder.id)
                } else {
                    expandedFolders.insert(folder.id)
                    app.libraryFilter = .folder(folder.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                Circle().fill(folderColor(folder)).frame(width: 9, height: 9)
                Text(folder.name).font(.skBody).lineLimit(1)
                Spacer()
                countBadge(count)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hoveredFolder == folder.id {
                HStack(spacing: 10) {
                    Button {
                        app.projectMemoryTarget = ProjectRef(id: folder.id, name: folder.name)
                    } label: { Image(systemName: "brain") }
                        .help("Project memory")
                    Button {
                        app.openProjectFolder(folder.id)
                    } label: { Image(systemName: "folder") }
                        .help("Open the project folder in Finder")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .background(rowBackground(token: folder.id.uuidString,
                                          selected: app.libraryFilter == .folder(folder.id)))
            }
        }
        .onHover { hovering in
            if hovering { hoveredFolder = folder.id }
            else if hoveredFolder == folder.id { hoveredFolder = nil }
        }
        .listRowBackground(rowBackground(token: folder.id.uuidString,
                                         selected: app.libraryFilter == .folder(folder.id)))
        .dropDestination(for: String.self, action: { items, _ in dropMeetings(items, to: folder.id) },
                         isTargeted: { setDrop(folder.id.uuidString, $0) })
        .contextMenu {
            Button("Project memory…", systemImage: "brain") {
                app.projectMemoryTarget = ProjectRef(id: folder.id, name: folder.name)
            }
            Button("Open Project Folder", systemImage: "folder") {
                app.openProjectFolder(folder.id)
            }
            Button("Export Project…", systemImage: "square.and.arrow.up") {
                app.exportProject(ProjectRef(id: folder.id, name: folder.name))
            }
            Divider()
            Button(isOpen ? "Collapse" : "Expand") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expandedFolders.remove(folder.id) } else { expandedFolders.insert(folder.id) }
                }
            }
            Button("Delete Folder", role: .destructive) {
                Task {
                    try? await app.folderStore.remove(id: folder.id)
                    await app.refresh()
                }
            }
        }
    }

    private func nestedMeetingRow(_ meeting: Meeting) -> some View {
        Button {
            app.selectedMeetingId = meeting.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: meeting.hasRecording ? "waveform" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(meeting.title).font(.skCallout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(app.selectedMeetingId == meeting.id
                           ? Theme.indigo.opacity(0.14) : Color.clear)
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
        VStack(spacing: 24) {
            LogoMark(size: 88)
                .shadow(color: Theme.indigo.opacity(0.5), radius: 30, y: 12)
            VStack(spacing: 10) {
                Text("Ready when you are")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentGradient)
                Text("Capture mic and system audio with live, speaker-aware transcription.")
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
            }
            RecordButton(prominent: true)
                .padding(.top, 4)
            if app.micStatus != .granted || app.systemAudioStatus != .granted {
                SetupHint()
            }
            if app.calendarConnected && !app.upcomingEvents.isEmpty {
                UpcomingEventsCard()
                    .padding(.top, 10)
            }
            if !app.claudeAvailable {
                Label("Claude Code CLI not detected. AI features disabled.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RadialGradient(
                    colors: [Theme.indigo.opacity(0.12), Theme.teal.opacity(0.05), .clear],
                    center: .center, startRadius: 0, endRadius: 360)
                    .offset(y: -110)
                    .blendMode(.plusLighter)
            }
            .ignoresSafeArea()
        )
        .task { app.refreshPermissions() }
    }
}

/// A gentle onboarding nudge on the home screen when the recording permissions aren't ready yet,
/// so a first meeting doesn't come out silent.
struct SetupHint: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setup to record").font(.skLabel)
                Text(missing).font(.skCaption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SettingsLink { Text("Open Settings").font(.skCallout) }
                .buttonStyle(.plain).foregroundStyle(Theme.indigo)
        }
        .padding(12)
        .frame(width: 380)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.25)))
        .padding(.top, 8)
    }

    private var missing: String {
        var parts: [String] = []
        if app.micStatus != .granted { parts.append("Microphone") }
        if app.systemAudioStatus != .granted { parts.append("System Audio") }
        return "Grant " + parts.joined(separator: " and ") + " so your meetings aren't silent."
    }
}

/// The next few Google Calendar events, shown on the home screen once the calendar is connected.
struct UpcomingEventsCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Upcoming", systemImage: "calendar")
                    .font(.skSubtitle)
                Spacer()
                Button("See all") { app.libraryFilter = .upcoming }
                    .buttonStyle(.plain).font(.skCaption)
                    .foregroundStyle(Theme.indigo)
                Button { Task { await app.refreshUpcoming() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
            }
            ForEach(app.upcomingEvents.prefix(4)) { ev in
                HStack(spacing: 10) {
                    Button {
                        app.libraryFilter = .upcoming
                        app.selectEvent(ev.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ev.title).font(.skCallout).lineLimit(1)
                            Text(Self.whenLabel(ev)).font(.skFootnote).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    if let url = ev.meetingURL {
                        Link("Join", destination: url).controlSize(.small)
                    }
                    Button("Start notes") { Task { await app.startNotes(for: ev) } }
                        .controlSize(.small)
                        .disabled(app.session != nil)
                }
            }
        }
        .frame(width: 380)
        .skCard(.quaternary.opacity(0.35))
    }

    private static func whenLabel(_ ev: GoogleCalendarEvent) -> String {
        let df = DateFormatter()
        df.dateFormat = ev.isAllDay ? "EEE, MMM d" : "EEE h:mm a"
        return df.string(from: ev.start)
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var app
    var prominent = false

    var body: some View {
        Button {
            Task { await app.startMeeting() }
        } label: {
            HStack(spacing: prominent ? 10 : 8) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: prominent ? 16 : 13))
                Text("Start Meeting")
                    .font(.system(size: prominent ? 15 : 13, weight: .semibold))
            }
            .padding(.horizontal, prominent ? 30 : 22)
            .padding(.vertical, prominent ? 14 : 11)
            .background(Theme.accentGradient, in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: Theme.indigo.opacity(prominent ? 0.4 : 0), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(app.session != nil)
        .keyboardShortcut("n", modifiers: [.command])
        .accessibilityLabel("Start Meeting")
    }
}
