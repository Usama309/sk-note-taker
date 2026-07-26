import Foundation

/// All AI features via the Claude Code CLI (`claude -p`) — uses the developer's Claude
/// subscription (keychain OAuth), never an API key.
public actor ClaudeCLIService {
    public var model: String
    private var resolvedBinary: String?

    public init(model: String = "sonnet") {
        self.model = model
    }

    // MARK: - Public features

    /// Granola-style "enhanced notes": intelligent summary with action items, decisions,
    /// and things to remember. User notes act as anchors/priority signals.
    public func summarize(meeting: Meeting, transcript: Transcript,
                          notes: String) async throws -> SummaryData {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw ClaudeCLIError.emptyTranscript }

        let schema = """
        {"type":"object","properties":{
          "summary_markdown":{"type":"string","description":"Well-structured markdown summary of the meeting"},
          "action_items":{"type":"array","items":{"type":"object","properties":{
            "owner":{"type":["string","null"]},"text":{"type":"string"}},"required":["text"]}},
          "decisions":{"type":"array","items":{"type":"string"}},
          "things_to_remember":{"type":"array","items":{"type":"string"}}
        },"required":["summary_markdown","action_items","decisions","things_to_remember"]}
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
            throw ClaudeCLIError.badOutput("no structured output")
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
        guard !rendered.isEmpty else { throw ClaudeCLIError.emptyTranscript }

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
        guard !rendered.isEmpty else { throw ClaudeCLIError.emptyTranscript }
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
        // Mid-call latency matters more than depth here: use the fast model.
        let output = try await run(prompt: prompt, jsonSchema: nil, modelOverride: "haiku")
        return output.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Categorize a meeting into client/project folders (existing folders preferred), and
    /// propose a concise human title to replace the default timestamp one.
    public func categorize(meeting: Meeting, transcript: Transcript,
                           existingFolders: [Folder],
                           folderPath: @Sendable (UUID?) -> String) async throws
        -> (category: AutoCategory, title: String?) {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw ClaudeCLIError.emptyTranscript }

        let folderList = existingFolders
            .map { "- \($0.kind.rawValue): \(folderPath($0.id))" }
            .joined(separator: "\n")

        let schema = """
        {"type":"object","properties":{
          "client":{"type":["string","null"],"description":"Client/company name, or null"},
          "project":{"type":["string","null"],"description":"Project name, or null"},
          "confidence":{"type":"number","minimum":0,"maximum":1},
          "title":{"type":["string","null"],"description":"Concise meeting title, max 6 words, no dates, or null if the transcript gives no signal"}
        },"required":["client","project","confidence","title"]}
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
            throw ClaudeCLIError.badOutput("no structured output")
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
        },"required":["say","source"]}
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
        // With web allowed the model may reason + look up (use the stronger default model); pure
        // memory answers stay on the fast model.
        let output = try await run(prompt: prompt, jsonSchema: schema,
                                   modelOverride: allowWeb ? nil : "haiku",
                                   allowTools: allowWeb ? ["WebSearch", "WebFetch"] : [])
        guard let structured = output.structured else {
            throw ClaudeCLIError.badOutput("no structured output")
        }
        struct Payload: Decodable { let say: String; let notes: [String]?; let source: String? }
        let p = try JSONDecoder().decode(Payload.self, from: structured)
        return AssistAnswer(say: p.say.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: p.notes ?? [], source: p.source ?? "memory")
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
          },"required":["type"]}
        },"required":["answer"]}
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
        let output = try await run(prompt: prompt, jsonSchema: schema,
                                   modelOverride: allowActions ? nil : "haiku")
        guard let structured = output.structured else {
            throw ClaudeCLIError.badOutput("no structured output")
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
        let output = try await run(prompt: prompt, jsonSchema: nil,
                                   modelOverride: allowWeb ? nil : "haiku",
                                   allowTools: allowWeb ? ["WebSearch", "WebFetch"] : [])
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
        (try? await binaryPath()) != nil
    }

    private func binaryPath() async throws -> String {
        if let resolvedBinary { return resolvedBinary }
        let (status, stdout, _) = try await Self.exec(
            "/bin/zsh", ["-lc", "command -v claude"], stdin: nil, timeout: 15)
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !path.isEmpty else { throw ClaudeCLIError.cliNotFound }
        resolvedBinary = path
        return path
    }

    private func run(prompt: String, jsonSchema: String?,
                     modelOverride: String? = nil, allowTools: [String] = []) async throws -> CLIOutput {
        let binary = try await binaryPath()
        var args = [binary, "-p", "--output-format", "json", "--model", modelOverride ?? model,
                    "--setting-sources", "", "--strict-mcp-config"]
        if !allowTools.isEmpty {
            args += ["--allowedTools", allowTools.joined(separator: ",")]
        }
        if let jsonSchema {
            args += ["--json-schema", jsonSchema]
        }
        let command = args.map { Self.shellQuote($0) }.joined(separator: " ")
        let (status, stdout, stderr) = try await Self.exec(
            "/bin/zsh", ["-lc", command], stdin: prompt, timeout: 300)
        guard status == 0 else {
            throw ClaudeCLIError.cliFailed(String(stderr.prefix(500)))
        }
        guard let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCLIError.badOutput(String(stdout.prefix(300)))
        }
        if let isError = json["is_error"] as? Bool, isError {
            throw ClaudeCLIError.cliFailed(String((json["result"] as? String ?? "").prefix(500)))
        }
        let result = json["result"] as? String ?? ""
        var structured: Data?
        if let so = json["structured_output"] {
            structured = try? JSONSerialization.data(withJSONObject: so)
        }
        return CLIOutput(result: result, structured: structured)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func exec(_ launchPath: String, _ arguments: [String],
                             stdin: String?, timeout: TimeInterval)
        async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = arguments
                // Pin the CLI's cwd to our data dir — inheriting the app's cwd makes the
                // CLI scan whatever folder that is (Desktop prompts, stray project files).
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

public enum ClaudeCLIError: Error, LocalizedError {
    case cliNotFound
    case cliFailed(String)
    case badOutput(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Claude Code CLI not found. Install it and sign in (https://claude.com/claude-code)."
        case .cliFailed(let detail): "Claude CLI failed: \(detail)"
        case .badOutput(let detail): "Unexpected Claude CLI output: \(detail)"
        case .emptyTranscript: "No transcript to work with yet."
        }
    }
}
