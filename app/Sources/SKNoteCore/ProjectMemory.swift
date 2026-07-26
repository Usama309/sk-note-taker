import Foundation

/// A person on a project: who they are and anything worth remembering about them.
public struct ProjectPerson: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var role: String
    public var notes: String

    public init(id: UUID = UUID(), name: String, role: String = "", notes: String = "") {
        self.id = id
        self.name = name
        self.role = role
        self.notes = notes
    }
}

/// A piece of external material imported into a project's memory (a pasted transcript, a note, or
/// the transcript of an imported recording). The text lives next to the metadata as `<id>.txt`.
public struct ImportedDoc: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, addedAt: Date) {
        self.id = id
        self.title = title
        self.addedAt = addedAt
    }
}

/// A project's structured memory: the people, the tools, free-form context, and imported material.
/// The project's filed meetings are not stored here (they live in the meeting store); they are
/// folded in when the living `project.md` is rebuilt.
public struct ProjectMemory: Codable, Sendable, Equatable {
    public var people: [ProjectPerson]
    public var platforms: [String]
    public var context: String
    public var imports: [ImportedDoc]

    public init(people: [ProjectPerson] = [], platforms: [String] = [],
                context: String = "", imports: [ImportedDoc] = []) {
        self.people = people
        self.platforms = platforms
        self.context = context
        self.imports = imports
    }

    public var isEmpty: Bool {
        people.isEmpty && platforms.isEmpty
            && context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imports.isEmpty
    }

    /// A compact human-readable rendering of the structured details, for feeding to the assistant
    /// and the project.md builder.
    public func rendered() -> String {
        var out: [String] = []
        if !people.isEmpty {
            out.append("People:")
            for p in people {
                let role = p.role.isEmpty ? "" : " — \(p.role)"
                let notes = p.notes.isEmpty ? "" : " (\(p.notes))"
                out.append("- \(p.name)\(role)\(notes)")
            }
        }
        if !platforms.isEmpty {
            out.append("Platforms & tools: \(platforms.joined(separator: ", "))")
        }
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            out.append("Context:\n\(ctx)")
        }
        return out.joined(separator: "\n")
    }
}
