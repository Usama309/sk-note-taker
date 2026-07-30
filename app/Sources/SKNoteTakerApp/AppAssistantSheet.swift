import SwiftUI
import SKNoteCore

/// The whole-app assistant: a chat with access to every meeting and project. It answers questions
/// ("what are my open tasks", "what happened with X") and can propose one action to run after the
/// user confirms.
struct AppAssistantSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Assistant", systemImage: "sparkles").font(.skTitle)
                Spacer()
                if !app.appAssistantChat.messages.isEmpty {
                    Button("Clear") {
                        app.appAssistantChat = ChatLog()
                        app.pendingAppAction = nil
                        Task { try? await app.store.saveAppChat(app.appAssistantChat) }
                    }
                    .buttonStyle(.borderless)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if app.appAssistantChat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ask me anything across your meetings and projects.")
                                    .font(.skSubtitle)
                                Text("Try: “What are my open tasks?”, “What happened with the tax project?”, “Rebuild the Acme memory”, “Start a meeting”.")
                                    .font(.skCallout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        ForEach(app.appAssistantChat.messages) { message in ChatBubble(message: message) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: app.appAssistantChat.messages.count) { _, _ in
                    withAnimation(Theme.Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if let action = app.pendingAppAction {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent)
                    Text(action.label ?? "Perform this action?").font(.skCallout)
                    Spacer()
                    Button("Dismiss") { app.pendingAppAction = nil }.buttonStyle(.bordered)
                    Button("Do it") { Task { await app.runPendingAppAction() } }.buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Theme.selection)
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about your meetings, tasks, projects…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit(ask)
                Button(action: ask) {
                    if asking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .task { await app.loadAppChat() }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        question = ""
        asking = true
        Task { await app.askApp(q); asking = false }
    }
}
