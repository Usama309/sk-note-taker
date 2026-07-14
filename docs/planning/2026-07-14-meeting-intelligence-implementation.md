# Meeting Intelligence — Implementation Document

**Date:** 2026-07-14
**Version target:** 1.6.0
**Author:** Claude (designed from Saqib's requirements, 14 Jul 2026)

## 1. Problems reported

1. **The app doesn't know when a meeting ends.** It keeps recording after everyone
   hangs up. It should notice ~2 minutes of silence — or farewell talk in the
   transcript ("okay, thanks, bye, take care") — ask whether the meeting has ended,
   and end the meeting itself if nobody responds. Important nuance: when Saqib
   speaks Urdu the transcriber produces nothing, but the meeting is still live —
   so "silence" must be judged from **audio energy**, never from "no transcribed
   words".
2. **Audio recording alongside the transcript.** (Investigation: the app already
   records every meeting to `recording.m4a` and uploads it to Supabase — all 5
   existing meetings have one on disk. The real gap is discoverability: playback
   is a single tiny icon with no scrubber, no seek, no export. This becomes a
   playback-experience upgrade rather than a new recording pipeline.)
3. **No way to ask AI questions *during* the meeting.** Chat exists only on
   finished meetings. During a call Saqib wants: what's going on, what do they
   mean, what should I respond?
4. **Plus any smart AI features that increase productivity.**

## 2. What exists today (relevant architecture)

- `MeetingSession` (SKNoteCore) orchestrates one live meeting: mic + system
  audio sources → per-channel `TranscriptionService` → `DiarizationService` →
  `TranscriptAssembler` → autosaved transcript. It already computes per-chunk
  RMS for the UI level meters and appends every chunk to `RecordingWriter`
  (AAC m4a, on by default; `meeting.hasRecording = true`).
- `MeetingDetectionEngine` (pure, unit-tested) detects meeting **starts** from
  mic-in-use + known call apps; `MeetingNotifier` posts the native notification.
  There is no end-of-meeting counterpart.
- `ClaudeCLIService` runs all AI via the Claude Code CLI: `summarize`,
  `answer` (post-meeting chat), `categorize`. Transcript autosaves continuously,
  so live data is available — only the UI and a live-tuned prompt are missing.
- `MeetingDetailView` has Summary/Transcript/Notes/Chat tabs and a bare
  play/pause button for the recording.

## 3. Feature designs

### F1 — Meeting-end detection (`MeetingEndEngine`)

New pure struct in `SKNoteCore/MeetingEndDetection.swift`, mirroring the style
of `MeetingDetectionEngine` (no I/O, fully unit-testable).

**Inputs** (fed by `MeetingSession`):
- `noteAudio(now:rms:)` — called per audio chunk on any channel. RMS ≥ 0.01
  (same threshold as the existing `channelHasAudio` logic) counts as activity
  and updates `lastAudioAt`. Language-independent by construction.
- `noteUtterance(now:text:)` — called per final transcript segment; runs the
  farewell matcher and records `lastUtteranceAt`.

**Triggers** (checked by `evaluate(now:)`, throttled to ~1/s by the caller):
- **Silence:** no audio activity on either channel for `silenceTimeout`
  (default 120 s, user-configurable 1–5 min). Guard: engine only arms after the
  meeting has had *some* audio (prevents firing during a slow start).
- **Farewell:** a final utterance within the last 45 s matched a farewell
  pattern **and** `farewellQuiet` (20 s) of audio silence has followed it.
  Patterns (case-insensitive, word-boundary): bye, goodbye, bye-bye, take care,
  see you, talk soon, talk to you later, thanks everyone, thank you everyone,
  have a good one/day/night, catch you later, khuda hafiz, allah hafiz.

**Outcome:** `evaluate` returns `.promptEnd(reason:)` once, then holds until
`snooze(now:)` (user chose Keep Recording → suppress 5 min and require fresh
silence) or the session ends.

**Prompt flow** (in `MeetingSession` + app layer):
- Session exposes `endPromptReason: String?` (Observable). UI shows a banner in
  `LiveMeetingView`: "Looks like the meeting may have ended (2 min of silence).
  Ending in 60s…" with **Keep Recording** and **End Now** buttons and a live
  countdown.
- `MeetingNotifier` gains a second category (`SK_MEETING_ENDED`) with the same
  two actions, so the prompt reaches Saqib even when the app is backgrounded.
- If nobody responds within `autoEndGraceSeconds` (60 s), the session
  auto-finishes exactly like pressing End Meeting. If audio resumes above the
  threshold during the countdown, the prompt cancels itself (meeting clearly
  continues).

**Settings:** `autoEndDetection: Bool = true`, `autoEndSilenceMinutes: Double = 2`.

### F2 — Recording playback experience

Recording capture already works; upgrade consumption:
- `PlaybackController` (@Observable, app layer): wraps `AVAudioPlayer` with
  `playing`, `currentTime` (0.25 s timer while playing), `duration`, `rate`
  (1×/1.25×/1.5×/2×), `seek(to:)`, `revealInFinder()`.
- `MeetingDetailView` header gets a real player bar when `hasRecording`:
  play/pause, scrubber slider, `mm:ss / mm:ss`, speed menu, Show in Finder.
- Transcript tab: clicking a segment's **timestamp** seeks the player to that
  moment and starts playback (bubble tap still toggles selection).
- `LiveMeetingView` header shows a small "REC" badge so it's visible that audio
  is being saved.

### F3 — Live in-meeting AI assistant

- Right pane of `LiveMeetingView` becomes two tabs: **Notes** (unchanged) and
  **Assistant** — the existing chat UI bound to the *live* transcript
  (`Transcript(segments: session.liveSegments)`), so no store round-trip and it
  works mid-meeting.
- Quick-action chips above the input:
  - **Catch me up** — recap what has happened so far.
  - **What do they mean?** — explain the last exchange in plain language.
  - **Suggest a response** — 1–3 things Saqib could say next, in his voice.
- New `ClaudeCLIService.liveAssist(...)`: prompt tuned for during-call help
  (be fast, concrete, answer-first; user is the mic speaker; transcript may be
  mid-sentence; cap transcript to the last ~12 000 chars for latency).
- Q&A persists into the same `chat.json`, so the conversation continues
  seamlessly in the post-meeting Chat tab.

### F4 — Smart auto-features on meeting end

- **Auto-title:** the `categorize` call (already fired on finish) additionally
  returns a concise `title` (≤ 6 words). Applied only when the meeting still
  has its default "…Meeting" timestamp title — a manual rename always wins.
- **Auto-summary:** after finish, when the transcript is non-empty and Claude
  CLI is available, generate the summary automatically (same path as the
  Generate Summary button). Setting `autoSummarize: Bool = true`.

## 4. Components & file changes

| File | Change |
|---|---|
| `SKNoteCore/MeetingEndDetection.swift` | new — `MeetingEndEngine` + `FarewellMatcher` |
| `SKNoteCore/MeetingSession.swift` | feed engine, `endPromptReason`, countdown, auto-finish callback |
| `SKNoteCore/Models.swift` | `AppSettings`: autoEndDetection, autoEndSilenceMinutes, autoSummarize |
| `SKNoteCore/AI/ClaudeCLIService.swift` | `liveAssist(…)`; `categorize` returns `title` |
| `SKNoteTakerApp/MeetingNotifier.swift` | `SK_MEETING_ENDED` category + actions |
| `SKNoteTakerApp/SKNoteTakerApp.swift` (AppState) | `askLive`, auto-title/summary on stop, end-prompt plumbing |
| `SKNoteTakerApp/LiveMeetingView.swift` | end banner + countdown, Notes/Assistant tabs, REC badge |
| `SKNoteTakerApp/MeetingDetailView.swift` | player bar, timestamp-seek |
| `SKNoteTakerApp/ChatAndSheets.swift` | settings toggles; chat view reuse for live assistant |
| `Tests/SKNoteCoreTests/MeetingEndDetectionTests.swift` | new — engine + farewell matcher unit tests |

## 5. Testing plan

1. **Unit (new):** MeetingEndEngine — silence trigger at exactly the timeout;
   no trigger while audio continues (Urdu speech = audio without transcript);
   farewell + quiet triggers early; farewell followed by resumed talk does not
   trigger; snooze suppresses and re-arms; no trigger before first audio.
   FarewellMatcher — positives/negatives incl. "bye" inside "bystander" must
   not match.
2. **Unit (existing):** full `swift test` suite must stay green.
3. **Build:** `make app` produces the 1.6.0 bundle; deploy to /Applications;
   launch and verify the app boots, meeting list renders, player bar appears
   on an existing meeting with a recording.
4. **Live-path checks that need a real call** (flagged to Saqib): end-of-call
   auto-detection on a real WhatsApp/Teams call, and live assistant latency
   during a call.

## 6. Out of scope (deliberate)

- Voice-enrollment speaker naming (tracked separately from v1.5.3 notes).
- Detecting meeting end from the call app releasing the mic (SK Note Taker
  itself holds the mic while recording, which muddies that signal; silence +
  farewell covers the need with less risk).
- Streaming/token-by-token assistant responses (CLI is one-shot; acceptable).
