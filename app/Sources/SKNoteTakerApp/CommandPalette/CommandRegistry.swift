import SwiftUI
import SKNoteCore

/// One runnable entry in the Cmd+K palette.
struct SKCommand: Identifiable {
    let id: String
    let title: String
    /// Grouping label shown on the right of the row ("Action", "Go to", "Meeting", "Upcoming").
    let group: String
    let icon: String
    /// Extra words that should match this command even though they aren't in the title.
    var keywords: [String] = []
    /// Rendered as a shortcut hint chip, so the keyboard map is discoverable.
    var shortcutHint: String?
    var tint: Color?
    let run: @MainActor () -> Void
}

/// Builds the palette's command list from live app state, and ranks it against a query.
///
/// Commands are assembled fresh each time the palette opens so availability is always correct
/// (End Meeting only while recording, project entries only for projects that exist, and so on).
@MainActor
enum CommandRegistry {

    static func commands(for app: AppState) -> [SKCommand] {
        var out: [SKCommand] = []

        // MARK: Actions
        if app.session == nil {
            out.append(SKCommand(id: "meeting.start", title: "Start Meeting", group: "Action",
                                 icon: "record.circle.fill",
                                 keywords: ["record", "new", "capture"],
                                 shortcutHint: "⌘N", tint: Theme.recording) {
                Task { await app.startMeeting() }
            })
        } else {
            out.append(SKCommand(id: "meeting.end", title: "End Meeting", group: "Action",
                                 icon: "stop.fill", keywords: ["stop", "finish"],
                                 shortcutHint: "⌘E", tint: Theme.recording) {
                Task { await app.stopMeeting() }
            })
            out.append(SKCommand(id: "meeting.screen", title: "Record Screen", group: "Action",
                                 icon: "rectangle.dashed.badge.record",
                                 keywords: ["video", "capture", "window"]) {
                app.openScreenSourcePicker()
            })
        }
        out.append(SKCommand(id: "assistant.open", title: "Open Assistant", group: "Action",
                             icon: "sparkles", keywords: ["ai", "ask", "chat", "help"]) {
            app.showAppAssistant = true
        })
        out.append(SKCommand(id: "project.new", title: "New Project", group: "Action",
                             icon: "folder.badge.plus", keywords: ["folder", "client", "add"]) {
            app.pendingNewProject = true
        })
        if !app.calendarConnected {
            out.append(SKCommand(id: "calendar.connect", title: "Connect Google Calendar",
                                 group: "Action", icon: "calendar.badge.plus",
                                 keywords: ["google", "sync", "meetings"]) {
                Task { await app.connectCalendar() }
            })
        }
        out.append(SKCommand(id: "app.settings", title: "Settings", group: "Action",
                             icon: "gearshape", keywords: ["preferences", "options", "config"],
                             shortcutHint: "⌘,") {
            app.openSettings()
        })
        out.append(SKCommand(id: "app.onboarding", title: "Replay Setup Guide", group: "Action",
                             icon: "sparkles.rectangle.stack",
                             keywords: ["onboarding", "tutorial", "walkthrough", "permissions"]) {
            app.showOnboarding = true
        })

        // MARK: Navigation
        out.append(SKCommand(id: "go.all", title: "All Meetings", group: "Go to",
                             icon: "tray.full", keywords: ["library", "everything"],
                             shortcutHint: "⌘1") { app.libraryFilter = .all })
        out.append(SKCommand(id: "go.starred", title: "Starred", group: "Go to",
                             icon: "star.fill", keywords: ["favorite", "pinned"],
                             shortcutHint: "⌘2", tint: Theme.star) { app.libraryFilter = .starred })
        if app.calendarConnected {
            out.append(SKCommand(id: "go.upcoming", title: "Upcoming", group: "Go to",
                                 icon: "calendar", keywords: ["calendar", "schedule", "next"],
                                 shortcutHint: "⌘3") { app.libraryFilter = .upcoming })
        }
        for folder in app.folders where folder.parentId == nil {
            out.append(SKCommand(id: "go.folder.\(folder.id)", title: folder.name,
                                 group: "Project", icon: "folder.fill",
                                 keywords: ["project", "client"],
                                 tint: Theme.folderColor(for: folder.id)) {
                app.libraryFilter = .folder(folder.id)
            })
            out.append(SKCommand(id: "memory.\(folder.id)", title: "\(folder.name) memory",
                                 group: "Project", icon: "brain",
                                 keywords: ["notes", "context", "project"]) {
                app.projectMemoryTarget = ProjectRef(id: folder.id, name: folder.name)
            })
        }

        // MARK: Content jumps
        for meeting in app.meetings.prefix(200) {
            out.append(SKCommand(id: "open.\(meeting.id)", title: meeting.title,
                                 group: "Meeting", icon: "waveform",
                                 keywords: ["transcript", "recording", "open"]) {
                app.libraryFilter = .all
                app.selectedMeetingId = meeting.id
            })
        }
        for event in app.upcomingEvents.prefix(20) {
            out.append(SKCommand(id: "notes.\(event.id)", title: "Take notes: \(event.title)",
                                 group: "Upcoming", icon: "calendar.badge.clock",
                                 keywords: ["start", "meeting", "event"]) {
                Task { await app.startNotes(for: event) }
            })
        }
        return out
    }

    /// Ranks commands against a query. Empty query returns a useful default set (actions and
    /// navigation first, then the most recent meetings) rather than an arbitrary dump.
    /// Scoring itself lives in SKNoteCore.CommandMatcher so it is unit tested.
    static func rank(_ commands: [SKCommand], query: String) -> [SKCommand] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let priority = ["Action", "Go to", "Project"]
            let top = commands.filter { priority.contains($0.group) }
            let rest = commands.filter { !priority.contains($0.group) }.prefix(6)
            return top + rest
        }
        return commands
            .compactMap { cmd -> (SKCommand, Int)? in
                guard let s = CommandMatcher.score(
                    title: cmd.title, keywords: cmd.keywords, query: query) else { return nil }
                return (cmd, s)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(24)
            .map(\.0)
    }
}
