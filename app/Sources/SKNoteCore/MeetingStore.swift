import Foundation

/// On-disk store shared with the MCP server and web view. One directory per meeting under
/// `<dataDir>/meetings/<uuid>/`. Writes are atomic (temp file + rename) because the web app
/// may write meeting.json concurrently.
public actor MeetingStore {
    public let dataDir: URL

    public init(dataDir: URL? = nil) {
        self.dataDir = dataDir ?? Self.defaultDataDir()
    }

    public static func defaultDataDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["SKNOTE_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SKNoteTaker", isDirectory: true)
    }

    public func meetingsDir() -> URL {
        dataDir.appendingPathComponent("meetings", isDirectory: true)
    }

    public func dir(for id: UUID) -> URL {
        meetingsDir().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Meetings

    public func save(_ meeting: Meeting) throws {
        let dir = dir(for: meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(meeting), to: dir.appendingPathComponent("meeting.json"))
    }

    public func meeting(id: UUID) throws -> Meeting? {
        let url = dir(for: id).appendingPathComponent("meeting.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SKJSON.decoder.decode(Meeting.self, from: Data(contentsOf: url))
    }

    public func allMeetings() -> [Meeting] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: meetingsDir(), includingPropertiesForKeys: nil) else { return [] }
        var result: [Meeting] = []
        for entry in entries {
            // Finder drops .DS_Store in here; it is not a meeting folder, so don't treat it as one.
            if entry.lastPathComponent.hasPrefix(".") { continue }
            let url = entry.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: url),
                  let meeting = try? SKJSON.decoder.decode(Meeting.self, from: data) else {
                // An empty file is a meeting still being written (or one whose write was
                // interrupted), not a corrupt one. Only shout about a file with real content in it,
                // otherwise every interrupted run logs a scary error for a file that is fine.
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
                if size > 0 {
                    SKLog.error(.storeReadFailed, .store,
                                "Skipping malformed file: \(entry.lastPathComponent)/meeting.json")
                }
                continue
            }
            result.append(meeting)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: dir(for: id))
    }

    // MARK: - Transcript

    public func save(_ transcript: Transcript, for id: UUID) throws {
        let dir = dir(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(transcript), to: dir.appendingPathComponent("transcript.json"))
    }

    public func transcript(for id: UUID) throws -> Transcript? {
        let url = dir(for: id).appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SKJSON.decoder.decode(Transcript.self, from: Data(contentsOf: url))
    }

    // MARK: - Notes

    public func saveNotes(_ markdown: String, for id: UUID) throws {
        let dir = dir(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(Data(markdown.utf8), to: dir.appendingPathComponent("notes.md"))
    }

    public func notes(for id: UUID) -> String {
        let url = dir(for: id).appendingPathComponent("notes.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Summary (markdown + YAML front-matter)

    public func saveSummary(_ summary: SummaryData, for id: UUID) throws {
        let dir = dir(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(Data(SummaryFrontMatter.render(summary).utf8),
                        to: dir.appendingPathComponent("summary.md"))
    }

    public func summary(for id: UUID) -> SummaryData? {
        let url = dir(for: id).appendingPathComponent("summary.md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SummaryFrontMatter.parse(raw)
    }

    // MARK: - Chat

    public func saveChat(_ chat: ChatLog, for id: UUID) throws {
        let dir = dir(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(chat), to: dir.appendingPathComponent("chat.json"))
    }

    public func chat(for id: UUID) -> ChatLog {
        let url = dir(for: id).appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: url),
              let chat = try? SKJSON.decoder.decode(ChatLog.self, from: data) else {
            return ChatLog()
        }
        return chat
    }

    // MARK: - Recording

    public func recordingURL(for id: UUID) -> URL {
        dir(for: id).appendingPathComponent("recording.m4a")
    }

    public func screenRecordingURL(for id: UUID) -> URL {
        dir(for: id).appendingPathComponent("screen.mov")
    }

    // MARK: - Project memory (per folder)

    public func foldersDir() -> URL {
        dataDir.appendingPathComponent("folders", isDirectory: true)
    }

    public func folderDir(for folderId: UUID) -> URL {
        foldersDir().appendingPathComponent(folderId.uuidString, isDirectory: true)
    }

    public func projectMemory(for folderId: UUID) -> ProjectMemory {
        let url = folderDir(for: folderId).appendingPathComponent("memory.json")
        guard let data = try? Data(contentsOf: url),
              let m = try? SKJSON.decoder.decode(ProjectMemory.self, from: data) else {
            return ProjectMemory()
        }
        return m
    }

    public func saveProjectMemory(_ memory: ProjectMemory, for folderId: UUID) throws {
        let dir = folderDir(for: folderId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(memory), to: dir.appendingPathComponent("memory.json"))
    }

    /// The living knowledge file the assistant reads first. Empty string when not built yet.
    public func projectMarkdown(for folderId: UUID) -> String {
        let url = folderDir(for: folderId).appendingPathComponent("project.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func saveProjectMarkdown(_ markdown: String, for folderId: UUID) throws {
        let dir = folderDir(for: folderId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(Data(markdown.utf8), to: dir.appendingPathComponent("project.md"))
    }

    private func importsDir(for folderId: UUID) -> URL {
        folderDir(for: folderId).appendingPathComponent("imports", isDirectory: true)
    }

    /// Add imported text (a pasted transcript / note / an imported recording's transcript) to a
    /// project's memory. Returns the new doc's metadata.
    @discardableResult
    public func addImport(title: String, text: String, for folderId: UUID) throws -> ImportedDoc {
        let doc = ImportedDoc(id: UUID(), title: title, addedAt: Date())
        let dir = importsDir(for: folderId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(Data(text.utf8), to: dir.appendingPathComponent("\(doc.id.uuidString).txt"))
        var memory = projectMemory(for: folderId)
        memory.imports.append(doc)
        try saveProjectMemory(memory, for: folderId)
        return doc
    }

    public func importText(_ docId: UUID, for folderId: UUID) -> String {
        let url = importsDir(for: folderId).appendingPathComponent("\(docId.uuidString).txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func projectChat(for folderId: UUID) -> ChatLog {
        let url = folderDir(for: folderId).appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: url),
              let chat = try? SKJSON.decoder.decode(ChatLog.self, from: data) else { return ChatLog() }
        return chat
    }

    public func saveProjectChat(_ chat: ChatLog, for folderId: UUID) throws {
        let dir = folderDir(for: folderId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(chat), to: dir.appendingPathComponent("chat.json"))
    }

    public func removeImport(_ docId: UUID, for folderId: UUID) throws {
        try? FileManager.default.removeItem(
            at: importsDir(for: folderId).appendingPathComponent("\(docId.uuidString).txt"))
        var memory = projectMemory(for: folderId)
        memory.imports.removeAll { $0.id == docId }
        try saveProjectMemory(memory, for: folderId)
    }

    // MARK: - App assistant chat

    public func appChat() -> ChatLog {
        let url = dataDir.appendingPathComponent("app-assistant-chat.json")
        guard let data = try? Data(contentsOf: url),
              let chat = try? SKJSON.decoder.decode(ChatLog.self, from: data) else { return ChatLog() }
        return chat
    }

    public func saveAppChat(_ chat: ChatLog) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(chat), to: dataDir.appendingPathComponent("app-assistant-chat.json"))
    }

    // MARK: - Settings

    public func loadSettings() -> AppSettings {
        let url = dataDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? SKJSON.decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    public func save(settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try atomicWrite(SKJSON.encoder.encode(settings), to: dataDir.appendingPathComponent("settings.json"))
    }

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - Front-matter codec

/// Minimal YAML front-matter renderer/parser for the fixed summary schema. Not a general YAML
/// implementation — only the shapes SummaryData produces.
public enum SummaryFrontMatter {
    public static func render(_ s: SummaryData) -> String {
        var out = "---\n"
        out += "generatedAt: \(ISO8601DateFormatter().string(from: s.generatedAt))\n"
        out += "actionItems:\n"
        for item in s.actionItems {
            out += "  - owner: \(yamlScalar(item.owner ?? ""))\n"
            out += "    text: \(yamlScalar(item.text))\n"
        }
        out += "decisions:\n"
        for d in s.decisions { out += "  - \(yamlScalar(d))\n" }
        out += "remember:\n"
        for r in s.remember { out += "  - \(yamlScalar(r))\n" }
        out += "---\n"
        out += s.body
        return out
    }

    public static func parse(_ raw: String) -> SummaryData {
        var summary = SummaryData()
        guard raw.hasPrefix("---") else {
            summary.body = raw
            return summary
        }
        let lines = raw.components(separatedBy: "\n")
        var i = 1
        var section = ""
        var pendingOwner: String?
        while i < lines.count, lines[i] != "---" {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("generatedAt:") {
                let v = String(line.dropFirst("generatedAt:".count)).trimmingCharacters(in: .whitespaces)
                summary.generatedAt = ISO8601DateFormatter().date(from: v) ?? summary.generatedAt
            } else if line.hasPrefix("actionItems:") { section = "actionItems" }
            else if line.hasPrefix("decisions:") { section = "decisions" }
            else if line.hasPrefix("remember:") { section = "remember" }
            else if trimmed.hasPrefix("- owner:"), section == "actionItems" {
                pendingOwner = unquote(String(trimmed.dropFirst("- owner:".count)))
            } else if trimmed.hasPrefix("text:"), section == "actionItems" {
                let text = unquote(String(trimmed.dropFirst("text:".count)))
                summary.actionItems.append(.init(
                    owner: pendingOwner?.isEmpty == true ? nil : pendingOwner, text: text))
                pendingOwner = nil
            } else if trimmed.hasPrefix("- ") {
                let value = unquote(String(trimmed.dropFirst(2)))
                if section == "decisions" { summary.decisions.append(value) }
                else if section == "remember" { summary.remember.append(value) }
            }
            i += 1
        }
        if i < lines.count {
            summary.body = lines[(i + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return summary
    }

    private static func yamlScalar(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            t = String(t.dropFirst().dropLast())
            t = t.replacingOccurrences(of: "\\\"", with: "\"")
                 .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }
}
