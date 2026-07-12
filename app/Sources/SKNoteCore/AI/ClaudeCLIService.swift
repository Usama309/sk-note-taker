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
        - summary_markdown: start with a one-paragraph TL;DR, then sections with headings \
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

    /// Categorize a meeting into client/project folders (existing folders preferred).
    public func categorize(meeting: Meeting, transcript: Transcript,
                           existingFolders: [Folder],
                           folderPath: @Sendable (UUID?) -> String) async throws -> AutoCategory {
        let rendered = transcript.rendered(with: meeting)
        guard !rendered.isEmpty else { throw ClaudeCLIError.emptyTranscript }

        let folderList = existingFolders
            .map { "- \($0.kind.rawValue): \(folderPath($0.id))" }
            .joined(separator: "\n")

        let schema = """
        {"type":"object","properties":{
          "client":{"type":["string","null"],"description":"Client/company name, or null"},
          "project":{"type":["string","null"],"description":"Project name, or null"},
          "confidence":{"type":"number","minimum":0,"maximum":1}
        },"required":["client","project","confidence"]}
        """

        let head = String(rendered.prefix(6000))
        let prompt = """
        Categorize this meeting into a client and project for folder organization.
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
        }
        let payload = try JSONDecoder().decode(Payload.self, from: structured)
        return AutoCategory(project: payload.project, client: payload.client,
                            confidence: payload.confidence)
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

    private func run(prompt: String, jsonSchema: String?) async throws -> CLIOutput {
        let binary = try await binaryPath()
        var args = [binary, "-p", "--output-format", "json", "--model", model,
                    "--setting-sources", "", "--strict-mcp-config"]
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
