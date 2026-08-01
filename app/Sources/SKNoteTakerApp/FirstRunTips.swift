import SwiftUI

/// A short, one-time coach shown right after a new user finishes setup. Four paged tips that teach
/// the core loop (record, ask the assistant, organize, privacy), then never appears again.
struct FirstRunTipsView: View {
    @Environment(AppState.self) private var app
    @State private var index = 0

    private struct Tip { let icon: String; let title: String; let body: String; let tint: Color }
    private let tips: [Tip] = [
        Tip(icon: "record.circle.fill", title: "Start a meeting",
            body: "Hit Start Meeting on Home (or ⌘N). SK captures your mic and the other side, and transcribes live with real names.",
            tint: Theme.accent),
        Tip(icon: "sparkles", title: "Your AI assistant",
            body: "Open Assistant in the sidebar to ask about any meeting, pull action items, or draft a reply. It reads your notes, not the cloud.",
            tint: Theme.accent),
        Tip(icon: "folder.fill", title: "Organize by project",
            body: "Drag meetings into a project to give it living memory. Import past recordings, docs, and people so every summary has context.",
            tint: Theme.folderPalette[1]),
        Tip(icon: "lock.fill", title: "Everything stays on your Mac",
            body: "Recordings, transcripts, and summaries are stored locally and processed on-device. Nothing is uploaded to a server we run.",
            tint: Theme.accent),
    ]

    private var isLast: Bool { index == tips.count - 1 }

    var body: some View {
        let tip = tips[index]
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(tip.tint.opacity(0.16)).frame(width: 84, height: 84)
                    Image(systemName: tip.icon).font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tip.tint)
                }
                .padding(.top, 10)
                VStack(spacing: 8) {
                    Text(tip.title).font(.skHero)
                    Text(tip.body).font(.skBody).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(index)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)

            HStack(spacing: 6) {
                ForEach(tips.indices, id: \.self) { i in
                    Capsule().fill(i == index ? Theme.mint : Theme.border)
                        .frame(width: i == index ? 20 : 7, height: 7)
                }
            }
            .animation(Theme.Motion.standard, value: index)
            .padding(.bottom, 16)

            Divider().opacity(0.5)
            HStack {
                Button("Skip tips") { app.finishTips() }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).font(.skCallout)
                Spacer()
                Button {
                    if isLast { app.finishTips() }
                    else { withAnimation(Theme.Motion.standard) { index += 1 } }
                } label: {
                    Text(isLast ? "Get started" : "Next")
                        .fontWeight(.semibold).padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 460, height: 430)
    }
}
