import SwiftUI
import SKNoteCore

/// The Cmd+K command palette: a Spotlight-style overlay for running any action, jumping to any
/// meeting, or switching views without touching the mouse.
///
/// Rendered as an overlay in the window (not a sheet) so it appears instantly and dismisses with
/// Escape or a click on the scrim.
struct CommandPaletteView: View {
    @Environment(AppState.self) private var app
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var selection = 0

    /// Built fresh from live app state on every evaluation: availability (End Meeting only while
    /// recording), the meeting list, and projects are always current, and there is no cached
    /// snapshot that can go stale between keystrokes.
    private var results: [SKCommand] {
        CommandRegistry.rank(CommandRegistry.commands(for: app), query: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: click anywhere outside the panel to dismiss.
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field
                if !results.isEmpty {
                    Divider().opacity(0.6)
                    list
                } else {
                    emptyState
                }
            }
            .frame(width: 560)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.dialogRadius, style: .continuous)
                .strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
            .padding(.top, 96)
            .background(keyboardHandlers)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selection = 0 }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Search actions, meetings, projects…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit { runSelected() }
            Text("esc")
                .font(.skBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Identity is the command id. An .id(index) here would pin row identity to
                    // position, letting SwiftUI keep stale content when the results change.
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, cmd in
                        row(cmd, index: index)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)
            .onChange(of: selection) {
                guard results.indices.contains(selection) else { return }
                proxy.scrollTo(results[selection].id, anchor: .center)
            }
        }
    }

    private func row(_ cmd: SKCommand, index: Int) -> some View {
        let active = index == selection
        return Button {
            run(cmd)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: cmd.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(cmd.tint ?? Theme.accent)
                    .frame(width: 20)
                Text(cmd.title)
                    .font(.skBody)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let hint = cmd.shortcutHint {
                    Text(hint)
                        .font(.skBadge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }
                Text(cmd.group)
                    .font(.skFootnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(active ? Theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = index } }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No matches").font(.skHeadline)
            Text("Try a meeting title, a project, or an action.")
                .font(.skCallout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: Keyboard

    /// Arrow keys move the selection; Return runs it; Escape closes. Wired as hidden buttons so
    /// the text field keeps focus (a .onKeyPress on the field would swallow typing).
    var keyboardHandlers: some View {
        Group {
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { close() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ cmd: SKCommand) {
        close()
        cmd.run()
    }

    private func close() {
        withAnimation(Theme.Motion.snap) { app.showCommandPalette = false }
    }
}
