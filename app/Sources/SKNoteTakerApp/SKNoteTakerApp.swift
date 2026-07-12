import SwiftUI
import AppKit
import SKNoteCore

@main
struct SKNoteTakerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await appState.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Root observable state: stores, lists, selection, live session.
@Observable
@MainActor
final class AppState {
    let store = MeetingStore()
    let folderStore = FolderStore()
    var ai = ClaudeCLIService()

    var meetings: [Meeting] = []
    var folders: [Folder] = []
    var selectedFolderId: UUID?      // nil = All Meetings
    var selectedMeetingId: UUID?
    var searchText = ""

    var session: MeetingSession?     // non-nil while recording
    var settings = AppSettings()
    var claudeAvailable = true

    // Permission state (refreshed on launch, after grants, and when the window activates).
    var micStatus: Permission.Status = .notDetermined
    var systemAudioStatus: Permission.Status = .notDetermined
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
        n.onStart = { [weak self] in Task { await self?.startMeeting() } }
        n.onDismiss = { [weak self] in self?.detector.snooze() }
        return n
    }()
    /// Most recently detected meeting app (for an in-app banner fallback).
    var detectedMeetingApp: String?

    // Transient UI state
    var errorMessage: String?
    var busy: Set<String> = []       // feature keys currently running (e.g. "summary")

    func bootstrap() async {
        settings = await store.loadSettings()
        ai = ClaudeCLIService(model: settings.claudeModel)
        claudeAvailable = await ai.isAvailable()
        refreshPermissions()
        // First run (mic never asked) → show the onboarding walkthrough.
        showOnboarding = micStatus == .notDetermined
        await recoverOrphanedMeetings()
        await refresh()
        await startAutoDetectIfEnabled()
    }

    // MARK: - Meeting auto-detection

    func startAutoDetectIfEnabled() async {
        guard settings.autoDetectMeetings else { detector.stop(); return }
        // Start polling immediately — the in-app banner works without notification permission.
        // Request notification auth in the background so it never blocks detection.
        detector.start()
        Task { await notifier.requestAuthorization() }
    }

    func setAutoDetect(_ enabled: Bool) {
        settings.autoDetectMeetings = enabled
        Task {
            try? await store.save(settings: settings)
            if enabled { await startAutoDetectIfEnabled() }
            else { detector.stop(); detectedMeetingApp = nil }
        }
    }

    private func handleDetectedMeeting(app: String) {
        guard session == nil else { return }
        detectedMeetingApp = app
        detector.accepted()          // latch until this call ends / user acts
        notifier.notifyMeetingDetected(app: app)
    }

    /// Dismiss the in-app banner and snooze detection.
    func dismissDetectedMeeting() {
        detectedMeetingApp = nil
        detector.snooze()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micStatus = Permission.micStatus()
        systemAudioStatus = Permission.systemAudioStatus()
    }

    func requestMic() async {
        micStatus = await Permission.requestMic()
    }

    /// Probing system-audio status also triggers its first-time prompt.
    func probeSystemAudio() {
        systemAudioStatus = Permission.systemAudioStatus()
    }

    func openMicSettings() {
        NSWorkspace.shared.open(Permission.micSettingsURL)
    }

    func openSystemAudioSettings() {
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
        if let folderId = selectedFolderId {
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

    func startMeeting() async {
        guard session == nil else { return }
        detectedMeetingApp = nil            // clear any pending detection banner
        let title = Date().formatted(date: .abbreviated, time: .shortened) + " Meeting"
        let session = MeetingSession.live(title: title, store: store)
        self.session = session
        await session.start()
        refreshPermissions()
        if case .failed(let why) = session.phase {
            errorMessage = why
            self.session = nil
        } else {
            selectedMeetingId = session.meeting.id
            await refresh()
        }
    }

    func stopMeeting() async {
        guard let session else { return }
        await session.finish()
        let finishedId = session.meeting.id
        self.session = nil
        await refresh()
        selectedMeetingId = finishedId
        // Fire-and-forget auto-categorization once the meeting is done.
        Task { await autoCategorize(meetingId: finishedId) }
    }

    // MARK: - AI features

    func generateSummary(for meetingId: UUID, notes: String) async {
        guard let meeting = meetings.first(where: { $0.id == meetingId }),
              let transcript = try? await store.transcript(for: meetingId) else { return }
        busy.insert("summary")
        defer { busy.remove("summary") }
        do {
            let summary = try await ai.summarize(meeting: meeting, transcript: transcript, notes: notes)
            try await store.saveSummary(summary, for: meetingId)
        } catch {
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
        } catch {
            chat.messages.append(ChatMessage(
                role: "assistant", text: "Something went wrong: \(error.localizedDescription)"))
            try? await store.saveChat(chat, for: meetingId)
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
            let category = try await ai.categorize(
                meeting: meeting, transcript: transcript, existingFolders: existing,
                folderPath: { paths[$0] ?? "" })
            meeting.autoCategory = category
            if category.confidence >= 0.5 {
                meeting.folderId = try await folderStore.resolveOrCreate(
                    client: category.client, project: category.project)
            }
            try await store.save(meeting)
            await refresh()
        } catch {
            // Categorization is best-effort; surface quietly.
            FileHandle.standardError.write(
                Data("SKNoteTaker: auto-categorize failed: \(error)\n".utf8))
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
    }

    func move(meetingId: UUID, to folderId: UUID?) async {
        guard var meeting = meetings.first(where: { $0.id == meetingId }) else { return }
        meeting.folderId = folderId
        try? await store.save(meeting)
        await refresh()
    }

    func delete(meetingId: UUID) async {
        try? await store.delete(id: meetingId)
        if selectedMeetingId == meetingId { selectedMeetingId = nil }
        await refresh()
    }

    func saveSettings() async {
        try? await store.save(settings: settings)
        ai = ClaudeCLIService(model: settings.claudeModel)
    }
}
