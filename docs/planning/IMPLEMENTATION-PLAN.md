# SK Note Taker — Implementation Plan

## Scope for v1.0 (this autonomous run)

**In**: dual-stream capture (mic + system tap), on-device real-time transcription, speaker
diarization (S1..Sn), per-meeting speaker naming, full-meeting audio recording, notes editor
with AI-enhanced summary (action items / decisions / things to remember), chat-with-meeting
Q&A, project/client folders with AI auto-categorization, MCP server, LAN web view, beautiful
branded UI + logo, tests + reports, GitHub publish.

**Out (v2 backlog)**: calendar integration & meeting auto-detect, templates library, sharing
links, cloud sync, iOS/Windows, integrations (Slack/Notion/CRM), briefs, multi-meeting chat.
Documented in BACKLOG section of README.

## Phases

### Phase 1 — Core engine (SKNoteCore Swift library)
1. `Package.swift` (deps: FluidAudio), targets: SKNoteCore (lib), SKNoteTaker (exec), tests.
2. Models: Meeting, TranscriptSegment, Speaker, Folder, Settings (Codable, DATA-MODEL.md).
3. `MeetingStore` / `FolderStore`: atomic JSON persistence in data dir.
4. `AudioSource` protocol + `FileSource` (WAV reader, chunked, simulated clock).
5. `MicSource` (AVAudioEngine + voice processing), `SystemAudioSource` (Core Audio tap +
   aggregate device + IOProc), resampler to 16k mono Float32.
6. `TranscriptionService` (SpeechAnalyzer/SpeechTranscriber wrapper, volatile + final).
7. `DiarizationService` (FluidAudio wrapper, incremental chunked + final pass).
8. `TranscriptAssembler` (merge, utterance coalescing, source tagging).
9. `MeetingSession` (orchestrates one meeting: sources → services → store → recording).
10. `RecordingWriter` (AVAudioFile m4a).

### Phase 2 — AI (ClaudeCLIService)
1. Subprocess runner (zsh -lc, async, timeout, JSON parse, error surface).
2. Summary generation w/ json-schema front-matter contract.
3. Chat Q&A (transcript with resolved names + history).
4. Auto-categorization into folders (existing-folder matching, new-folder proposal).

### Phase 3 — App UI + branding
1. Logo: SVG + app icon (.icns via iconutil) — waveform/note mark, teal-indigo gradient.
2. SwiftUI app: NavigationSplitView — folder sidebar / meeting list / detail.
3. Detail: title bar (record button, timer), notes editor + live transcript (speaker-colored
   bubbles), summary tab, chat tab, speakers sheet (rename S1→name), folder picker.
4. Settings: model choice, data dir, audio device info, permissions status.
5. Onboarding: permission walkthrough.
6. build-app.sh → signed .app bundle; Makefile.

### Phase 4 — MCP + Web (delegated to subagents with full spec)
1. `mcp/`: TS stdio server, 6 tools, README with `claude mcp add` instructions + tests.
2. `web/`: Express server + polished single-page UI (read + speaker rename + folder move),
   port 4517, `npm start`; tests.

### Phase 5 — Testing (fix-and-retest loop)
1. Unit: stores, assembler merge logic, name substitution, folder logic (swift test).
2. Integration: synthesized 2–3-voice WAV via `say` → FileSource → full pipeline →
   assert diarized transcript; ClaudeCLIService live call; summary + Q&A end-to-end.
3. MCP: spawn server, JSON-RPC handshake + each tool against fixture data.
4. Web: supertest/curl endpoints + Chrome DevTools MCP visual check.
5. App: build bundle, launch, screenshot main window states (Chrome MCP not applicable —
   use `screencapture` + Accessibility). Verify no crashes, permission flow visible.
6. Report → tests/reports/TEST-REPORT-v1.0.md.

### Phase 6 — Ship
README (screenshots, install, permissions), CHANGELOG 1.0.0, commit, private GitHub repo
under `saqibkamransaif`, push, switch gh back. Profile delta entry.

## Key risks & mitigations

| Risk | Mitigation |
|---|---|
| TCC prompts unclickable autonomously | FileSource-based integration tests cover the pipeline; live capture verified to the permission boundary; onboarding UX for the user's first run |
| FluidAudio API drift vs research | Pin 0.15.x, adapt to actual API at compile time |
| SpeechTranscriber asset download | Do it at engine init w/ progress; tests trigger it once |
| claude CLI latency (~35 s) | All AI calls async w/ visible progress; summary is explicit user action; categorize in background |
| Swift 6 concurrency strictness | SKNoteCore actors + Sendable models from the start |
