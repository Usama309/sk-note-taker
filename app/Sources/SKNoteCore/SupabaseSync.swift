import Foundation

/// Mirrors the local store to Supabase (PostgREST + Storage) so the web app and MCP can read
/// meetings from anywhere. Best-effort and non-blocking: failures are logged and retried on the
/// next `syncAll()` (e.g. at launch), so recording never depends on connectivity.
public actor SupabaseSync {
    public struct Config: Sendable {
        public let url: URL
        public let anonKey: String
        public let recordingsBucket: String
        public init(url: URL, anonKey: String, recordingsBucket: String = "recordings") {
            self.url = url
            self.anonKey = anonKey
            self.recordingsBucket = recordingsBucket
        }
    }

    private let config: Config
    private let store: MeetingStore
    private let folderStore: FolderStore
    public private(set) var lastError: String?
    public private(set) var enabled: Bool

    public init(config: Config, store: MeetingStore, folderStore: FolderStore, enabled: Bool = true) {
        self.config = config
        self.store = store
        self.folderStore = folderStore
        self.enabled = enabled
    }

    public func setEnabled(_ on: Bool) { enabled = on }

    // MARK: - Public sync entry points (called after local saves)

    public func syncMeeting(_ id: UUID) async {
        guard enabled else { return }
        do {
            if let meeting = try await store.meeting(id: id) {
                try await upsertMeeting(meeting)
                if let transcript = try await store.transcript(for: id) {
                    try await replaceSegments(meetingId: id, segments: transcript.segments)
                }
                if let summary = await store.summary(for: id) {
                    try await upsertSummary(meetingId: id, summary: summary)
                }
                try await replaceChat(meetingId: id, chat: await store.chat(for: id))
            }
        } catch {
            lastError = error.localizedDescription
            SKLog.error(.syncFailed, .sync, "Cloud sync of a meeting failed (local copy unaffected)", error: error)
        }
    }

    public func syncFolders() async {
        guard enabled else { return }
        do { try await upsertFolders(await folderStore.all()) }
        catch {
            lastError = error.localizedDescription
            SKLog.error(.syncFailed, .sync, "Cloud sync of folders failed (local copy unaffected)", error: error)
        }
    }

    public func deleteMeeting(_ id: UUID) async {
        guard enabled else { return }
        // Segments/summary/chat cascade via FK ON DELETE CASCADE.
        try? await delete(path: "meetings", query: "id=eq.\(id.uuidString.lowercased())")
        // Best-effort remove the audio object too.
        let url = config.url.appendingPathComponent(
            "storage/v1/object/\(config.recordingsBucket)/\(id.uuidString.lowercased()).m4a")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    public func uploadRecording(_ id: UUID) async {
        guard enabled else { return }
        let url = await store.recordingURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        do { try await putStorage(path: "\(id.uuidString.lowercased()).m4a", data: data, contentType: "audio/mp4") }
        catch {
            SKLog.error(.syncFailed, .sync, "Recording upload failed (local recording unaffected)", error: error)
        }
    }

    /// Push everything (catch-up sync). Call at launch and after reconnecting.
    @discardableResult
    public func syncAll() async -> Bool {
        guard enabled else { return false }
        await syncFolders()
        var ok = true
        for meeting in await store.allMeetings() {
            await syncMeeting(meeting.id)
            if meeting.hasRecording { await uploadRecording(meeting.id) }
        }
        if lastError != nil { ok = false }
        return ok
    }

    /// Quick reachability check.
    public func ping() async -> Bool {
        var req = request(path: "meetings", query: "select=id&limit=1")
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - PostgREST upserts

    private func upsertMeeting(_ m: Meeting) async throws {
        let body: [String: Any?] = [
            "id": m.id.uuidString.lowercased(),
            "title": m.title,
            "created_at": iso(m.createdAt),
            "ended_at": m.endedAt.map(iso),
            "folder_id": m.folderId?.uuidString.lowercased(),
            "state": m.state.rawValue,
            "speakers": encodeJSON(m.speakers),
            "has_recording": m.hasRecording,
            "duration_sec": m.durationSec,
            "auto_category": m.autoCategory.map { encodeJSON($0) } ?? NSNull(),
            "notes": await store.notes(for: m.id),
        ]
        try await postUpsert(path: "meetings", body: [body.compactMapValues { $0 }])
    }

    private func replaceSegments(meetingId: UUID, segments: [TranscriptSegment]) async throws {
        try await delete(path: "transcript_segments", query: "meeting_id=eq.\(meetingId.uuidString.lowercased())")
        guard !segments.isEmpty else { return }
        let rows = segments.map { seg -> [String: Any] in
            ["meeting_id": meetingId.uuidString.lowercased(), "idx": seg.id, "speaker": seg.speaker,
             "source": seg.source.rawValue, "start_sec": seg.start, "end_sec": seg.end, "text": seg.text]
        }
        try await postUpsert(path: "transcript_segments", body: rows)
    }

    private func upsertSummary(meetingId: UUID, summary: SummaryData) async throws {
        let body: [String: Any] = [
            "meeting_id": meetingId.uuidString.lowercased(),
            "generated_at": iso(summary.generatedAt),
            "body": summary.body,
            "action_items": summary.actionItems.map { ["owner": $0.owner as Any, "text": $0.text] },
            "decisions": summary.decisions,
            "remember": summary.remember,
        ]
        try await postUpsert(path: "summaries", body: [body])
    }

    private func replaceChat(meetingId: UUID, chat: ChatLog) async throws {
        try await delete(path: "chat_messages", query: "meeting_id=eq.\(meetingId.uuidString.lowercased())")
        guard !chat.messages.isEmpty else { return }
        let rows = chat.messages.map { msg -> [String: Any] in
            ["meeting_id": meetingId.uuidString.lowercased(), "role": msg.role, "text": msg.text, "at": iso(msg.at)]
        }
        try await postUpsert(path: "chat_messages", body: rows)
    }

    private func upsertFolders(_ folders: [Folder]) async throws {
        guard !folders.isEmpty else { return }
        let rows = folders.map { f -> [String: Any] in
            ["id": f.id.uuidString.lowercased(), "name": f.name, "kind": f.kind.rawValue,
             "parent_id": f.parentId?.uuidString.lowercased() as Any]
        }
        try await postUpsert(path: "folders", body: rows)
    }

    // MARK: - HTTP helpers

    private func request(path: String, query: String? = nil) -> URLRequest {
        var comps = URLComponents(url: config.url.appendingPathComponent("rest/v1/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if let query { comps.query = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func postUpsert(path: String, body: [[String: Any]]) async throws {
        var req = request(path: path)
        req.httpMethod = "POST"
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await send(req)
    }

    private func delete(path: String, query: String) async throws {
        var req = request(path: path, query: query)
        req.httpMethod = "DELETE"
        try await send(req)
    }

    private func putStorage(path: String, data: Data, contentType: String) async throws {
        let url = config.url.appendingPathComponent("storage/v1/object/\(config.recordingsBucket)/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.httpBody = data
        try await send(req)
    }

    private func send(_ req: URLRequest) async throws {
        let (data, resp) = try await URLSession.shared.upload(
            for: req, from: req.httpBody ?? Data())
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Encoding

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> Any {
        guard let data = try? SKJSON.encoder.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return obj
    }
}

public extension SupabaseSync.Config {
    /// The SK Note Taker project's Supabase config. The anon key is publishable (client-safe).
    static let sknote = SupabaseSync.Config(
        url: URL(string: "https://ntuamvphoorqbuikbhdb.supabase.co")!,
        anonKey: "sb_publishable_hQfcPxlg1Y13bdNFu72olA_yPArtdgF")
}

public enum SyncError: Error, LocalizedError {
    case badResponse
    case http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .badResponse: "Bad response from Supabase"
        case .http(let code, let body): "Supabase HTTP \(code): \(body.prefix(200))"
        }
    }
}
