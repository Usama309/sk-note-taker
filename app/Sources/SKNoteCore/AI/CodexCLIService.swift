import Foundation

/// All AI features run through `codex exec` using the developer's Codex CLI sign-in.
/// Prompts are isolated from project and user configuration and never require an API key.
public actor CodexCLIService {
    public var model: String
    private var resolvedBinary: String?

    public init(model: String = "") {
        self.model = model
    }

    // MARK: - Public features

    /// Granola-style "enhanced notes": intelligent summary with action items, decisions,
    /// and things to remember. User notes act as anchors/priority signals.
    public func summarize(meeting: Meeting, transcript: Transcript,
                          notes: String) async throws -> SummaryData {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw CodexCLIError.emptyTranscript }

        let schema = """
        {"type":"object","properties":{
          "summary_markdown":{"type":"string","description":"Well-structured markdown summary of the meeting"},
          "action_items":{"type":"array","items":{"type":"object","properties":{
            "owner":{"type":["string","null"]},"text":{"type":"string"}},
            "required":["owner","text"],"additionalProperties":false}},
          "decisions":{"type":"array","items":{"type":"string"}},
          "things_to_remember":{"type":"array","items":{"type":"string"}}
        },"required":["summary_markdown","action_items","decisions","things_to_remember"],
          "additionalProperties":false}
        """

        let prompt = """
        You are the summarization engine of SK Note Taker, a meeting notes app.
        Produce an intelligent meeting summary from the diarized transcript below.

        Rules:
        - The user's own rough notes (if any) are priority signals: expand each of their \
        points using everything relevant in the transcript.
        - Attribute key statements to speakers by name where it matters.
        - summary_markdown: start with a one-paragraph plain-language overview under a \
        "## Quick summary" heading (do NOT use the label "TL;DR"), then sections with headings \
        (use the user's note bullets as section anchors when present).
        - action_items: concrete follow-ups with the responsible person as owner when \
        identifiable from the conversation.
        - decisions: decisions that were actually made (not proposals).
        - things_to_remember: durable facts worth remembering later (preferences, dates, \
        constraints, commitments).

        Meeting title: \(meeting.title)
        Date: \(meeting.createdAt.formatted(date: .long, time: .shortened))

        USER'S ROUGH NOTES:
        \(notes.isEmpty ? "(none)" : notes)

        TRANSCRIPT:
        \(rendered)
        """

        let output = try await run(prompt: prompt, jsonSchema: schema)
        guard let structured = output.structured else {
            throw CodexCLIError.badOutput("no structured output")
        }
        struct Payload: Decodable {
            struct Item: Decodable { let owner: String?; let text: String }
            let summary_markdown: String
            let action_items: [Item]
            let decisions: [String]
            let things_to_remember: [String]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: structured)
        return SummaryData(
            generatedAt: Date(),
            actionItems: payload.action_items.map { .init(owner: $0.owner, text: $0.text) },
            decisions: payload.decisions,
            remember: payload.things_to_remember,
            body: payload.summary_markdown)
    }

    /// Chat with a meeting: "What did Kainat say about the deadline?"
    public func answer(question: String, meeting: Meeting, transcript: Transcript,
                       history: ChatLog) async throws -> String {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw CodexCLIError.emptyTranscript }

        let historyText = history.messages.suffix(10).map {
            "\($0.role == "user" ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")

        let prompt = """
        You are the meeting assistant inside SK Note Taker. Answer the user's question using \
        ONLY the transcript below. Speakers are identified by name (or "Speaker N" when \
        unnamed). Quote or paraphrase what specific people actually said, with timestamps \
        like [12:34] when referencing specific moments. If the transcript doesn't contain \
        the answer, say so plainly. Be concise and direct.

        Meeting: \(meeting.title) — \(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))

        TRANSCRIPT:
        \(rendered)

        \(historyText.isEmpty ? "" : "PREVIOUS Q&A:\n\(historyText)\n")
        QUESTION: \(question)
        """
        let output = try await run(prompt: prompt, jsonSchema: nil)
        return output.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// In-meeting assistant: fast, actionable help while the call is still running.
    /// The transcript is the LIVE one (may end mid-sentence); answers must be quick to scan.
    public func liveAssist(question: String, meeting: Meeting, transcript: Transcript,
                           history: ChatLog, userName: String?) async throws -> String {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw CodexCLIError.emptyTranscript }
        // Latency matters mid-call: keep only the most recent context.
        let tail = String(rendered.suffix(12_000))

        let historyText = history.messages.suffix(6).map {
            "\($0.role == "user" ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")

        let prompt = """
        You are the LIVE meeting assistant inside SK Note Taker. The meeting is happening \
        RIGHT NOW; the transcript below is live and may cut off mid-sentence. The user \
        (\(userName ?? "the meeting owner"), the "mic" speaker) needs help immediately, \
        while people are talking.

        Rules:
        - Answer first, context after. 1–3 short sentences or a tight bullet list. No preamble, \
        no "Sure" / "Here's" / restating the question — just the answer, scannable in a glance.
        - When asked to catch up: recap only what matters — topics, asks, open questions.
        - When asked what someone means: explain their point in plain language.
        - When asked what to respond: give 1–3 concrete things the user could say, in a \
        natural first-person voice they can read out loud.
        - Use speaker names. If the transcript doesn't contain the answer, say so in one line.

        Meeting: \(meeting.title)

        LIVE TRANSCRIPT (most recent part):
        \(tail)

        \(historyText.isEmpty ? "" : "PREVIOUS Q&A:\n\(historyText)\n")
        QUESTION: \(question)
        """
        let output = try await run(prompt: prompt, jsonSchema: nil)
        return output.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Categorize a meeting into client/project folders (existing folders preferred), and
    /// propose a concise human title to replace the default timestamp one.
    public func categorize(meeting: Meeting, transcript: Transcript,
                           existingFolders: [Folder],
                           folderPath: @Sendable (UUID?) -> String) async throws
        -> (category: AutoCategory, title: String?) {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw CodexCLIError.emptyTranscript }

        let folderList = existingFolders
            .map { "- \($0.kind.rawValue): \(folderPath($0.id))" }
            .joined(separator: "\n")

        let schema = """
        {"type":"object","properties":{
          "client":{"type":["string","null"],"description":"Client/company name, or null"},
          "project":{"type":["string","null"],"description":"Project name, or null"},
          "confidence":{"type":"number","minimum":0,"maximum":1},
          "title":{"type":["string","null"],"description":"Concise meeting title, max 6 words, no dates, or null if the transcript gives no signal"}
        },"required":["client","project","confidence","title"],"additionalProperties":false}
        """

        let head = String(rendered.prefix(6000))
        let prompt = """
        Categorize this meeting into a client and project for folder organization, and \
        propose a concise descriptive title (what the meeting was ABOUT, max 6 words, \
        no dates — the app shows the date separately).
        STRONGLY prefer reusing an existing client/project (exact names below) when the \
        meeting clearly belongs there; only propose a new name when nothing fits. Use \
        null when the transcript gives no signal. Client = company/person being served; \
        project = the specific engagement/initiative.

        EXISTING FOLDERS:
        \(folderList.isEmpty ? "(none yet)" : folderList)

        MEETING TITLE: \(meeting.title)
        TRANSCRIPT (start):
        \(head)
        """
        let output = try await run(prompt: prompt, jsonSchema: schema)
        guard let structured = output.structured else {
            throw CodexCLIError.badOutput("no structured output")
        }
        struct Payload: Decodable {
            let client: String?
            let project: String?
            let confidence: Double
            let title: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: structured)
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (AutoCategory(project: payload.project, client: payload.client,
                             confidence: payload.confidence),
                title?.isEmpty == true ? nil : title)
    }

    // MARK: - Meeting copilot (project memory + live answers)

    /// The live copilot's answer: the exact wording to say, optional supporting notes, and where it
    /// came from.
    public struct AssistAnswer: Codable, Sendable, Equatable {
        public var say: String
        public var notes: [String]
        public var source: String   // "memory" | "web" | "transcript" | "unknown"
        public init(say: String, notes: [String] = [], source: String = "memory") {
            self.say = say
            self.notes = notes
            self.source = source
        }
    }

    /// Memory-backed live answer: tells the user the exact words to say, drawn from the project's
    /// living memory, the live transcript, and (when allowed and needed) a quick web lookup.
    public func assistWithMemory(question: String, meeting: Meeting, transcript: Transcript,
                                 history: ChatLog, userName: String?,
                                 projectMarkdown: String, projectDetails: String,
                                 allowWeb: Bool) async throws -> AssistAnswer {
        let rendered = transcript.rendered(with: meeting)
        let tail = String(rendered.suffix(12_000))
        let historyText = history.messages.suffix(6).map {
            "\($0.role == "user" ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")

        let schema = """
        {"type":"object","properties":{
          "say":{"type":"string","description":"The EXACT words for the user to say out loud, first person, 1-2 sentences, natural and speakable"},
          "notes":{"type":"array","items":{"type":"string"},"description":"0-2 short supporting facts, optional"},
          "source":{"type":"string","enum":["memory","web","transcript","unknown"]}
        },"required":["say","notes","source"],"additionalProperties":false}
        """

        let prompt = """
        You are the LIVE meeting copilot inside SK Note Taker. The meeting is happening RIGHT NOW. \
        Your job is to tell \(userName ?? "the user") the EXACT words to say next, so they can read \
        your "say" text aloud immediately. Draw on the project memory, the live transcript, and \
        (only if needed) a quick web lookup.

        \(CommunicationPlaybook.text)

        Return: "say" = the exact wording to read aloud (1-2 sentences); "notes" = at most two short \
        supporting facts, optional; "source" = where the answer mainly came from.

        PROJECT MEMORY (project.md — read this first):
        \(projectMarkdown.isEmpty ? "(none yet)" : projectMarkdown)

        PROJECT DETAILS:
        \(projectDetails.isEmpty ? "(none)" : projectDetails)

        Meeting: \(meeting.title)
        LIVE TRANSCRIPT (most recent part):
        \(tail.isEmpty ? "(nothing yet)" : tail)

        \(historyText.isEmpty ? "" : "PREVIOUS Q&A:\n\(historyText)\n")
        \(allowWeb ? "If the answer needs current or external facts that are not in the memory (a how-to, a price, a policy, steps in a tool), use web search to get them, then give the exact wording. " : "")\
        QUESTION / WHAT THE USER NEEDS TO SAY: \(question)
        """
        let output = try await run(prompt: prompt, jsonSchema: schema, allowWeb: allowWeb)
        guard let structured = output.structured else {
            throw CodexCLIError.badOutput("no structured output")
        }
        struct Payload: Decodable { let say: String; let notes: [String]?; let source: String? }
        let p = try JSONDecoder().decode(Payload.self, from: structured)
        return AssistAnswer(say: p.say.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: p.notes ?? [], source: p.source ?? "memory")
    }

    /// Where an imported file should go, decided from the user's plain-language instruction.
    public struct ImportRoute: Codable, Sendable, Equatable {
        public var project: String   // target project name (an existing one, or a new one to create)
        public var title: String     // a short title for the imported material
        public var note: String      // 1-2 sentences on what the file is / what it's for
        public init(project: String, title: String, note: String) {
            self.project = project; self.title = title; self.note = note
        }
    }

    /// Decide which project a dropped file belongs to and a note about it, from the user's
    /// instruction ("this is the Acme SOW, put it in the Acme project as the signed contract").
    public func routeImport(instruction: String, fileNames: [String],
                            projects: [String]) async throws -> ImportRoute {
        let schema = """
        {"type":"object","properties":{
          "project":{"type":"string","description":"Target project name — an EXISTING one (exact name) if it fits, else a concise new project name"},
          "title":{"type":"string","description":"Short title for the imported material"},
          "note":{"type":"string","description":"1-2 sentences: what this file is and what it's for"}
        },"required":["project","title","note"],"additionalProperties":false}
        """
        let prompt = """
        A file is being imported into a PROJECT's memory. From the user's instruction, decide which \
        project it belongs to and write a short note about the file.

        "project" MUST be one of the existing projects below (use the exact name) when the \
        instruction fits one; otherwise a concise NEW project name taken from the instruction. Never \
        answer with an app name — only a project.

        Existing projects: \(projects.isEmpty ? "(none yet)" : projects.joined(separator: ", "))
        File(s): \(fileNames.joined(separator: ", "))
        User's instruction: \(instruction.isEmpty ? "(none — infer the project from the file name)" : "\"\(instruction)\"")
        """
        let output = try await run(prompt: prompt, jsonSchema: schema)
        guard let structured = output.structured else { throw CodexCLIError.badOutput("no structured output") }
        return try JSONDecoder().decode(ImportRoute.self, from: structured)
    }

    /// An action the app assistant proposes for the app to perform (after the user confirms).
    public struct AppAction: Codable, Sendable, Equatable {
        public var type: String   // start_meeting | open_project_memory | open_project_folder | export_project | rebuild_project_memory | resummarize_meeting | none
        public var project: String?
        public var meetingId: String?
        public var label: String?
        public init(type: String, project: String? = nil, meetingId: String? = nil, label: String? = nil) {
            self.type = type; self.project = project; self.meetingId = meetingId; self.label = label
        }
    }

    public struct AppAssistReply: Codable, Sendable, Equatable {
        public var answer: String
        public var action: AppAction?
        public init(answer: String, action: AppAction? = nil) { self.answer = answer; self.action = action }
    }

    /// The whole-app assistant: answers questions across every meeting and project ("what's
    /// happening", "what are my open tasks"), and may propose ONE action for the app to run after
    /// the user confirms.
    public func appAssistant(question: String, appDigest: String, history: ChatLog,
                             allowActions: Bool) async throws -> AppAssistReply {
        let historyText = history.messages.suffix(8).map {
            "\($0.role == "user" ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")

        let actionsDoc = allowActions ? """

        You may propose ONE action for the app to perform. Set "action" ONLY when the user is clearly \
        asking to DO something (not just to know something). The user confirms before it runs. \
        Available action types:
        - start_meeting: begin recording a new meeting.
        - open_project_memory: open a project's memory (set "project" to its name).
        - open_project_folder: reveal a project's folder in Finder (set "project").
        - export_project: export a copyable project bundle (set "project").
        - rebuild_project_memory: regenerate a project's working memory (set "project").
        - resummarize_meeting: regenerate a meeting's summary (set "meetingId" to its id from the digest).
        Always set "label" to a short description of what will happen. Omit "action" (or use type \
        "none") when the user only wants information.
        """ : ""

        let schema = """
        {"type":"object","properties":{
          "answer":{"type":"string"},
          "action":{"type":["object","null"],"properties":{
            "type":{"type":"string","enum":["start_meeting","open_project_memory","open_project_folder","export_project","rebuild_project_memory","resummarize_meeting","none"]},
            "project":{"type":["string","null"]},
            "meetingId":{"type":["string","null"]},
            "label":{"type":["string","null"]}
          },"required":["type","project","meetingId","label"],"additionalProperties":false}
        },"required":["answer","action"],"additionalProperties":false}
        """

        let prompt = """
        You are the SK Note Taker app assistant. You can see everything in the app (below). Answer \
        the user's question specifically, referencing meeting titles and dates. For "what are my \
        tasks" gather the task lines across meetings. Be concise.
        \(actionsDoc)

        APP CONTENTS:
        \(appDigest)

        \(historyText.isEmpty ? "" : "PREVIOUS:\n\(historyText)\n")
        QUESTION: \(question)
        """
        let output = try await run(prompt: prompt, jsonSchema: schema)
        guard let structured = output.structured else {
            throw CodexCLIError.badOutput("no structured output")
        }
        struct ActionPayload: Decodable {
            let type: String; let project: String?; let meetingId: String?; let label: String?
        }
        struct Payload: Decodable { let answer: String; let action: ActionPayload? }
        let p = try JSONDecoder().decode(Payload.self, from: structured)
        let action: AppAction? = {
            guard let a = p.action, a.type != "none" else { return nil }
            return AppAction(type: a.type, project: a.project, meetingId: a.meetingId, label: a.label)
        }()
        return AppAssistReply(answer: p.answer.trimmingCharacters(in: .whitespacesAndNewlines), action: action)
    }

    /// Chat with a whole project's memory (not a single meeting): answers using the living
    /// project.md, the details, and imported material, with optional web lookup.
    public func chatWithProject(question: String, projectName: String, projectMarkdown: String,
                                details: String, history: ChatLog, allowWeb: Bool) async throws -> String {
        let historyText = history.messages.suffix(10).map {
            "\($0.role == "user" ? "Q" : "A"): \($0.text)"
        }.joined(separator: "\n")
        let prompt = """
        You are the project assistant for "\(projectName)" inside SK Note Taker. Answer the user's \
        question using the project's memory and imported material below. Be concise and direct; give \
        exact wording when that helps. \
        \(allowWeb ? "If the answer needs external facts not in the memory, use web search." : "If the answer isn't in the memory, say so plainly.")

        \(CommunicationPlaybook.text)

        PROJECT MEMORY (project.md):
        \(projectMarkdown.isEmpty ? "(none yet)" : projectMarkdown)

        DETAILS & IMPORTED MATERIAL:
        \(details.isEmpty ? "(none)" : details)

        \(historyText.isEmpty ? "" : "PREVIOUS:\n\(historyText)\n")
        QUESTION: \(question)
        """
        let output = try await run(prompt: prompt, jsonSchema: nil, allowWeb: allowWeb)
        return output.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuild a project's living `project.md` from its details, imported material, and the digests
    /// of its meetings. Returns the markdown file content.
    public func buildProjectMarkdown(projectName: String, details: String,
                                     importsDigest: String, meetingsDigest: String) async throws -> String {
        let prompt = """
        You maintain the living working-memory file (project.md) for a project inside SK Note Taker. \
        Rebuild it from the details, imported material, and meeting history below. Output ONLY the \
        markdown file content, no preamble, no code fences.

        Use exactly these section headings (drop a section only if it would be truly empty):
        # \(projectName) — Working Memory
        ## People
        ## Platforms & tools
        ## Context
        ## Open tasks (mine)
        ## Decisions & outcomes
        ## Reusable answers & facts
        ## Glossary
        ## Meeting log

        Keep it compact and factual — it is read during live meetings for fast answers. Merge \
        duplicates, keep the most recent state, and date entries where the date is known. Under \
        "Open tasks (mine)" list what the user personally owes. Under "Reusable answers & facts" \
        capture recurring questions with their answers.

        DETAILS:
        \(details.isEmpty ? "(none)" : details)

        IMPORTED MATERIAL:
        \(importsDigest.isEmpty ? "(none)" : importsDigest)

        MEETINGS (most recent first):
        \(meetingsDigest.isEmpty ? "(none yet)" : meetingsDigest)
        """
        let output = try await run(prompt: prompt, jsonSchema: nil)
        return output.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Subprocess plumbing

    struct CLIOutput {
        let result: String
        let structured: Data?
    }

    public func isAvailable() async -> Bool {
        guard let binary = try? await binaryPath(),
              let (status, _, _) = try? await Self.exec(
                binary, ["login", "status"], stdin: nil, timeout: 15) else { return false }
        return status == 0
    }

    private func binaryPath() async throws -> String {
        if let resolvedBinary { return resolvedBinary }
        let (status, stdout, _) = try await Self.exec(
            "/bin/zsh", ["-lc", "command -v codex"], stdin: nil, timeout: 15)
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !path.isEmpty else { throw CodexCLIError.cliNotFound }
        resolvedBinary = path
        return path
    }

    private func run(prompt: String, jsonSchema: String?, allowWeb: Bool = false) async throws -> CLIOutput {
        let binary = try await binaryPath()
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("sk-note-taker-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let outputURL = workDir.appendingPathComponent("response.txt")
        var args = ["--ask-for-approval", "never"]
        if allowWeb { args.append("--search") }
        args += [
            "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
            "--ignore-user-config", "--ignore-rules", "--color", "never",
            "--cd", workDir.path, "--output-last-message", outputURL.path,
        ]

        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedModel.isEmpty { args += ["--model", selectedModel] }
        if let jsonSchema {
            let schemaURL = workDir.appendingPathComponent("schema.json")
            try Data(jsonSchema.utf8).write(to: schemaURL, options: .atomic)
            args += ["--output-schema", schemaURL.path]
        }
        args.append("-")
        let (status, stdout, stderr) = try await Self.exec(
            binary, args, stdin: prompt, timeout: 300)

        let haystack = (stderr + "\n" + stdout).lowercased()
        if haystack.contains("not logged in") || haystack.contains("codex login")
            || haystack.contains("authentication required") || haystack.contains("401 unauthorized") {
            throw CodexCLIError.notLoggedIn
        }
        guard status == 0 else {
            let detail = stderr.isEmpty ? String(stdout.prefix(500)) : String(stderr.prefix(500))
            throw CodexCLIError.cliFailed(
                detail.isEmpty ? "the CLI exited with code \(status) and no output" : detail)
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty,
              let result = String(data: data, encoding: .utf8) else {
            throw CodexCLIError.badOutput(String(stdout.prefix(300)))
        }
        return CLIOutput(result: result, structured: jsonSchema == nil ? nil : data)
    }

    private static func exec(_ launchPath: String, _ arguments: [String],
                             stdin: String?, timeout: TimeInterval)
        async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = arguments
                // Do not inherit the app's launch directory. Each Codex call separately points
                // itself at an empty, per-call temporary workspace.
                let cwd = MeetingStore.defaultDataDir()
                try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                proc.currentDirectoryURL = cwd
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                proc.standardInput = inPipe

                do { try proc.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                }
                try? inPipe.fileHandleForWriting.close()

                let deadline = DispatchWorkItem {
                    if proc.isRunning { proc.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                deadline.cancel()

                continuation.resume(returning: (
                    proc.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }
}

public enum CodexCLIError: Error, LocalizedError {
    case cliNotFound
    case notLoggedIn
    case cliFailed(String)
    case badOutput(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex CLI not found. Install it, then open Terminal and run “codex login”."
        case .notLoggedIn:
            "Codex isn't signed in. Open Terminal, run “codex login”, and sign in with your ChatGPT account. SK Note Taker uses that sign-in for its AI features."
        case .cliFailed(let detail): "Codex CLI failed: \(detail)"
        case .badOutput(let detail): "Unexpected Codex CLI output: \(detail)"
        case .emptyTranscript: "No transcript to work with yet."
        }
    }
}
