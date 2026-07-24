import SwiftUI
import SKNoteCore

// MARK: - Upcoming list (content column)

/// All upcoming Google Calendar events, grouped by day. Selecting one opens it in the detail pane.
struct UpcomingListView: View {
    @Environment(AppState.self) private var app

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
                Text("Upcoming").font(.system(size: 15, weight: .bold))
                if let email = app.calendarEmail {
                    Text(email).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button { Task { await app.refreshUpcoming() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if app.upcomingEvents.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 30)).foregroundStyle(Theme.teal)
                    Text("No upcoming events").font(.headline)
                    Text("Events from your Google Calendar show up here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
    let event: GoogleCalendarEvent

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text("all-day").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Text(Self.time(event.start)).font(.system(size: 12, weight: .semibold))
                    Text(Self.time(event.end)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, alignment: .trailing)

            Capsule().fill(Theme.accentGradient).frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
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
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(event.title)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Label(dateRange, systemImage: "clock")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if let loc = event.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button { Task { await app.startNotes(for: event) } } label: {
                        Label("Start notes", systemImage: "record.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Theme.accentGradient, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.session != nil)

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
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(event.attendees.prefix(12), id: \.self) { name in
                            HStack(spacing: 9) {
                                Circle().fill(Theme.indigo.opacity(0.15))
                                    .frame(width: 24, height: 24)
                                    .overlay(Text(String(name.prefix(1)).uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.indigo))
                                Text(name).font(.system(size: 12))
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }

                if let notes = event.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.system(size: 13, weight: .semibold))
                        Text(notes).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private func pillLabel(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .foregroundStyle(.primary)
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
