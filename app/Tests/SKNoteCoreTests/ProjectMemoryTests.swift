import Foundation
import Testing
@testable import SKNoteCore

@Suite("Project memory")
struct ProjectMemoryTests {

    private func tempStore() -> MeetingStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-projmem-\(UUID().uuidString)", isDirectory: true)
        return MeetingStore(dataDir: dir)
    }

    @Test("ProjectMemory round-trips through Codable")
    func codableRoundTrip() throws {
        let memory = ProjectMemory(
            people: [ProjectPerson(name: "Kai", role: "Manager", notes: "prefers bullet updates")],
            platforms: ["Karbon", "Stripe"],
            context: "Tax season crunch.",
            imports: [])
        let data = try SKJSON.encoder.encode(memory)
        let back = try SKJSON.decoder.decode(ProjectMemory.self, from: data)
        #expect(back == memory)
    }

    @Test("rendered() lists people, platforms, and context compactly")
    func rendered() {
        let memory = ProjectMemory(
            people: [ProjectPerson(name: "Kai", role: "Manager", notes: "bullets")],
            platforms: ["Karbon", "Stripe"],
            context: "Tax season.")
        let text = memory.rendered()
        #expect(text.contains("Kai — Manager (bullets)"))
        #expect(text.contains("Karbon, Stripe"))
        #expect(text.contains("Tax season."))
    }

    @Test("isEmpty is true only with no details")
    func isEmpty() {
        #expect(ProjectMemory().isEmpty)
        #expect(!ProjectMemory(platforms: ["Stripe"]).isEmpty)
    }

    @Test("store saves and loads project memory per folder")
    func storeMemory() async throws {
        let store = tempStore()
        let folder = UUID()
        #expect(await store.projectMemory(for: folder).isEmpty)
        let memory = ProjectMemory(platforms: ["Notion"], context: "Alpha")
        try await store.saveProjectMemory(memory, for: folder)
        #expect(await store.projectMemory(for: folder) == memory)
        // A different folder is independent.
        #expect(await store.projectMemory(for: UUID()).isEmpty)
    }

    @Test("store saves and reads the living project.md")
    func storeMarkdown() async throws {
        let store = tempStore()
        let folder = UUID()
        #expect(await store.projectMarkdown(for: folder).isEmpty)
        try await store.saveProjectMarkdown("# Alpha — Working Memory\n", for: folder)
        #expect(await store.projectMarkdown(for: folder).contains("Working Memory"))
    }

    @Test("importing text stores it and registers the doc")
    func storeImport() async throws {
        let store = tempStore()
        let folder = UUID()
        let doc = try await store.addImport(title: "Kickoff notes", text: "hello world", for: folder)
        let memory = await store.projectMemory(for: folder)
        #expect(memory.imports.count == 1)
        #expect(memory.imports.first?.title == "Kickoff notes")
        #expect(await store.importText(doc.id, for: folder) == "hello world")
        try await store.removeImport(doc.id, for: folder)
        #expect(await store.projectMemory(for: folder).imports.isEmpty)
        #expect(await store.importText(doc.id, for: folder).isEmpty)
    }
}
