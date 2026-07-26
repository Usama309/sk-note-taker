import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SKNoteCore

/// A project a memory sheet can be opened for (Identifiable so it drives a `.sheet(item:)`).
struct ProjectRef: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// A project's memory: import anything to feed it, read the auto-generated working memory, and chat
/// with the whole project. The living `project.md` is what the copilot reads for fast answers.
struct ProjectMemorySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRef

    enum Tab: Hashable { case memory, chat }

    @State private var memory = ProjectMemory()
    @State private var projectMd = ""
    @State private var loaded = false
    @State private var tab = Tab.memory
    @State private var importing = false
    @State private var importStatus = ""
    // Project chat
    @State private var chat = ChatLog()
    @State private var question = ""
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.skTitle)
                    Text("Project memory").font(.skCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    app.openProjectFolder(project.id)
                } label: { Image(systemName: "folder") }
                    .help("Open this project's folder in Finder")
                Button("Done") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            Picker("", selection: $tab) {
                Text("Memory").tag(Tab.memory)
                Text("Chat").tag(Tab.chat)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .memory {
                memoryTab
            } else {
                chatTab
            }
        }
        .frame(width: 580, height: 660)
        .task { await load() }
    }

    // MARK: Memory tab

    private var memoryTab: some View {
        Form {
            importsSection
            Section("Notes") {
                TextEditor(text: $memory.context)
                    .font(.system(size: 13)).frame(minHeight: 70)
                Text("Optional. Anything the assistant should know. Most memory comes from your files and meetings.")
                    .font(.skFootnote).foregroundStyle(.tertiary)
            }
            if !projectMd.isEmpty {
                Section("Working memory (auto-generated)") {
                    Text(projectMd).font(.skMonoSmall).textSelection(.enabled)
                    Text("Rebuilt from your files and this project's meetings. This is what the assistant reads first.")
                        .font(.skFootnote).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var importsSection: some View {
        Section("Imported material") {
            ForEach(memory.imports) { doc in
                HStack {
                    Image(systemName: "doc.text")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.title).font(.skSubtitle)
                        Text(doc.addedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.skFootnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await app.removeProjectImport(doc.id, folderId: project.id); await reload() }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                importFiles()
            } label: { Label("Import files…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .disabled(importing)
            if importing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(importStatus).font(.skFootnote).foregroundStyle(.secondary)
                }
            }
            Text("Import anything: audio or video (transcribed), PDF, Word, CSV, or text. It becomes part of this project's memory.")
                .font(.skFootnote).foregroundStyle(.tertiary)
        }
    }

    // MARK: Chat tab

    private var chatTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            Text("Ask anything about this project. It answers from all of this project's meetings and imported material.")
                                .font(.skCallout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        ForEach(chat.messages) { message in ChatBubble(message: message) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask this project…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit(ask)
                Button(action: ask) {
                    if asking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            .padding(12)
        }
    }

    // MARK: Actions

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        question = ""
        asking = true
        Task {
            await app.askProject(project.id, question: q)
            chat = await app.projectChatLog(project.id)
            asking = false
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Import files into this project's memory"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        Task {
            for (i, url) in urls.enumerated() {
                importStatus = "Adding \(url.lastPathComponent)…"
                    + (urls.count > 1 ? " (\(i + 1)/\(urls.count))" : "")
                    + (FileImporter.isSlow(url) ? " — transcribing" : "")
                _ = await app.importFileIntoProject(url, folderId: project.id)
            }
            await reload()
            importing = false
            importStatus = ""
        }
    }

    private func load() async {
        memory = await app.loadProjectMemory(project.id)
        projectMd = await app.store.projectMarkdown(for: project.id)
        chat = await app.projectChatLog(project.id)
        loaded = true
    }

    private func reload() async {
        memory = await app.loadProjectMemory(project.id)
        projectMd = await app.store.projectMarkdown(for: project.id)
    }

    private func save() {
        let toSave = memory
        Task { await app.saveProjectMemory(toSave, for: project.id) }
        dismiss()
    }
}
