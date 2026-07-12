import SwiftUI
import SKNoteCore

/// The in-meeting experience: live transcript with speaker attribution on the left,
/// the user's rough notes on the right (Granola's notepad model).
struct LiveMeetingView: View {
    @Environment(AppState.self) private var app
    let session: MeetingSession
    @State private var notes = ""
    @State private var showSpeakers = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                transcriptPane
                    .frame(minWidth: 340)
                notesPane
                    .frame(minWidth: 300)
            }
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet(meetingId: session.meeting.id,
                          speakers: session.meeting.speakers)
        }
        .onChange(of: notes) {
            let id = session.meeting.id
            let text = notes
            Task { try? await app.store.saveNotes(text, for: id) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(session.phase == .recording ? 1 : 0.3)
                Text(session.phase == .preparing ? "Preparing…" :
                     session.phase == .finishing ? "Finishing…" : "Recording")
                    .font(.system(size: 13, weight: .semibold))
                Text(Theme.timestamp(session.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showSpeakers = true
            } label: {
                Label("Speakers", systemImage: "person.2")
            }

            Button {
                Task { await app.stopMeeting() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("End Meeting").fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.red.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .finishing)
            .keyboardShortcut("e", modifiers: [.command])
            .accessibilityLabel("End Meeting")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.liveSegments.isEmpty && session.volatileText.values.allSatisfy(\.isEmpty) {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.accentGradient)
                            Text("Listening… start talking or play meeting audio.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(session.liveSegments) { segment in
                        UtteranceBubble(
                            name: session.meeting.displayName(forSpeakerKey: segment.speaker),
                            color: Theme.speakerColor(segment.speaker),
                            time: segment.start,
                            text: segment.text,
                            volatile: false)
                            .id(segment.id)
                    }
                    ForEach([AudioChannel.mic, .system], id: \.self) { channel in
                        if let text = session.volatileText[channel], !text.isEmpty {
                            UtteranceBubble(
                                name: channel == .mic ? "You" : "…",
                                color: .secondary,
                                time: nil,
                                text: text,
                                volatile: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: session.liveSegments.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
        .background(.background.secondary.opacity(0.4))
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MY NOTES")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            Text("Jot rough bullets — they become anchors for the AI summary.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 2)
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
        }
    }
}

struct UtteranceBubble: View {
    let name: String
    let color: Color
    let time: Double?
    let text: String
    let volatile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                if let time {
                    Text(Theme.timestamp(time))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(volatile ? .secondary : .primary)
                .italic(volatile)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(volatile ? 0.05 : 0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
