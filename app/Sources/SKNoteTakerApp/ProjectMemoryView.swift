import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SKNoteCore

/// A project a memory sheet can be opened for (Identifiable so it drives a `.sheet(item:)`).
struct ProjectRef: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// Edit a project's memory: the people, the platforms, free-form context, and imported material.
/// Saving rebuilds the project's living `project.md`, which the copilot reads for fast answers.
struct ProjectMemorySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRef

    @State private var memory = ProjectMemory()
    @State private var projectMd = ""
    @State private var loaded = false
    @State private var newPlatform = ""
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.skTitle)
                    Text("Project memory").font(.skCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    peopleSection
                    platformsSection
                    Section("Context") {
                        TextEditor(text: $memory.context)
                            .font(.system(size: 13)).frame(minHeight: 80)
                        Text("Anything the assistant should know about this project or company.")
                            .font(.skFootnote).foregroundStyle(.tertiary)
                    }
                    importsSection
                    if !projectMd.isEmpty {
                        Section("Working memory (auto-generated)") {
                            Text(projectMd).font(.skMonoSmall).textSelection(.enabled)
                            Text("Rebuilt from your details and this project's meetings. This is what the assistant reads first.")
                                .font(.skFootnote).foregroundStyle(.tertiary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 580, height: 660)
        .task {
            memory = await app.loadProjectMemory(project.id)
            projectMd = await app.store.projectMarkdown(for: project.id)
            loaded = true
        }
    }

    private var peopleSection: some View {
        Section("People") {
            ForEach($memory.people) { $person in
                VStack(spacing: 4) {
                    HStack {
                        TextField("Name", text: $person.name)
                        TextField("Role", text: $person.role)
                        Button(role: .destructive) {
                            memory.people.removeAll { $0.id == person.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    TextField("Notes (how they like to work, what they care about)", text: $person.notes)
                        .font(.skCaption)
                }
                .padding(.vertical, 2)
            }
            Button {
                memory.people.append(ProjectPerson(name: ""))
            } label: { Label("Add person", systemImage: "person.badge.plus") }
                .buttonStyle(.borderless)
        }
    }

    private var platformsSection: some View {
        Section("Platforms & tools") {
            if !memory.platforms.isEmpty {
                WrapChips(items: memory.platforms) { platform in
                    memory.platforms.removeAll { $0 == platform }
                }
            }
            HStack {
                TextField("Add a platform (Stripe, Karbon, Notion…)", text: $newPlatform)
                    .onSubmit(addPlatform)
                Button("Add", action: addPlatform).disabled(newPlatform.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
                importFile()
            } label: { Label("Import a transcript or notes file…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderless)
                .disabled(importing)
            Text("Import past transcripts, notes, or docs (.txt, .md). They become part of this project's memory.")
                .font(.skFootnote).foregroundStyle(.tertiary)
        }
    }

    private func addPlatform() {
        let p = newPlatform.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !memory.platforms.contains(p) else { return }
        memory.platforms.append(p)
        newPlatform = ""
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, .text]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        importing = true
        let urls = panel.urls
        Task {
            for url in urls {
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                    await app.importIntoProject(title: url.deletingPathExtension().lastPathComponent,
                                                text: text, folderId: project.id)
                }
            }
            await reload()
            importing = false
        }
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

/// A simple wrapping row of removable chips.
private struct WrapChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.skCaption)
                    Button { onRemove(item) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.indigo.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Minimal flow layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
