# Changelog

## [1.2.0] — 2026-07-12

### Added — menu bar app + native notifications
- **Menu bar icon** (waveform): New Meeting, Open SK Note Taker, recent meetings, Settings,
  Quit — start or open from anywhere without the main window (Zoom/Willow style).
- The app now **runs in the background** (menu bar keeps it alive; App Nap disabled) so it
  keeps detecting meetings even when the window is closed.
- Meeting detection now fires a **native macOS notification** ("You're in a &lt;app&gt;
  meeting — start taking notes?" with the app icon and Start Notes / Options actions).
  Clicking it brings the app forward and starts recording. The old in-app banner is removed.
- Settings → Meeting Detection shows notification permission status with an Open Settings link.
- Verified live: Teams call detected while the app was backgrounded → native notification →
  click → app foregrounded + recording started.

### Fixed
- Notification-permission `await` was blocking the detector from starting; detection now
  starts immediately and requests notification permission in the background.

## [1.1.0] — 2026-07-12

### Added — automatic meeting detection (Granola-style)
- Detects when a **Zoom, Microsoft Teams, WhatsApp, Slack, Webex, Discord, FaceTime, or
  browser (Google Meet / Zoom-web)** call starts — by watching the microphone's in-use state
  (Core Audio, no permission needed) cross-checked against running meeting apps.
- Pops up a **"You're in a &lt;app&gt; meeting — start taking notes?"** prompt: a macOS
  notification with a **Start Notes** action, plus an in-app banner when the app is frontmost.
  Clicking **Start Notes** begins recording immediately.
- Debounced (two consecutive polls), fires once per call, suppressed while already recording,
  and honours a cooldown after you dismiss. **On by default**; toggle in Settings → Meeting
  Detection.
- Verified live: a real Teams call fired the banner → Start Notes → a full 32 s recording.
- 14 new tests (app registry, detection state machine, cooldown/debounce, settings default +
  legacy decode). 82 automated tests total.

## [1.0.1] — 2026-07-12

### Fixed — microphone capture (critical)
- **Mic produced pure silence.** `setVoiceProcessingEnabled(true)` requires an active output
  render chain to deliver input buffers; a capture-only app has none, so the mic delivered
  zero audio (Speaker 1 never appeared). Now captures the raw input node. Verified live: a
  real meeting produced 20 mic segments + 20 system segments.
- Mic **preflight permission request** with a clear error on denial (no more silent recording).

### Added
- First-run **permission onboarding** walkthrough (mic + system audio, live status).
- **Settings → Permissions** panel: status + Request / Open Settings, plus the `tccutil reset`
  hint for the exact bundle id.
- **Live per-channel input level meters** and a **"no microphone audio detected" banner** in
  the recording view.
- `sknote-audiocheck` diagnostic CLI (`mic` / `system` / `both`) and a `Makefile`.
- New tests: audio RMS on signal vs silence, resampler energy/downsampling, permission model,
  level-meter math (68 automated tests total, up from 58).

## [1.0.0] — 2026-07-12

First release — built autonomously end-to-end (research → planning → implementation → tests).

### Mac app (`app/`)
- Botless dual-stream capture: microphone (AVAudioEngine + echo cancellation) and
  system audio (Core Audio process tap, no screen-recording permission needed).
- Real-time on-device transcription (Apple SpeechAnalyzer/SpeechTranscriber, macOS 26).
- **Speaker diarization** (FluidAudio CoreML, on-device): live transcript labeled
  Speaker 1..N — the headline upgrade over Granola's Me/Them.
- Per-meeting speaker naming (Speaker 2 → "Kainat") — instant, metadata-only; names flow
  into transcripts, summaries, chat, MCP, and web.
- Full-meeting audio recording (m4a) with in-app playback (Granola discards audio).
- Granola-style notepad: rough notes during the meeting become anchors for the AI summary.
- AI via **Claude Code CLI** (subscription, no API key): intelligent summary (TL;DR,
  action items with owners, decisions, things to remember), chat-with-meeting Q&A,
  auto-categorization into client/project folders.
- Folder organization (clients → projects) with badge counts and manual override.
- SwiftUI three-pane UI, brand gradient (indigo→teal), custom logo + app icon,
  signed .app bundle build script.

### MCP server (`mcp/`)
- TypeScript stdio server: `list_meetings`, `get_meeting`, `get_transcript`,
  `get_summary`, `search_meetings`, `list_folders`.

### Web view (`web/`)
- Node/Express app on port 4517 (LAN-accessible): browse folders/meetings, read
  summaries/transcripts/notes, play recordings, rename speakers, move meetings.

### Tests
- 12 unit tests (stores, assembler merge, front-matter codec).
- Pipeline integration test over synthesized multi-voice audio (TTS): ASR + diarization
  (2 speakers) + attribution + rename + recording.
- Live Claude CLI tests: summary, speaker Q&A, categorization.
- MCP + web endpoint test suites.

### Fixed during development
- Chunk-boundary audio corruption from per-chunk AVAudioConverter creation (mangled ASR);
  switched to persistent converters.
- Hardened-runtime signing silently denied the microphone until the
  `com.apple.security.device.audio-input` entitlement was added.
- System-audio tap IOProc read the physical output device's silent stream instead of the
  tap's; now selects the ABL buffer matching the tap format.
- Transcription finals emitted during finalization were dropped (consumer task was
  cancelled instead of drained).
- Diarization clustering threshold lowered 0.7 → 0.6: macOS speaker-output processing
  compresses voice-embedding distances, which merged distinct speakers on live captures
  (verified by threshold sweep on live-captured audio).
- durationSec was 0 for file-sourced sessions (clock never advanced); now derived from
  audio chunk timestamps.
