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
│   │ MeetingStore   │ ← │ CodexCLIService (codex exec)  │   │ FolderStore      │             │
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
6. Both streams are also written into separate stereo channels in `recording.m4a` for playback
   and reliable post-meeting reprocessing.

Diarization runs complete-history passes for stable global clustering. Live passes run on a
detached utility task so audio ingestion is never blocked, at 15-second intervals for the first
2 minutes, 60-second intervals through 10 minutes, and 180-second intervals afterward. One final
full pass runs when the meeting ends. Audio that arrives during a pass is buffered separately so
the growing meeting array is not copied on every append.

## Screen recording pipeline

`ScreenVideoRecorder` uses a separate ScreenCaptureKit stream so optional video capture cannot
destabilize transcription. It records 1280 px, 8 fps NV12 frames through hardware H.264 plus
separate system-audio and microphone AAC tracks. Frame reordering is disabled and keyframes are
limited to two-second intervals, which keeps decode timestamps aligned with sparse variable-rate
screen frames. Movie fragments make a partial recording recoverable after a crash. Whole-screen
capture is recommended for long calls because a selected window may stop when the meeting app
closes or recreates it.

## AI layer (Codex CLI, no API key)

`CodexCLIService` resolves `codex` through the user's login shell and runs `codex exec` with:
- ephemeral sessions in a new empty temporary directory for each request
- read-only sandboxing, no approvals, no user config, and no rule files
- `--output-last-message` for plain responses and `--output-schema` for structured responses
- the Codex default model unless the optional model override is set
- self-contained prompts passed through stdin; live web search only when the user enables it

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
  `get_summary`, `search_meetings`, `list_folders`. Registered via `codex mcp add`.

## App bundle & permissions

Swift Package builds a real `SK Note Taker.app` bundle (script, ad-hoc/Dev-ID signed) —
required for stable TCC. Info.plist: NSMicrophoneUsageDescription,
NSAudioCaptureUsageDescription. First-run onboarding walks through both grants.
