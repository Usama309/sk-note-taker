import SwiftUI

/// The app's keyboard map, mounted once behind the window content.
///
/// These are zero-sized buttons rather than `.keyboardShortcut` on real controls because the
/// actions they trigger (open the palette, switch library filters) have no single owning view.
/// Text fields keep first responder, so typing is never intercepted.
struct GlobalShortcuts: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            Button("") { togglePalette() }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { app.focusSearch.toggle() }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { app.libraryFilter = .all }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { app.libraryFilter = .starred }
                .keyboardShortcut("2", modifiers: .command)
            Button("") { if app.calendarConnected { app.libraryFilter = .upcoming } }
                .keyboardShortcut("3", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func togglePalette() {
        withAnimation(Theme.Motion.snap) { app.showCommandPalette.toggle() }
    }
}
