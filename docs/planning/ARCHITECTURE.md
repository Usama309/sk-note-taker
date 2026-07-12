# SK Note Taker — Architecture

## Components

```
┌─────────────────────────────── macOS app (Swift 6 / SwiftUI) ───────────────────────────────┐
│                                                                                             │
│  UI Layer (SwiftUI)                                                                         │
│   Sidebar (folders) · Meeting list · Note editor + live transcript · Chat pane · Settings   │
│                                                                                             │
│  SKNoteCore (library target, fully testable)                                                │
│   ┌──────────────┐  ┌──────────────────┐  ┌───────────────┐  ┌──────────────────────┐       │
│   │ AudioEngine  │→ │ TranscriptionSvc │→ │ DiarizerSvc   │→ │ TranscriptAssembler  │       │
│   │ MicSource    │  │ (SpeechAnalyzer, │  │ (FluidAudio,  │  │ (merge ASR+speakers, │       │
│   │ SystemTap    │  │  2 instances)    │  │  system strm) │  │  utterance coalesce) │       │
│   │ FileSource   │  └──────────────────┘  └───────────────┘  └──────────────────────┘       │
│   └──────┬───────┘                                                    │                     │
│          └── RecordingWriter (m4a)                                    ▼                     │
│   ┌────────────────┐   ┌───────────────────────────────┐   ┌──────────────────┐             │
│   │ MeetingStore   │ ← │ ClaudeCLIService (claude -p)  │   │ FolderStore      │             │
│   │ (JSON on disk) │   │ summary·Q&A·auto-categorize   │   │ (projects/clients│             │
│   └────────────────┘   └───────────────────────────────┘   └──────────────────┘             │
└───────────────────────────────────────┬─────────────────────────────────────────────────────┘
                                        │  shared data dir: ~/Library/Application Support/SKNoteTaker
                       ┌────────────────┴──────────────────┐
              ┌────────▼─────────┐              ┌──────────▼──────────┐
              │ MCP server (TS)  │              │ Web view (Node)     │
              │ stdio, tools:    │              │ localhost:4517      │
              │ list/get/search  │              │ meetings, transcript│
              │ meetings, trans- │              │ summary, rename     │
              │ cripts, summaries│              │ speakers, folders   │
              └──────────────────┘              └─────────────────────┘
```

## Audio pipeline

1. **MicSource** — AVAudioEngine input tap with voice processing (AEC) → local user's voice.
2. **SystemTapSource** — Core Audio process tap on all system output → remote participants.
3. Both resampled to 16 kHz mono Float32 on a shared session clock (seconds from start).
4. Each stream feeds its own **SpeechTranscriber** (volatile results → live UI; finalized runs
   with audioTimeRange → transcript store).
5. System stream also feeds **FluidAudio diarizer**. Speaker segments are merged with system
   ASR tokens by midpoint-overlap → S2, S3, … Mic stream is always S1 ("me").
6. Both streams are also written into `recording.m4a` (mixed) — playback later (Granola can't).

Diarization runs incrementally during the meeting (chunked batch every ~10 s over accumulated
system audio for stable clustering) and does a final full pass at meeting end.

## AI layer (Claude Code CLI — no API key)

`ClaudeCLIService` shells out to `claude -p` (login-shell resolved path) with:
- `--output-format json` (+ `--json-schema` for structured outputs)
- `--model` from settings (default sonnet)
- lean context: prompts are self-contained; transcript passed via stdin

| Feature | Prompt shape | Output |
|---|---|---|
| Enhanced summary | transcript + user notes + template | markdown w/ YAML front-matter (actionItems, decisions, remember) |
| Chat / Q&A | transcript w/ speaker names + question (+ chat history) | text answer |
| Auto-categorize | title + attendees + transcript head + existing folder list | {client, project, confidence} JSON |

Speaker names are substituted (S2 → "Kainat") **before** prompting, so "What did Kainat say?"
works naturally.

## Speaker naming

Transcript segments store stable keys (S1…Sn). `meeting.json.speakers` maps key → name.
Renaming is metadata-only (instant, no transcript rewrite). All renderers (app, web, MCP,
AI prompts) resolve names at display/prompt time.

## Web view + MCP

Both are thin readers of the same data dir (no daemon coupling to the app):
- **Web** (`web/`): Node + Express, zero-build vanilla JS frontend, listens on 0.0.0.0:4517 so
  phones on the LAN can review meetings. Can edit speaker names + folder assignment.
- **MCP** (`mcp/`): stdio server; tools: `list_meetings`, `get_meeting`, `get_transcript`,
  `get_summary`, `search_meetings`, `list_folders`. Registered via `claude mcp add`.

## App bundle & permissions

Swift Package builds a real `SK Note Taker.app` bundle (script, ad-hoc/Dev-ID signed) —
required for stable TCC. Info.plist: NSMicrophoneUsageDescription,
NSAudioCaptureUsageDescription. First-run onboarding walks through both grants.
