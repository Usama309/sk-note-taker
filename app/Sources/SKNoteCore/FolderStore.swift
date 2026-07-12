import Foundation

/// Folder tree persisted as a single folders.json in the data dir.
public actor FolderStore {
    public let dataDir: URL

    private struct FolderFile: Codable {
        var folders: [Folder]
    }

    public init(dataDir: URL? = nil) {
        self.dataDir = dataDir ?? MeetingStore.defaultDataDir()
    }

    private var fileURL: URL { dataDir.appendingPathComponent("folders.json") }

    public func all() -> [Folder] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? SKJSON.decoder.decode(FolderFile.self, from: data) else { return [] }
        return file.folders
    }

    public func save(_ folders: [Folder]) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let data = try SKJSON.encoder.encode(FolderFile(folders: folders))
        let tmp = dataDir.appendingPathComponent(".folders.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }

    @discardableResult
    public func add(_ folder: Folder) throws -> Folder {
        var folders = all()
        folders.append(folder)
        try save(folders)
        return folder
    }

    public func rename(id: UUID, to name: String) throws {
        var folders = all()
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = name
        try save(folders)
    }

    public func remove(id: UUID) throws {
        var folders = all()
        let childIds = Set(folders.filter { $0.parentId == id }.map(\.id))
        folders.removeAll { $0.id == id || childIds.contains($0.id) }
        try save(folders)
    }

    /// Find a folder by case-insensitive name (optionally under a parent).
    public func find(named name: String, parentId: UUID? = nil) -> Folder? {
        all().first {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                && $0.parentId == parentId
        }
    }

    /// Resolve "Client / Project" into folder ids, creating missing folders.
    /// Returns the deepest folder id (project if given, else client).
    public func resolveOrCreate(client: String?, project: String?) throws -> UUID? {
        var clientFolder: Folder?
        if let client, !client.isEmpty {
            clientFolder = find(named: client)
            if clientFolder == nil {
                clientFolder = try add(Folder(name: client, kind: .client))
            }
        }
        if let project, !project.isEmpty {
            if let existing = find(named: project, parentId: clientFolder?.id) {
                return existing.id
            }
            let created = try add(Folder(name: project, kind: .project, parentId: clientFolder?.id))
            return created.id
        }
        return clientFolder?.id
    }

    /// Human-readable path like "Acme Corp / Website Redesign".
    public func path(for id: UUID?) -> String {
        guard let id else { return "" }
        let folders = Dictionary(uniqueKeysWithValues: all().map { ($0.id, $0) })
        var parts: [String] = []
        var current = folders[id]
        while let folder = current {
            parts.insert(folder.name, at: 0)
            current = folder.parentId.flatMap { folders[$0] }
        }
        return parts.joined(separator: " / ")
    }
}
