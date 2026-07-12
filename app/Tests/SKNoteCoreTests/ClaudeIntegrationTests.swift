import Foundation
import Testing
@testable import SKNoteCore

/// Live tests against the Claude Code CLI (subscription auth). Enabled with SKNOTE_AI=1.
@Suite("Claude CLI integration",
       .enabled(if: ProcessInfo.processInfo.environment["SKNOTE_AI"] == "1"),
       .serialized)
struct ClaudeIntegrationTests {

    /// A realistic diarized fixture meeting: Saqib (S1), Kainat (S2), Rick (S3).
    private func fixtureMeeting() -> (Meeting, Transcript) {
        var meeting = Meeting(title: "Website launch sync")
        meeting.speakers = [
            "S1": SpeakerInfo(label: "Speaker 1", name: "Saqib", source: .mic),
            "S2": SpeakerInfo(label: "Speaker 2", name: "Kainat", source: .system),
            "S3": SpeakerInfo(label: "Speaker 3", name: "Rick", source: .system),
        ]
        let lines: [(String, Double, String)] = [
            ("S1", 2, "Alright, let's get started. Main topic today is the Acme Corp website launch."),
            ("S2", 8, "The homepage design is approved. I will deliver the final assets by Wednesday."),
            ("S3", 15, "Backend is ready. One concern: the payment gateway sandbox is still flaky."),
            ("S1", 24, "Okay — decision: we launch on the twentieth without the payment feature, it follows a week later."),
            ("S2", 33, "Noted. Also remember Acme's CEO wants the dark theme as default, he mentioned it twice."),
            ("S3", 41, "I'll set up monitoring dashboards before launch day."),
            ("S1", 47, "Great. Kainat, please also send the launch announcement draft to marketing by Friday."),
            ("S2", 54, "Will do, announcement draft to marketing by Friday."),
        ]
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(id: index, speaker: line.0,
                              source: line.0 == "S1" ? .mic : .system,
                              start: line.1, end: line.1 + 5, text: line.2)
        }
        return (meeting, Transcript(segments: segments))
    }

    @Test("Summary has action items, decisions, and things to remember",
          .timeLimit(.minutes(6)))
    func summarize() async throws {
        let ai = ClaudeCLIService(model: "sonnet")
        let (meeting, transcript) = fixtureMeeting()
        let summary = try await ai.summarize(
            meeting: meeting, transcript: transcript,
            notes: "- launch date\n- payment gateway risk")

        #expect(!summary.body.isEmpty)
        #expect(!summary.actionItems.isEmpty, "should extract action items")
        #expect(!summary.decisions.isEmpty, "should extract the launch decision")
        let allActions = summary.actionItems.map { "\($0.owner ?? "") \($0.text)" }
            .joined(separator: " ").lowercased()
        #expect(allActions.contains("kainat") || allActions.contains("marketing")
                || allActions.contains("assets"),
                "action items should reference the actual commitments: \(allActions)")
        let decisionsText = summary.decisions.joined(separator: " ").lowercased()
        #expect(decisionsText.contains("launch") || decisionsText.contains("payment")
                || decisionsText.contains("twentieth") || decisionsText.contains("20"),
                "decisions should cover the launch call: \(decisionsText)")
    }

    @Test("Q&A: 'What did Kainat say?' answers from her utterances",
          .timeLimit(.minutes(6)))
    func askAboutSpeaker() async throws {
        let ai = ClaudeCLIService(model: "sonnet")
        let (meeting, transcript) = fixtureMeeting()
        let answer = try await ai.answer(
            question: "What did Kainat commit to, and by when?",
            meeting: meeting, transcript: transcript, history: ChatLog())

        let lower = answer.lowercased()
        #expect(lower.contains("wednesday") || lower.contains("assets"),
                "should mention final assets by Wednesday: \(answer)")
        #expect(lower.contains("friday") || lower.contains("announcement"),
                "should mention announcement draft by Friday: \(answer)")
    }

    @Test("Auto-categorization proposes client/project", .timeLimit(.minutes(6)))
    func categorize() async throws {
        let ai = ClaudeCLIService(model: "sonnet")
        let (meeting, transcript) = fixtureMeeting()
        let existing = [Folder(name: "Acme Corp", kind: .client)]
        let category = try await ai.categorize(
            meeting: meeting, transcript: transcript, existingFolders: existing,
            folderPath: { _ in "Acme Corp" })

        #expect(category.confidence > 0.3)
        #expect(category.client?.lowercased().contains("acme") == true,
                "should match the existing Acme client folder: \(String(describing: category.client))")
    }
}
