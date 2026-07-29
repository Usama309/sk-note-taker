import Foundation
import Testing
@testable import SKNoteCore

@Suite("Speaker name track")
struct SpeakerNameTrackTests {
    @Test("a change of active speaker closes one span and opens the next")
    func spansOnChange() {
        let track = SpeakerNameTrack()
        track.record(name: "Alice", at: 0)
        track.record(name: "Bob", at: 5)
        let spans = track.snapshot(now: 10)
        #expect(spans.count == 2)
        #expect(spans[0] == NameSpan(name: "Alice", start: 0, end: 5))
        #expect(spans[1] == NameSpan(name: "Bob", start: 5, end: 10))
    }

    @Test("the same active speaker repeated stays one extending span")
    func sameNameExtends() {
        let track = SpeakerNameTrack()
        track.record(name: "Alice", at: 0)
        track.record(name: "Alice", at: 3)
        track.record(name: "Alice", at: 6)
        let spans = track.snapshot(now: 8)
        #expect(spans == [NameSpan(name: "Alice", start: 0, end: 8)])
    }

    @Test("clearActive closes the open span")
    func clearCloses() {
        let track = SpeakerNameTrack()
        track.record(name: "Alice", at: 0)
        track.clearActive(at: 5)
        let spans = track.snapshot(now: 9)
        #expect(spans == [NameSpan(name: "Alice", start: 0, end: 5)])
    }

    @Test("blank names are ignored")
    func blankIgnored() {
        let track = SpeakerNameTrack()
        track.record(name: "", at: 0)
        track.record(name: "   ", at: 1)
        #expect(track.isEmpty)
    }
}

@Suite("TranscriptAssembler with names")
struct TranscriptAssemblerNameTests {
    private func systemResult(_ text: String, _ start: Double, _ end: Double) -> TranscriptionResult {
        TranscriptionResult(channel: .system, text: text, start: start, end: end,
                            isFinal: true, tokens: [(text, start, end)])
    }

    @Test("the dominant participant name labels its diarizer cluster")
    func namesCluster() {
        let assembler = TranscriptAssembler()
        let finals = [systemResult("hello there everyone", 1.0, 5.0)]
        let diarized = [SpeakerSegment(speakerId: "A", start: 1.0, end: 5.0)]
        let spans = [NameSpan(name: "Alice", start: 1.0, end: 5.0)]

        let (_, speakers) = assembler.assemble(
            finals: finals, speakerSegments: diarized, nameSpans: spans)

        #expect(speakers["S2"]?.name == "Alice")
        #expect(speakers["S2"]?.displayName == "Alice")
        #expect(speakers["S2"]?.source == .system)
    }

    @Test("two speakers get their two names")
    func twoNames() {
        let assembler = TranscriptAssembler()
        let finals = [
            systemResult("first part", 1.0, 3.0),
            systemResult("second part", 3.2, 5.0),
        ]
        let diarized = [
            SpeakerSegment(speakerId: "A", start: 1.0, end: 3.0),
            SpeakerSegment(speakerId: "B", start: 3.2, end: 5.0),
        ]
        let spans = [
            NameSpan(name: "Alice", start: 1.0, end: 3.0),
            NameSpan(name: "Bob", start: 3.2, end: 5.0),
        ]
        let (_, speakers) = assembler.assemble(
            finals: finals, speakerSegments: diarized, nameSpans: spans)

        #expect(speakers["S2"]?.name == "Alice")
        #expect(speakers["S3"]?.name == "Bob")
    }

    @Test("over-split diarizer clusters collapse to one speaker when the app names them")
    func overSplitCollapses() {
        let assembler = TranscriptAssembler()
        // One remote person, but the voice-pitch diarizer over-split into A and B.
        let finals = [
            systemResult("part one", 1.0, 3.0),
            systemResult("part two", 3.2, 5.0),
        ]
        let diarized = [
            SpeakerSegment(speakerId: "A", start: 1.0, end: 3.0),
            SpeakerSegment(speakerId: "B", start: 3.2, end: 5.0),
        ]
        // The meeting app said it was Sameel the whole time.
        let spans = [NameSpan(name: "Sameel", start: 1.0, end: 5.0)]

        let (segments, speakers) = assembler.assemble(
            finals: finals, speakerSegments: diarized, nameSpans: spans)

        let systemSpeakers = speakers.filter { $0.value.source == .system }
        #expect(systemSpeakers.count == 1)                       // over-split is gone
        #expect(systemSpeakers.first?.value.name == "Sameel")
        #expect(Set(segments.filter { $0.source == .system }.map(\.speaker)).count == 1)
    }

    @Test("a system token during the user's spotlight (lag) is attributed to the remote, not the user")
    func lagAttributedToRemote() {
        let assembler = TranscriptAssembler()
        // The remote (Sameel) is on the system audio at t=6, but Zoom's spotlight lagged onto the
        // user's tile. The system channel is never the user, so this must resolve to Sameel.
        let finals = [systemResult("the remote line", 5.0, 7.0)]
        let diarized = [SpeakerSegment(speakerId: "A", start: 5.0, end: 7.0)]
        let spans = [
            NameSpan(name: "Sameel", start: 0.0, end: 4.0),
            NameSpan(name: "Muhammad Usama", start: 4.0, end: 8.0),
        ]
        let (segments, speakers) = assembler.assemble(
            finals: finals, speakerSegments: diarized, nameSpans: spans, userName: "Usama")

        let sys = speakers.filter { $0.value.source == .system }
        #expect(sys.count == 1)
        #expect(sys.first?.value.name == "Sameel")
        #expect(segments.contains { $0.source == .system && speakers[$0.speaker]?.name == "Sameel" })
    }

    @Test("no name spans leaves the diarize-only behaviour unchanged")
    func emptySpansUnchanged() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "my words", start: 0.0, end: 1.0,
                                isFinal: true, tokens: [("my words", 0.0, 1.0)]),
            systemResult("their words", 1.5, 2.5),
        ]
        let diarized = [SpeakerSegment(speakerId: "A", start: 1.0, end: 3.0)]

        let (_, speakers) = assembler.assemble(
            finals: finals, speakerSegments: diarized, nameSpans: [])

        #expect(speakers["S1"]?.name == nil)
        #expect(speakers["S1"]?.source == .mic)
        #expect(speakers["S2"]?.name == nil)
        #expect(speakers["S2"]?.label == "Speaker 2")
    }

    @Test("the local mic speaker is never renamed by an external name")
    func micNotRenamed() {
        let assembler = TranscriptAssembler()
        let finals = [
            TranscriptionResult(channel: .mic, text: "my words", start: 0.0, end: 2.0,
                                isFinal: true, tokens: [("my words", 0.0, 2.0)]),
        ]
        let spans = [NameSpan(name: "Alice", start: 0.0, end: 2.0)]

        let (_, speakers) = assembler.assemble(
            finals: finals, speakerSegments: [], nameSpans: spans)

        #expect(speakers["S1"]?.name == nil)
    }
}
