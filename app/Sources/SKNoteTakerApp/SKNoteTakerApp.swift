import SwiftUI
import AppKit
import SKNoteCore

/// Entry point. Intercepts hidden `--selftest-*` diagnostics (which run under the app's real
/// TCC grants and exit) before the normal SwiftUI app launches.
@main
enum AppEntry {
    static func main() {
        if SelfTest.run(CommandLine.arguments) { exit(0) }
        SKNoteTakerApp.main()
    }
}

struct SKNoteTakerApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SK Note Taker", id: "main") {
            ContentView()
                .environment(appState)
                .preferredColorScheme(.light)   // brand look: light surfaces, readable speaker colors
                .task { await appState.bootstrap() }
                .onAppear {
                    // Give AppState a way to surface the main window (from the menu bar
                    // and from the notification's "Start Notes" action while backgrounded).
                    appState.showMainWindow = {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Preview meeting popup") { appState.previewMeetingPopup() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        // Menu bar item — open, start a meeting, or quit from anywhere (Zoom/Willow style).
        // Live label: a recording badge while recording, else the next meeting + countdown.
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(.light)
        }
    }
}

/// Captures the hosting NSWindow so AppState can resize/float it for compact mode.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

/// The menu shown from the top menu-bar icon.
struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let session = app.session {
            Text("Recording  \(Theme.timestamp(session.elapsed))"
                 + (session.isPaused ? "  (paused)" : ""))
            Button("End Meeting") { Task { await app.stopMeeting() } }
            Divider()
        } else {
            Button("New Meeting") {
                app.showMainWindow?()
                Task { await app.startMeeting() }
            }
            .keyboardShortcut("n")
        }
        Button("Open SK Note Taker") { app.showMainWindow?() }
        if app.session == nil {
            Button("Preview meeting popup") { app.previewMeetingPopup() }
        }
        if app.settings.showUpcomingInMenuBar, app.calendarConnected, !app.upcomingEvents.isEmpty {
            Divider()
            if let next = app.nextMenuBarEvent {
                Text("Next: \(MenuBarLabel.shortTitle(next)) \(MenuBarLabel.countdown(next, now: Date()))")
            }
            Text("Upcoming")
            ForEach(app.upcomingEvents.prefix(4)) { event in
                Button(MenuBarLabel.rowTitle(event)) {
                    app.libraryFilter = .upcoming
                    app.selectEvent(event.id)
                    app.showMainWindow?()
                }
            }
        }
        Divider()
        if !app.meetings.isEmpty {
            Text("Recent")
            ForEach(app.meetings.prefix(5)) { meeting in
                Button(meeting.title) {
                    app.selectedMeetingId = meeting.id
                    app.showMainWindow?()
                }
            }
            Divider()
        }
        SettingsLink { Text("Settings…") }
        Button("Quit SK Note Taker") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu-bar item's label. ICON ONLY, and stable per state.
///
/// A live-updating label here (a TimelineView, or any continuously-changing text) drives
/// NSStatusItem into an infinite update/relayout loop (MenuBarExtraController.updateButton ->
/// _adjustLength -> requestUpdate), pinning the whole app at ~100% CPU. So the elapsed timer and
/// the next-meeting countdown live in the dropdown (MenuBarContent), not here.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if let session = app.session {
            return session.isPaused ? "pause.circle.fill" : "record.circle.fill"
        }
        if app.settings.showUpcomingInMenuBar, app.calendarConnected, app.nextMenuBarEvent != nil {
            return "calendar"
        }
        return "waveform"
    }

    static func shortTitle(_ event: GoogleCalendarEvent) -> String {
        event.title.count > 24 ? String(event.title.prefix(23)) + "…" : event.title
    }

    static func countdown(_ event: GoogleCalendarEvent, now: Date) -> String {
        let mins = Int(event.start.timeIntervalSince(now) / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
    }

    static func rowTitle(_ event: GoogleCalendarEvent) -> String {
        let df = DateFormatter()
        df.dateFormat = event.isAllDay ? "EEE" : "EEE h:mm a"
        return "\(df.string(from: event.start))  ·  \(event.title)"
    }
}

/// What the meeting list is currently filtered to (drives the sidebar selection).
enum LibraryFilter: Equatable {
    case all
    case starred
    case upcoming
    case folder(UUID)
}

/// Root observable state: stores, lists, selection, live session.
@Observable
@MainActor
final class AppState {
    let store = MeetingStore()
    let folderStore = FolderStore()
    var ai = ClaudeCLIService()
    /// Cloud mirror (local-first): every local save is pushed to Supabase best-effort.
    @ObservationIgnored lazy var sync = SupabaseSync(
        config: .sknote, store: store, folderStore: folderStore)

    var meetings: [Meeting] = []
    var folders: [Folder] = []
    var libraryFilter: LibraryFilter = .all   // All Meetings / Starred / Upcoming / a project folder
    var selectedMeetingId: UUID? {
        didSet { if selectedMeetingId != nil { selectedEventId = nil } }
    }
    var searchText = ""
    /// Starred meeting ids (persisted in UserDefaults so no Codable migration on Meeting).
    var starred: Set<UUID> = []

    var session: MeetingSession?     // non-nil while recording
    var settings = AppSettings()
    var claudeAvailable = true

    // Google Calendar (in-app browser sign-in). The service holds the Keychain-backed tokens;
    // these mirror its state for the UI to observe.
    @ObservationIgnored let calendar = GoogleCalendarService()
    /// Observable mirror of the (non-observable) service's saved-credentials state, so the
    /// Settings UI re-renders the moment credentials are saved.
    var googleCredentialsSaved = false
    var calendarConnected = false
    var calendarEmail: String?
    var calendarBusy = false
    var calendarError: String?
    var upcomingEvents: [GoogleCalendarEvent] = []
    var calendarList: [GoogleCalendarInfo] = []
    @ObservationIgnored private var calendarPollTask: Task<Void, Never>?
    /// Selected calendar event id (drives the event detail pane in the Upcoming view).
    var selectedEventId: String?
    var selectedEvent: GoogleCalendarEvent? {
        upcomingEvents.first { $0.id == selectedEventId }
    }

    /// Compact "floating transcript" mode: the window shrinks to a right-docked strip that
    /// floats over other apps, showing just the live transcript + Ask AI while recording runs.
    var compactMode = false
    @ObservationIgnored var mainWindow: NSWindow?
    @ObservationIgnored private var savedFrame: NSRect?

    func setCompact(_ compact: Bool) {
        guard compactMode != compact else { return }
        compactMode = compact
        guard let window = mainWindow else { return }
        if compact {
            savedFrame = window.frame
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
                let w: CGFloat = 360
                window.setFrame(NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height),
                                display: true, animate: true)
            }
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            if let saved = savedFrame { window.setFrame(saved, display: true, animate: true) }
        }
    }

    // Permission state (refreshed on launch, after grants, and when the window activates).
    var micStatus: Permission.Status = .notDetermined
    var systemAudioStatus: Permission.Status = .notDetermined
    var accessibilityStatus: Permission.Status = .denied

    // Zoom speaker tags: read Zoom's active-speaker via Accessibility, feed noteActiveSpeaker.
    @ObservationIgnored let zoomReader = ZoomSpeakerReader()
    var speakerTagsActive = false
    var notificationStatus: String = "notDetermined"
    var showOnboarding = false

    // Meeting auto-detection (Zoom/Teams/WhatsApp/Meet → notification → start notes).
    @ObservationIgnored private lazy var detector: MeetingDetector = {
        let d = MeetingDetector()
        d.isRecording = { [weak self] in self?.session != nil }
        d.onDetected = { [weak self] app in self?.handleDetectedMeeting(app: app) }
        return d
    }()
    @ObservationIgnored private lazy var notifier: MeetingNotifier = {
        let n = MeetingNotifier()
        n.onStart = { [weak self] in
            self?.showMainWindow?()          // surface the window (may be closed/backgrounded)
            Task { await self?.startMeeting() }
        }
        n.onDismiss = { [weak self] in self?.detector.snooze() }
        n.onEndMeeting = { [weak self] in Task { await self?.stopMeeting() } }
        n.onKeepRecording = { [weak self] in self?.session?.keepRecording() }
        return n
    }()
    /// Set by the main window scene; surfaces/creates the main window (used by the menu bar
    /// and the notification's Start Notes action when the app is backgrounded).
    @ObservationIgnored var showMainWindow: (() -> Void)?
    /// The custom floating "you're in a meeting" popup (top-right, 40s, Start Notes).
    @ObservationIgnored private let detectionPanel = MeetingDetectionPanel()
    /// Keeps App Nap from throttling the background detection timer.
    @ObservationIgnored private var backgroundActivity: NSObjectProtocol?

    // Transient UI state
    var errorMessage: String?
    var busy: Set<String> = []       // feature keys currently running (e.g. "summary")
    /// Bumped whenever a meeting's stored transcript is rewritten underneath an open view
    /// (e.g. "Redo speaker detection"). Detail views key their load on this so the transcript
    /// pane re-reads from the store instead of showing the pre-redo attribution.
    private(set) var transcriptRevision = 0

    private static let starredKey = "sk.starredMeetings"

    func isStarred(_ id: UUID) -> Bool { starred.contains(id) }

    func toggleStar(_ id: UUID) {
        if starred.contains(id) { starred.remove(id) } else { starred.insert(id) }
        UserDefaults.standard.set(starred.map(\.uuidString), forKey: Self.starredKey)
    }

    func bootstrap() async {
        starred = Set((UserDefaults.standard.array(forKey: Self.starredKey) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:)))
        settings = await store.loadSettings()
        ai = ClaudeCLIService(model: settings.claudeModel)
        claudeAvailable = await ai.isAvailable()
        // Sync the login item to the saved preference (registers on first run if defaulted on).
        if settings.launchAtLogin != LoginItem.isEnabled {
            LoginItem.setEnabled(settings.launchAtLogin)
        }
        refreshPermissions()
        // First run (mic never asked) → show the onboarding walkthrough.
        showOnboarding = micStatus == .notDetermined
        await recoverOrphanedMeetings()
        await refresh()
        await startAutoDetectIfEnabled()
        googleCredentialsSaved = calendar.hasCredentials
        calendarConnected = calendar.isConnected
        calendarEmail = calendar.connectedEmail
        if calendarConnected {
            await loadCalendarList()
            await refreshUpcoming()
            startCalendarPolling()
        }
        // Catch-up cloud sync in the background (local-first: never blocks the UI).
        Task { await sync.syncAll() }
    }

    // MARK: - Google Calendar

    var savedGoogleClientID: String { calendar.savedClientID ?? "" }

    func setGoogleCredentials(clientID: String, clientSecret: String) {
        calendar.setCredentials(clientID: clientID, clientSecret: clientSecret)
        googleCredentialsSaved = calendar.hasCredentials
    }

    func connectCalendar() async {
        calendarError = nil
        calendarBusy = true
        defer { calendarBusy = false }
        do {
            try await calendar.connect { NSWorkspace.shared.open($0) }
            calendarConnected = calendar.isConnected
            calendarEmail = calendar.connectedEmail
            await loadCalendarList()
            await refreshUpcoming()
            startCalendarPolling()
        } catch {
            calendarError = (error as? GoogleCalendarError)?.message ?? error.localizedDescription
        }
    }

    func disconnectCalendar() {
        calendar.disconnect()
        calendarConnected = false
        calendarEmail = nil
        upcomingEvents = []
        calendarList = []
        calendarPollTask?.cancel(); calendarPollTask = nil
    }

    func cancelCalendarConnect() { calendar.cancelConnect() }

    /// The calendar ids whose events should show: the user's saved selection, or (first run,
    /// empty selection) each calendar's Google-side `selected` flag.
    var enabledCalendarIds: [String] {
        if !settings.visibleCalendarIds.isEmpty { return settings.visibleCalendarIds }
        let seeded = calendarList.filter(\.selectedByDefault).map(\.id)
        return seeded.isEmpty ? ["primary"] : seeded
    }

    func loadCalendarList() async {
        guard calendar.isConnected else { return }
        do { calendarList = try await calendar.calendarList() }
        catch { calendarError = (error as? GoogleCalendarError)?.message ?? error.localizedDescription }
    }

    func refreshUpcoming() async {
        guard calendar.isConnected else { return }
        let ids = enabledCalendarIds
        let colors = Dictionary(uniqueKeysWithValues: calendarList.compactMap { info in
            info.colorHex.map { (info.id, $0) }
        })
        do {
            var events = try await calendar.upcomingEvents(
                days: 30, max: 50, calendarIds: ids, colorByCalendar: colors)
            if !settings.showEventsWithoutParticipants {
                events = events.filter { !$0.attendees.isEmpty || $0.meetingURL != nil }
            }
            upcomingEvents = events
        } catch {
            calendarError = (error as? GoogleCalendarError)?.message ?? error.localizedDescription
        }
    }

    func setCalendarVisible(_ id: String, _ visible: Bool) {
        var ids = Set(enabledCalendarIds)
        if visible { ids.insert(id) } else { ids.remove(id) }
        settings.visibleCalendarIds = calendarList.map(\.id).filter { ids.contains($0) }
        Task { try? await store.save(settings: settings); await refreshUpcoming() }
    }

    func resetCalendarVisibility() {
        settings.visibleCalendarIds = []
        Task { try? await store.save(settings: settings); await refreshUpcoming() }
    }

    func isCalendarVisible(_ id: String) -> Bool { enabledCalendarIds.contains(id) }

    func setShowUpcomingInMenuBar(_ on: Bool) {
        settings.showUpcomingInMenuBar = on
        Task { try? await store.save(settings: settings) }
    }

    func setShowEventsWithoutParticipants(_ on: Bool) {
        settings.showEventsWithoutParticipants = on
        Task { try? await store.save(settings: settings); await refreshUpcoming() }
    }

    /// The next timed event that hasn't started yet (skips all-day and in-progress) — drives
    /// the menu-bar countdown.
    var nextMenuBarEvent: GoogleCalendarEvent? {
        let now = Date()
        return upcomingEvents.first { !$0.isAllDay && $0.start > now }
    }

    /// Refresh calendar data periodically so the menu-bar countdown stays current.
    private func startCalendarPolling() {
        calendarPollTask?.cancel()
        calendarPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.calendar.isConnected else { return }
                await self.refreshUpcoming()
            }
        }
    }

    func selectEvent(_ id: String) {
        selectedEventId = id
        selectedMeetingId = nil
    }

    /// Start a recording pre-titled after a calendar event.
    func startNotes(for event: GoogleCalendarEvent) async {
        showMainWindow?()
        await startMeeting(suggestedTitle: event.title)
    }

    // MARK: - Meeting auto-detection

    func startAutoDetectIfEnabled() async {
        guard settings.autoDetectMeetings else {
            detector.stop()
            endBackgroundActivity()
            return
        }
        // Keep the poll timer alive even when the app is backgrounded / window closed.
        if backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "SK Note Taker meeting detection")
        }
        detector.start()
        // Native macOS notification is the pop-up; request permission (non-blocking).
        Task {
            await notifier.requestAuthorization()
            notificationStatus = await notifier.authorizationStatusString()
        }
    }

    private func endBackgroundActivity() {
        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }
    }

    func setAutoDetect(_ enabled: Bool) {
        settings.autoDetectMeetings = enabled
        Task {
            try? await store.save(settings: settings)
            if enabled { await startAutoDetectIfEnabled() }
            else { detector.stop(); endBackgroundActivity() }
        }
    }

    /// A meeting was detected → fire the native macOS notification (works while backgrounded).
    private func handleDetectedMeeting(app: String) {
        guard session == nil else { return }
        detector.accepted()          // latch until this call ends / user acts
        detectionPanel.show(
            appName: app,
            onStartNotes: { [weak self] in
                Task { @MainActor in await self?.startMeetingCompact() }
            },
            onDismiss: { [weak self] in self?.detector.snooze() })
    }

    /// Start a meeting and drop straight into the compact floating panel — used by the
    /// meeting-detected popup's Start Notes so the user immediately sees the live transcript.
    func startMeetingCompact() async {
        showMainWindow?()
        await startMeeting()
        if session != nil { setCompact(true) }
    }

    /// Show the meeting-detected popup on demand (menu bar → Preview), so its look and behaviour
    /// can be checked without waiting for a real call.
    func previewMeetingPopup() {
        detectionPanel.show(
            appName: "Zoom",
            onStartNotes: { [weak self] in
                Task { @MainActor in await self?.startMeetingCompact() }
            },
            onDismiss: {})
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micStatus = Permission.micStatus()
        // System audio now flows through ScreenCaptureKit, which the Screen Recording grant
        // gates; the Core Audio process tap is only a fallback. Report granted when either
        // path can actually capture, preferring the primary one.
        if Permission.screenRecordingStatus() == .granted {
            systemAudioStatus = .granted
        } else {
            systemAudioStatus = Permission.systemAudioStatus()
        }
        accessibilityStatus = Permission.accessibilityStatus()
    }

    // MARK: - Zoom speaker tags (Accessibility)

    func refreshAccessibility() { accessibilityStatus = Permission.accessibilityStatus() }

    /// Fires the system Accessibility prompt, then opens the pane so the user can enable us.
    func setUpSpeakerTags() {
        Permission.requestAccessibility()
        accessibilityStatus = Permission.accessibilityStatus()
        if accessibilityStatus != .granted {
            NSWorkspace.shared.open(Permission.accessibilitySettingsURL)
        }
    }

    /// Start reading Zoom for the active speaker if the meeting is a Zoom call and we're trusted.
    private func startZoomSpeakerReaderIfPossible() {
        guard session != nil,
              ZoomSpeakerReader.zoomIsRunning(),
              Permission.accessibilityStatus() == .granted else { return }
        speakerTagsActive = true
        zoomReader.start { [weak self] name in
            Task { @MainActor in self?.session?.noteActiveSpeaker(name) }
        }
    }

    private func stopZoomSpeakerReader() {
        zoomReader.stop()
        speakerTagsActive = false
    }

    /// Dump Zoom's accessibility tree to the Desktop log so the active-speaker nodes can be
    /// identified during a live call (used to refine the reader).
    func dumpZoomTree() {
        let dump = zoomReader.dumpTree()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SK Note Taker Logs/zoom-ax-tree.txt")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? dump.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func requestMic() async {
        micStatus = await Permission.requestMic()
    }

    /// Probing system-audio status also triggers its first-time prompts (Screen Recording for
    /// the ScreenCaptureKit path, then the process-tap probe for the fallback).
    func probeSystemAudio() {
        if Permission.screenRecordingStatus() != .granted {
            Permission.requestScreenRecording()
        }
        refreshPermissions()
    }

    /// The name shown for anything captured on the microphone — the machine owner. Empty
    /// falls back to "Me" rather than "Speaker 1", which read as a stranger's label.
    var userDisplayName: String {
        let name = settings.defaultSpeakerName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Me" : name
    }

    func setUserName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        settings.defaultSpeakerName = trimmed.isEmpty ? nil : trimmed
        Task { try? await store.save(settings: settings) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        LoginItem.setEnabled(enabled)
        Task { try? await store.save(settings: settings) }
    }

    func openMicSettings() {
        NSWorkspace.shared.open(Permission.micSettingsURL)
    }

    func openSystemAudioSettings() {
        // Fire the Screen Recording request first so the app is listed in the pane we open.
        Permission.requestScreenRecording()
        NSWorkspace.shared.open(Permission.systemAudioSettingsURL)
    }

    /// Meetings left in "recording" state by a crash/quit: close them out (their transcript
    /// was autosaved continuously, so nothing is lost).
    private func recoverOrphanedMeetings() async {
        for var meeting in await store.allMeetings() where meeting.state == .recording {
            meeting.state = .complete
            if meeting.endedAt == nil { meeting.endedAt = Date() }
            if meeting.durationSec == 0,
               let transcript = try? await store.transcript(for: meeting.id),
               let last = transcript.segments.map(\.end).max() {
                meeting.durationSec = last
            }
            try? await store.save(meeting)
        }
    }

    func refresh() async {
        meetings = await store.allMeetings()
        folders = await folderStore.all()
    }

    var visibleMeetings: [Meeting] {
        var list = meetings
        switch libraryFilter {
        case .all:
            break
        case .starred:
            list = list.filter { starred.contains($0.id) }
        case .upcoming:
            list = []   // the Upcoming view renders calendar events, not saved meetings
        case .folder(let folderId):
            // Include meetings in child folders (client folder shows its projects' meetings).
            let childIds = Set(folders.filter { $0.parentId == folderId }.map(\.id))
            list = list.filter { m in
                m.folderId == folderId || (m.folderId.map { childIds.contains($0) } ?? false)
            }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        return list
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingId }
    }

    // MARK: - Recording lifecycle

    func startMeeting(suggestedTitle: String? = nil) async {
        guard session == nil else { return }
        let trimmed = suggestedTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = trimmed.isEmpty
            ? Date().formatted(date: .abbreviated, time: .shortened) + " Meeting"
            : trimmed
        let session = await MeetingSession.live(
            title: title, store: store,
            autoEndSilenceSeconds: settings.autoEndDetection
                ? max(60, settings.autoEndSilenceMinutes * 60) : nil,
            userName: settings.defaultSpeakerName)
        session.onEndPromptShown = { [weak self] reason in
            self?.notifier.notifyMeetingMayHaveEnded(reason: reason)
        }
        session.onEndPromptCleared = { [weak self] in self?.notifier.clearEndPrompts() }
        session.onAutoEnd = { [weak self] in Task { await self?.stopMeeting() } }
        self.session = session
        await session.start()
        refreshPermissions()
        if case .failed(let why) = session.phase {
            errorMessage = why
            self.session = nil
        } else {
            selectedMeetingId = session.meeting.id
            await refresh()
            startZoomSpeakerReaderIfPossible()
        }
    }

    func stopMeeting() async {
        stopZoomSpeakerReader()
        guard let session else { return }
        if compactMode { setCompact(false) }   // restore the full window when the meeting ends
        notifier.clearEndPrompts()
        await session.finish()
        let finishedId = session.meeting.id
        self.session = nil
        await refresh()
        selectedMeetingId = finishedId
        // Fire-and-forget post-meeting intelligence + cloud sync once the meeting is done.
        Task {
            await autoCategorize(meetingId: finishedId)
            if settings.autoSummarize, claudeAvailable,
               await store.summary(for: finishedId) == nil {
                let notes = await store.notes(for: finishedId)
                await generateSummary(for: finishedId, notes: notes)
            }
            await sync.syncMeeting(finishedId)
            await sync.uploadRecording(finishedId)
        }
    }

    // MARK: - AI features

    func generateSummary(for meetingId: UUID, notes: String) async {
        guard let meeting = meetings.first(where: { $0.id == meetingId }),
              let transcript = try? await store.transcript(for: meetingId),
              !transcript.segments.isEmpty else { return }   // nothing to summarize → no scary alert
        busy.insert("summary")
        defer { busy.remove("summary") }
        do {
            let summary = try await ai.summarize(meeting: meeting, transcript: transcript, notes: notes)
            try await store.saveSummary(summary, for: meetingId)
            await sync.syncMeeting(meetingId)
        } catch {
            SKLog.error(.aiRequestFailed, .ai, "Summary generation failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func ask(question: String, meetingId: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingId }),
              let transcript = try? await store.transcript(for: meetingId) else { return }
        busy.insert("chat")
        defer { busy.remove("chat") }
        var chat = await store.chat(for: meetingId)
        chat.messages.append(ChatMessage(role: "user", text: question))
        try? await store.saveChat(chat, for: meetingId)
        do {
            let answer = try await ai.answer(
                question: question, meeting: meeting, transcript: transcript, history: chat)
            chat.messages.append(ChatMessage(role: "assistant", text: answer))
            try await store.saveChat(chat, for: meetingId)
            await sync.syncMeeting(meetingId)
        } catch {
            chat.messages.append(ChatMessage(
                role: "assistant", text: "Something went wrong: \(error.localizedDescription)"))
            try? await store.saveChat(chat, for: meetingId)
        }
    }

    /// In-meeting question — answered from the LIVE transcript, no store round-trip.
    /// Persists into the meeting's chat.json so the thread continues after the meeting.
    func askLive(question: String) async {
        guard let session, !session.liveSegments.isEmpty else { return }
        let meeting = session.meeting
        let transcript = Transcript(segments: session.liveSegments)
        busy.insert("liveChat")
        defer { busy.remove("liveChat") }
        var chat = await store.chat(for: meeting.id)
        chat.messages.append(ChatMessage(role: "user", text: question))
        try? await store.saveChat(chat, for: meeting.id)
        do {
            let answer = try await ai.liveAssist(
                question: question, meeting: meeting, transcript: transcript,
                history: chat, userName: settings.defaultSpeakerName)
            chat.messages.append(ChatMessage(role: "assistant", text: answer))
            try await store.saveChat(chat, for: meeting.id)
        } catch {
            chat.messages.append(ChatMessage(
                role: "assistant", text: "Something went wrong: \(error.localizedDescription)"))
            try? await store.saveChat(chat, for: meeting.id)
        }
    }

    func autoCategorize(meetingId: UUID) async {
        guard var meeting = meetings.first(where: { $0.id == meetingId }),
              meeting.folderId == nil,
              let transcript = try? await store.transcript(for: meetingId),
              !transcript.segments.isEmpty else { return }
        busy.insert("categorize")
        defer { busy.remove("categorize") }
        do {
            let existing = await folderStore.all()
            var mutablePaths: [UUID?: String] = [:]
            for folder in existing {
                mutablePaths[folder.id] = await folderStore.path(for: folder.id)
            }
            let paths = mutablePaths
            let (category, suggestedTitle) = try await ai.categorize(
                meeting: meeting, transcript: transcript, existingFolders: existing,
                folderPath: { paths[$0] ?? "" })
            meeting.autoCategory = category
            // Smart title — only while the meeting still has its default timestamp title
            // (a manual rename always wins).
            if let suggestedTitle, meeting.title.hasSuffix(" Meeting") {
                meeting.title = suggestedTitle
            }
            if category.confidence >= 0.5 {
                meeting.folderId = try await folderStore.resolveOrCreate(
                    client: category.client, project: category.project)
            }
            try await store.save(meeting)
            await refresh()
            await sync.syncFolders()
            await sync.syncMeeting(meetingId)
        } catch {
            // Categorization is best-effort; surface quietly.
            SKLog.error(.aiRequestFailed, .ai,
                        "Auto-categorization failed — the meeting stays unfiled", error: error)
        }
    }

    /// Re-run speaker detection on a finished meeting's recording and re-attribute the
    /// transcript. Recovers remote speakers the live pass collapsed into one. On new stereo
    /// recordings this uses the isolated system channel; on legacy mono it's best-effort.
    func redoSpeakerDetection(meetingId: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingId }), meeting.hasRecording,
              let transcript = try? await store.transcript(for: meetingId),
              !transcript.segments.isEmpty else { return }
        _ = transcript
        busy.insert("redoSpeakers")
        defer { busy.remove("redoSpeakers") }
        let url = await store.recordingURL(for: meetingId)
        do {
            let (newTranscript, speakers) = try await MeetingReprocessor.reprocess(
                recordingURL: url)
            guard !newTranscript.segments.isEmpty else { return }
            try await store.save(newTranscript, for: meetingId)
            transcriptRevision += 1      // force open detail views to re-read the transcript
            if var m = meetings.first(where: { $0.id == meetingId }) {
                // Merge new speaker set, preserving any names the user already assigned.
                var merged: [String: SpeakerInfo] = [:]
                for (key, var info) in speakers {
                    if let name = m.speakers[key]?.name { info.name = name }
                    merged[key] = info
                }
                m.speakers = merged
                try await store.save(m)
                await refresh()
            }
            await sync.syncMeeting(meetingId)
        } catch {
            SKLog.error(.diarizationPassFailed, .diarization,
                        "Redo speaker detection failed", error: error)
            errorMessage = "Speaker detection failed: \(error.localizedDescription)"
        }
    }

    func renameSpeaker(meetingId: UUID, key: String, name: String) async {
        if let session, session.meeting.id == meetingId {
            await session.nameSpeaker(key: key, name: name)
        } else if var meeting = meetings.first(where: { $0.id == meetingId }) {
            meeting.speakers[key]?.name = name.isEmpty ? nil : name
            try? await store.save(meeting)
        }
        await refresh()
        await sync.syncMeeting(meetingId)
    }

    func move(meetingId: UUID, to folderId: UUID?) async {
        guard var meeting = meetings.first(where: { $0.id == meetingId }) else { return }
        meeting.folderId = folderId
        try? await store.save(meeting)
        await refresh()
        await sync.syncMeeting(meetingId)
    }

    func delete(meetingId: UUID) async {
        try? await store.delete(id: meetingId)
        if selectedMeetingId == meetingId { selectedMeetingId = nil }
        await refresh()
        await sync.deleteMeeting(meetingId)
    }

    func saveSettings() async {
        try? await store.save(settings: settings)
        ai = ClaudeCLIService(model: settings.claudeModel)
    }
}
