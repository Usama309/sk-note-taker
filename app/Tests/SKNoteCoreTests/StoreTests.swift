import Foundation
import Testing
@testable import SKNoteCore

private func tempDataDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sknote-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MeetingStore")
struct MeetingStoreTests {
    @Test func saveAndLoadMeetingRoundTrip() async throws {
        let store = MeetingStore(dataDir: tempDataDir())
        var meeting = Meeting(title: "Weekly sync")
        meeting.speakers = [
            "S1": SpeakerInfo(label: "Speaker 1", name: "Saqib", source: .mic),
            "S2": SpeakerInfo(label: "Speaker 2", source: .system),
        ]
        try await store.save(meeting)

        let loaded = try #require(try await store.meeting(id: meeting.id))
        #expect(loaded.id == meeting.id)
        #expect(loaded.title == meeting.title)
        #expect(loaded.speakers == meeting.speakers)
        #expect(loaded.state == meeting.state)
        // Dates round-trip at millisecond precision through ISO8601.
        #expect(abs(loaded.createdAt.timeIntervalSince(meeting.createdAt)) < 0.001)
        #expect(loaded.displayName(forSpeakerKey: "S1") == "Saqib")
        #expect(loaded.displayName(forSpeakerKey: "S2") == "Speaker 2")
    }

    @Test func speakerRenameIsMetadataOnly() async throws {
        let store = MeetingStore(dataDir: tempDataDir())
        var meeting = Meeting(title: "Client call")
        meeting.speakers = ["S2": SpeakerInfo(label: "Speaker 2", source: .system)]
        try await store.save(meeting)

        let transcript = Transcript(segments: [
            TranscriptSegment(id: 0, speaker: "S2", source: .system,
                              start: 1.0, end: 3.0, text: "Hello from the client side."),
        ])
        try await store.save(transcript, for: meeting.id)

        // Rename S2 -> Kainat: only meeting.json changes.
        meeting.speakers["S2"]?.name = "Kainat"
        try await store.save(meeting)

        let loadedMeeting = try #require(try await store.meeting(id: meeting.id))
        let loadedTranscript = try #require(try await store.transcript(for: meeting.id))
        #expect(loadedTranscript.segments[0].speaker == "S2") // untouched key
        let rendered = loadedTranscript.rendered(with: loadedMeeting)
        #expect(rendered.contains("Kainat: Hello from the client side."))
    }

    @Test func allMeetingsSortedNewestFirstAndSkipsMalformed() async throws {
        let dir = tempDataDir()
        let store = MeetingStore(dataDir: dir)
        let older = Meeting(title: "Old", createdAt: Date(timeIntervalSinceNow: -3600))
        let newer = Meeting(title: "New")
        try await store.save(older)
        try await store.save(newer)

        // Malformed entry should be skipped, not crash.
        let badDir = dir.appendingPathComponent("meetings/not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: badDir.appendingPathComponent("meeting.json"))

        let all = await store.allMeetings()
        #expect(all.map(\.title) == ["New", "Old"])
    }

    @Test func summaryFrontMatterRoundTrip() async throws {
        let store = MeetingStore(dataDir: tempDataDir())
        let id = UUID()
        let summary = SummaryData(
            actionItems: [
                .init(owner: "Kainat", text: "Send the revised proposal by Friday"),
                .init(owner: nil, text: "Book the follow-up: \"kickoff\" meeting"),
            ],
            decisions: ["Ship v1 without SSO"],
            remember: ["Client prefers Friday check-ins"],
            body: "# Meeting Summary\n\nWe discussed the launch plan.")
        try await store.saveSummary(summary, for: id)

        let loaded = try #require(await store.summary(for: id))
        #expect(loaded.actionItems.count == 2)
        #expect(loaded.actionItems[0].owner == "Kainat")
        #expect(loaded.actionItems[1].owner == nil)
        #expect(loaded.actionItems[1].text == "Book the follow-up: \"kickoff\" meeting")
        #expect(loaded.decisions == summary.decisions)
        #expect(loaded.remember == summary.remember)
        #expect(loaded.body == summary.body)
    }

    @Test func chatRoundTrip() async throws {
        let store = MeetingStore(dataDir: tempDataDir())
        let id = UUID()
        var chat = ChatLog()
        chat.messages.append(ChatMessage(role: "user", text: "What did Kainat say?"))
        chat.messages.append(ChatMessage(role: "assistant", text: "She confirmed the deadline."))
        try await store.saveChat(chat, for: id)
        let loaded = await store.chat(for: id)
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[0].text == "What did Kainat say?")
    }
}

@Suite("FolderStore")
struct FolderStoreTests {
    @Test func resolveOrCreateBuildsClientProjectHierarchy() async throws {
        let store = FolderStore(dataDir: tempDataDir())
        let projectId = try await store.resolveOrCreate(client: "Acme Corp", project: "Website Redesign")
        let folders = await store.all()
        #expect(folders.count == 2)

        let client = try #require(folders.first { $0.kind == .client })
        let project = try #require(folders.first { $0.kind == .project })
        #expect(project.parentId == client.id)
        #expect(project.id == projectId)
        #expect(await store.path(for: projectId) == "Acme Corp / Website Redesign")

        // Idempotent: same names resolve to the same folder (case-insensitive).
        let again = try await store.resolveOrCreate(client: "acme corp", project: "website redesign")
        #expect(again == projectId)
        #expect(await store.all().count == 2)
    }

    @Test func removeCascadesToChildren() async throws {
        let store = FolderStore(dataDir: tempDataDir())
        let projectId = try #require(try await store.resolveOrCreate(client: "Acme", project: "App"))
        let clientId = try #require(await store.all().first { $0.kind == .client }?.id)
        _ = projectId
        try await store.remove(id: clientId)
        #expect(await store.all().isEmpty)
    }
}

@Suite("TranscriptAssembler")
struct TranscriptAssemblerTests {
    @Test func micTokensAreAlwaysS1AndSystemTokensFollowDiarizer() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "Hi everyone", start: 0.0, end: 1.0,
                                isFinal: true, tokens: [("Hi everyone", 0.0, 1.0)]),
            TranscriptionResult(channel: .system, text: "Hello Saqib", start: 1.5, end: 2.5,
                                isFinal: true, tokens: [("Hello Saqib", 1.5, 2.5)]),
            TranscriptionResult(channel: .system, text: "Good morning", start: 3.5, end: 4.5,
                                isFinal: true, tokens: [("Good morning", 3.5, 4.5)]),
        ]
        let diarized = [
            SpeakerSegment(speakerId: "A", start: 1.0, end: 3.0),
            SpeakerSegment(speakerId: "B", start: 3.2, end: 5.0),
        ]
        let (segments, speakers) = assembler.assemble(finals: finals, speakerSegments: diarized)

        #expect(segments.count == 3)
        #expect(segments[0].speaker == "S1")
        #expect(segments[1].speaker == "S2") // diarizer "A" seen first -> S2
        #expect(segments[2].speaker == "S3")
        #expect(speakers["S1"]?.source == .mic)
        #expect(speakers["S2"]?.source == .system)
        #expect(speakers["S3"]?.label == "Speaker 3")
    }

    @Test func consecutiveSameSpeakerTokensCoalesce() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("Let's review", 0.0, 0.8),
                                         ("the launch checklist", 0.9, 1.8),
                                         (".", 1.8, 1.85)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 0.0, end: 2.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Let's review the launch checklist.")
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 1.85)
    }

    @Test func longGapSplitsUtterancesEvenForSameSpeaker() {
        let assembler = TranscriptAssembler(maxUtteranceGap: 1.5)
        let finals = [
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("First thought", 0.0, 1.0),
                                         ("second thought", 5.0, 6.0)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 0.0, end: 7.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.count == 2)
    }

    @Test func tokensOutsideDiarizerSegmentsSnapToNearest() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .system, text: "Trailing words", start: 10.0, end: 11.0,
                                isFinal: true, tokens: [("Trailing words", 10.0, 11.0)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "B", start: 2.0, end: 9.5)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.count == 1)
        #expect(segments[0].speaker == "S2")
    }

    @Test func micEchoOfSystemAudioIsSuppressed() {
        // Laptop-speaker echo: the remote voice (system) is also picked up by the mic at the
        // same time. The mic copy must be dropped so it's not duplicated as S1.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("Hello", 1.0, 1.5), ("everyone", 1.6, 2.2)]),
            // Mic hears the same words (slightly offset) — this is echo.
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("Hello", 1.1, 1.6), ("everyone", 1.7, 2.3)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 0.5, end: 3.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.allSatisfy { $0.source == .system },
                "mic echo of system audio should be dropped, got: \(segments.map { "\($0.speaker):\($0.text)" })")
        #expect(segments.count == 1, "remaining system tokens should coalesce into one utterance")
        #expect(segments.first?.text == "Hello everyone")
    }

    @Test func localMicSpeechIsKeptWhenSystemIsQuiet() {
        // The user speaks (mic) while nobody remote is talking — must NOT be suppressed.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("My", 1.0, 1.2), ("turn", 1.3, 1.8)]),
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("Later reply", 5.0, 5.8)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 4.5, end: 6.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.contains { $0.speaker == "S1" && $0.text == "My turn" })
        #expect(segments.contains { $0.source == .system })
    }

    @Test func volatileResultsAreIgnored() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "not yet final", start: 0, end: 1,
                                isFinal: false, tokens: [("not yet final", 0, 1)]),
        ]
        let (segments, speakers) = assembler.assemble(finals: finals, speakerSegments: [])
        #expect(segments.isEmpty)
        #expect(speakers.isEmpty)
    }

    @Test func leadingEchoFragmentWithTimestampSkewIsSuppressed() {
        // The Patriot-meeting bug at 24:43: the mic hears the first word of the remote
        // speaker's sentence slightly BEFORE the system channel's ASR timestamps it, so
        // there's no time overlap — but the same word on both channels moments apart is
        // still echo and must not become a phantom S1 line.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("hold", 10.00, 10.30)]),
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("hold on a second", 10.35, 11.6)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 10.0, end: 12.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.allSatisfy { $0.source == .system },
                "skewed leading echo must be dropped, got: \(segments.map { "\($0.speaker):\($0.text)" })")
    }

    @Test func subArticulationBlipDuringRemoteSpeechIsSuppressed() {
        // Faint echo the system ASR never transcribed ("go?" at 24:32): a <0.2s mic token
        // is not an articulable word — drop it whenever the remote channel is active nearby.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("go", 9.95, 10.05)]),
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("But there you are", 10.6, 12.0)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 10.0, end: 12.5)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.allSatisfy { $0.source == .system },
                "sub-articulation blip must be dropped, got: \(segments.map { "\($0.speaker):\($0.text)" })")
    }

    @Test func leadingShortWordOfARealSentenceIsKept() {
        // FSL Blueprint call (17 Jul): the user said "How you're supposed to improve your
        // English without even practicing it?" 0.4s after the remote speaker stopped. The
        // sub-0.2s leading "How" was being dropped as an echo blip, so the saved line began
        // "you're supposed to…". It is not isolated — real mic speech follows it — so it
        // must survive.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("How", 12.05, 12.20), ("you're supposed to improve", 12.20, 13.6)]),
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("My gosh, sorry", 9.0, 11.7)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 9.0, end: 11.7)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        let micText = segments.filter { $0.source == .mic }.map(\.text).joined(separator: " ")
        #expect(micText.contains("How"),
                "leading short word of a real sentence must survive, got: \(micText)")
    }

    @Test func realInterjectionDuringRemoteSpeechIsKept() {
        // A genuine "Got it." from the user mid-remote-speech: proper word duration and
        // different words than the remote channel — must survive all three echo rules.
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("Got it", 10.0, 11.2)]),
            TranscriptionResult(channel: .system, text: "", start: 0, end: 0, isFinal: true,
                                tokens: [("and the numbers keep improving", 8.0, 9.9),
                                         ("so the plan stays", 11.5, 13.0)]),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 8.0, end: 13.0)]
        let (segments, _) = assembler.assemble(finals: finals, speakerSegments: diarized)
        #expect(segments.contains { $0.speaker == "S1" && $0.text == "Got it" },
                "real interjections must be preserved, got: \(segments.map { "\($0.speaker):\($0.text)" })")
    }
}
