import Foundation
import Testing
@testable import SKNoteCore

/// End-to-end pipeline tests over synthesized multi-voice audio (no TCC permissions needed —
/// audio comes from files). Enabled with SKNOTE_INTEGRATION=1 because the first run downloads
/// on-device models (SpeechTranscriber locale asset + FluidAudio CoreML models).
@Suite("Pipeline integration",
       .enabled(if: ProcessInfo.processInfo.environment["SKNOTE_INTEGRATION"] == "1"),
       .serialized)
struct PipelineIntegrationTests {

    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil,
                                 subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing — run scripts/make-fixtures.sh")
    }

    private func tempDataDir() -> URL {
        // SKNOTE_PIPELINE_OUT lets cross-component tests (MCP/web) consume real pipeline output.
        if let out = ProcessInfo.processInfo.environment["SKNOTE_PIPELINE_OUT"] {
            let url = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sknote-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("File sources → transcription → diarization → assembled diarized transcript",
          .timeLimit(.minutes(10)))
    @MainActor
    func fullPipelineOverSyntheticMeeting() async throws {
        let store = MeetingStore(dataDir: tempDataDir())
        let sources: [any AudioSource] = [
            FileAudioSource(url: try fixtureURL("mic.wav"), channel: .mic),
            FileAudioSource(url: try fixtureURL("system.wav"), channel: .system),
        ]
        let session = MeetingSession(
            title: "Integration Test Meeting", store: store,
            sources: sources, clock: SessionClock(), recordAudio: true)

        await session.start()
        if case .failed(let why) = session.phase {
            Issue.record("session failed to start: \(why)")
            return
        }

        // File sources finish quickly (no realtime pacing); wait for ASR results to settle:
        // keep polling until segment count is stable for a few seconds.
        var lastCount = -1
        var stableTicks = 0
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            let count = session.liveSegments.count
            if count == lastCount && count > 0 {
                stableTicks += 1
                if stableTicks >= 5 { break }
            } else {
                stableTicks = 0
                lastCount = count
            }
        }

        await session.finish()
        #expect(session.phase == .idle)

        let meeting = try #require(try await store.meeting(id: session.meeting.id))
        let transcript = try #require(try await store.transcript(for: session.meeting.id))

        // --- Transcript content ---
        let allText = transcript.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(!transcript.segments.isEmpty, "transcript should not be empty")
        #expect(allText.contains("launch") || allText.contains("checklist"),
                "system speech should be transcribed, got: \(allText.prefix(300))")
        #expect(allText.contains("single sign on") || allText.contains("version one")
                || allText.contains("ship"),
                "mic speech should be transcribed, got: \(allText.prefix(300))")

        // --- Attribution ---
        let micSegments = transcript.segments.filter { $0.source == .mic }
        let systemSegments = transcript.segments.filter { $0.source == .system }
        #expect(!micSegments.isEmpty, "mic channel produced no segments")
        #expect(!systemSegments.isEmpty, "system channel produced no segments")
        #expect(micSegments.allSatisfy { $0.speaker == "S1" }, "mic is always S1")

        // --- Diarization: the two TTS voices should be distinguished ---
        let systemSpeakers = Set(systemSegments.map(\.speaker))
        #expect(systemSpeakers.count >= 2,
                "expected ≥2 diarized system speakers, got \(systemSpeakers)")

        // --- Speakers map + rename flow ---
        #expect(meeting.speakers["S1"]?.source == .mic)
        let renameKey = try #require(systemSpeakers.sorted().first)
        var updated = meeting
        updated.speakers[renameKey]?.name = "Kainat"
        try await store.save(updated)
        let rendered = try #require(try await store.transcript(for: meeting.id))
            .rendered(with: updated)
        #expect(rendered.contains("Kainat:"), "rename should reflect in rendered transcript")

        // --- Duration derived from the audio itself (~22 s fixture) ---
        #expect(meeting.durationSec > 15, "durationSec should reflect audio length, got \(meeting.durationSec)")

        // --- Recording exists and is playable length ---
        #expect(meeting.hasRecording)
        let recording = await store.recordingURL(for: meeting.id)
        let size = (try? FileManager.default.attributesOfItem(atPath: recording.path)[.size]
                    as? Int) ?? 0
        #expect(size ?? 0 > 10_000, "recording.m4a should have real audio data")
    }
}
