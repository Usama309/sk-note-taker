import SwiftUI
import SKNoteCore

// MARK: - Upcoming list (content column)

/// All upcoming Google Calendar events, grouped by day. Selecting one opens it in the detail pane.
struct UpcomingListView: View {
    @Environment(AppState.self) private var app
    @State private var refreshHover = false

    private var groups: [(key: Date, label: String, events: [GoogleCalendarEvent])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: app.upcomingEvents) { cal.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            (key: day, label: Self.dayLabel(day), events: byDay[day]!.sorted { $0.start < $1.start })
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { app.selectedEventId }, set: { if let id = $0 { app.selectEvent(id) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Upcoming").font(.skHeadline)
                if let email = app.calendarEmail {
                    Text(email).font(.skFootnote).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button { Task { await app.refreshUpcoming() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        .scaleEffect(refreshHover ? 1.12 : 1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(refreshHover ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .help("Refresh")
                .onHover { refreshHover = $0 }
                .animation(Theme.Motion.snap, value: refreshHover)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if app.upcomingEvents.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 30)).foregroundStyle(Theme.mint)
                    Text("No upcoming events").font(.skHeadline)
                    Text("Events from your Google Calendar show up here.")
                        .font(.skCallout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Refresh") { Task { await app.refreshUpcoming() } }.controlSize(.small)
                }
                .padding(.horizontal, 24)
                Spacer()
            } else {
                List(selection: selection) {
                    ForEach(groups, id: \.key) { group in
                        Section(group.label) {
                            ForEach(group.events) { event in
                                EventRow(event: event).tag(event.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .task { if app.upcomingEvents.isEmpty { await app.refreshUpcoming() } }
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: day)
    }
}

struct EventRow: View {
    @Environment(AppState.self) private var app
    let event: GoogleCalendarEvent
    @State private var hovering = false

    // Same story as MeetingRow: the selected row already wears the accent fill, so the hover
    // tint has to stay out of its way.
    private var isSelected: Bool { app.selectedEventId == event.id }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("all-day").font(.skFootnoteStrong).foregroundStyle(.secondary)
                } else {
                    Text(Self.time(event.start)).font(.skLabel)
                    Text(Self.time(event.end)).font(.skFootnote).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, alignment: .trailing)

            // Scaled, not resized, so the hover never nudges the rows below it.
            Capsule().fill(Theme.accentGradient).frame(width: 3, height: 32)
                .scaleEffect(y: hovering ? 1.18 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.skSubtitle).lineLimit(1)
                HStack(spacing: 6) {
                    if event.meetingURL != nil {
                        Image(systemName: "video.fill").font(.system(size: 9))
                    }
                    if let loc = event.location, !loc.isEmpty {
                        Text(loc).lineLimit(1)
                    } else if !event.attendees.isEmpty {
                        Text("\(event.attendees.count) guest\(event.attendees.count == 1 ? "" : "s")")
                    }
                }
                .font(.skCaption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .background(Theme.surface.opacity(hovering && !isSelected ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snap, value: hovering)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Event detail (detail pane)

/// A single calendar event, with actions to start notes for it or open it.
struct EventDetailView: View {
    @Environment(AppState.self) private var app
    let event: GoogleCalendarEvent
    @State private var startHover = false
    /// Which pill link the cursor is over. Keyed by title so the two links share one flag.
    @State private var hoveredPill: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(event.title)
                        .font(.skHero)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(dateRange, systemImage: "clock")
                        .font(.skBody).foregroundStyle(.secondary)
                    if let loc = event.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.skBody).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button { Task { await app.startNotes(for: event) } } label: {
                        Label("Start notes", systemImage: "record.circle.fill")
                            .font(.skSubtitle)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Theme.accentGradient, in: Capsule())
                            .foregroundStyle(.white)
                            .scaleEffect(startHover ? 1.03 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.session != nil)
                    .onHover { startHover = $0 && app.session == nil }
                    .animation(Theme.Motion.snap, value: startHover)

                    if let url = event.meetingURL {
                        Link(destination: url) { pillLabel("Join", "video.fill") }
                    }
                    if let link = event.htmlLink {
                        Link(destination: link) { pillLabel("Open in Google Calendar", "calendar") }
                    }
                }

                if !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Guests (\(event.attendees.count))")
                            .font(.skSubtitle)
                        ForEach(event.attendees.prefix(12), id: \.self) { name in
                            HStack(spacing: 9) {
                                Circle().fill(Theme.accent.opacity(0.16))
                                    .frame(width: 24, height: 24)
                                    .overlay(Text(String(name.prefix(1)).uppercased())
                                        .font(.skCaptionStrong)
                                        .foregroundStyle(Theme.accent))
                                Text(name).font(.skCallout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .skCard(Theme.card)
                }

                if let notes = event.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.skSubtitle)
                        Text(notes).font(.skBody).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }

    private func pillLabel(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.skBody)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.surface, in: Capsule())
            .foregroundStyle(.primary)
            .scaleEffect(hoveredPill == text ? 1.03 : 1)
            .onHover { hoveredPill = $0 ? text : nil }
            .animation(Theme.Motion.snap, value: hoveredPill)
    }

    private var dateRange: String {
        let f = DateFormatter()
        if event.isAllDay {
            f.dateFormat = "EEEE, MMM d"
            return f.string(from: event.start) + " · all-day"
        }
        f.dateFormat = "EEEE, MMM d · h:mm a"
        let ef = DateFormatter(); ef.dateFormat = "h:mm a"
        return f.string(from: event.start) + " to " + ef.string(from: event.end)
    }
}
