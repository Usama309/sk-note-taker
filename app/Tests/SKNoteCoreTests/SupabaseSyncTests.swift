import Foundation
import Testing
@testable import SKNoteCore

/// Live Supabase sync test. Enabled with SKNOTE_SUPABASE=1. Creates a uniquely-titled meeting,
/// syncs it, verifies via the REST API, then deletes it — never touches real data.
@Suite("Supabase sync",
       .enabled(if: ProcessInfo.processInfo.environment["SKNOTE_SUPABASE"] == "1"),
       .serialized)
struct SupabaseSyncTests {
    let config = SupabaseSync.Config.sknote

    private func tempDataDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sknote-sb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rest(_ path: String, method: String = "GET", query: String? = nil) async throws -> (Int, Data) {
        var comps = URLComponents(url: config.url.appendingPathComponent("rest/v1/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if let query { comps.query = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test("Meeting + transcript + summary + chat round-trip to Supabase", .timeLimit(.minutes(3)))
    func syncRoundTrip() async throws {
        let dir = tempDataDir()
        let store = MeetingStore(dataDir: dir)
        let folderStore = FolderStore(dataDir: dir)
        let sync = SupabaseSync(config: config, store: store, folderStore: folderStore)

        #expect(await sync.ping(), "Supabase must be reachable")

        let marker = "__synctest__\(UUID().uuidString.prefix(8))"
        var meeting = Meeting(title: marker, state: .complete, durationSec: 42)
        meeting.speakers = [
            "S1": SpeakerInfo(label: "Speaker 1", name: "Saqib", source: .mic),
            "S2": SpeakerInfo(label: "Speaker 2", name: "Kainat", source: .system),
        ]
        try await store.save(meeting)
        try await store.save(Transcript(segments: [
            TranscriptSegment(id: 0, speaker: "S1", source: .mic, start: 0, end: 2, text: "Hello."),
            TranscriptSegment(id: 1, speaker: "S2", source: .system, start: 2, end: 5, text: "Hi Saqib."),
        ]), for: meeting.id)
        try await store.saveSummary(SummaryData(
            actionItems: [.init(owner: "Kainat", text: "Send proposal")],
            decisions: ["Ship Friday"], remember: ["Weekly check-ins"],
            body: "# Summary\nGood meeting."), for: meeting.id)
        var chat = ChatLog()
        chat.messages.append(ChatMessage(role: "user", text: "What did Kainat say?"))
        chat.messages.append(ChatMessage(role: "assistant", text: "Hi Saqib."))
        try await store.saveChat(chat, for: meeting.id)

        let meetingId = meeting.id
        await sync.syncMeeting(meetingId)

        // Verify meeting row.
        let idq = "id=eq.\(meeting.id.uuidString.lowercased())"
        let (mCode, mData) = try await rest("meetings", query: "select=*&\(idq)")
        #expect(mCode == 200)
        let rows = try JSONSerialization.jsonObject(with: mData) as? [[String: Any]] ?? []
        let row = try #require(rows.first)
        #expect(row["title"] as? String == marker)
        #expect((row["duration_sec"] as? Double) == 42)
        let speakers = row["speakers"] as? [String: Any]
        #expect(((speakers?["S2"] as? [String: Any])?["name"] as? String) == "Kainat")

        // Verify segments.
        let (sCode, sData) = try await rest("transcript_segments",
            query: "select=text&meeting_id=eq.\(meeting.id.uuidString.lowercased())&order=idx")
        #expect(sCode == 200)
        let segs = try JSONSerialization.jsonObject(with: sData) as? [[String: Any]] ?? []
        #expect(segs.count == 2)
        #expect(segs.last?["text"] as? String == "Hi Saqib.")

        // Verify summary.
        let (sumCode, sumData) = try await rest("summaries",
            query: "select=body,decisions&meeting_id=eq.\(meeting.id.uuidString.lowercased())")
        #expect(sumCode == 200)
        let sums = try JSONSerialization.jsonObject(with: sumData) as? [[String: Any]] ?? []
        #expect((sums.first?["decisions"] as? [String])?.first == "Ship Friday")

        // Verify chat.
        let (cCode, cData) = try await rest("chat_messages",
            query: "select=role,text&meeting_id=eq.\(meeting.id.uuidString.lowercased())&order=at")
        #expect(cCode == 200)
        let msgs = try JSONSerialization.jsonObject(with: cData) as? [[String: Any]] ?? []
        #expect(msgs.count == 2)

        // Cleanup + verify deletion.
        await sync.deleteMeeting(meeting.id)
        let (dCode, dData) = try await rest("meetings", query: "select=id&\(idq)")
        let after = try JSONSerialization.jsonObject(with: dData) as? [[String: Any]] ?? []
        #expect(dCode == 200 && after.isEmpty, "meeting should be deleted from Supabase")
    }
}
