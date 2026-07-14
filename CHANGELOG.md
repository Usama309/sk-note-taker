# Changelog

## [1.6.1] — 2026-07-14

### Fixed
- **False "has the meeting ended?" prompt while the client was still talking.** The silence
  timer only reset on audio above the RMS activity gate (≈ −40 dBFS). The remote
  participant's voice arrives on the system-audio channel and is routinely transcribed well
  below that gate (a listener on headphones or low volume), so while the client spoke and
  the local user stayed quiet, both channels read as "silent" and after 2 minutes the app
  wrongly asked whether the meeting had ended — then re-asked repeatedly. Now **any
  transcription on any channel resets the silence timer**: if words are being transcribed,
  the meeting is unambiguously live. The RMS path stays, so untranscribed speech (e.g.
  Urdu) still keeps a meeting alive.
- **Repeated end-of-meeting notifications.** The prompt now fires **at most once per
  meeting**, and dismissing the notification counts as "keep recording" — a single,
  dismissible notification instead of a recurring nag.

## [1.6.0] — 2026-07-14

Meeting intelligence release. Design doc:
`docs/planning/2026-07-14-meeting-intelligence-implementation.md`.

### Added
- **Automatic meeting-end detection.** SK Note Taker now notices when a call is over
  instead of recording forever. Two signals: ~2 minutes of audio silence (judged from
  audio *energy*, not transcription — so speaking Urdu or any untranscribed language still
  counts as an active meeting), or farewell talk in the transcript ("okay thanks, bye, take
  care", plus Urdu "Khuda Hafiz / Allah Hafiz"). When triggered it shows a banner (and a
  native notification while backgrounded) asking "Has the meeting ended?" with **Keep
  Recording** / **End Now**, and auto-ends after a 60-second countdown if nobody responds.
  If audio resumes during the countdown, the prompt cancels itself. Configurable in
  Settings → Meeting Detection (on by default, 1–5 min silence threshold). New pure
  `MeetingEndEngine` with 11 unit tests.
- **Live in-meeting AI assistant.** The meeting's right pane now has **Notes** and
  **Assistant** tabs. During a call you can ask questions about what's being said, with one
  tap quick actions: **Catch me up**, **What do they mean?**, and **Suggest a response**.
  Answers come from the live transcript and persist into the same chat thread you see after
  the meeting. Tuned for speed and answer-first brevity mid-call.
- **Full recording playback.** Every meeting already recorded its audio; now there's a
  proper player bar — play/pause, a scrubber, elapsed/total time, 1×–2× speed, and Show in
  Finder. Clicking any transcript timestamp jumps playback to that moment. A "Saving audio"
  badge during live meetings makes it clear the audio is being kept.
- **Smart auto-title.** When a meeting ends, its default timestamp name ("14 Jul 9:01 AM
  Meeting") is replaced with a concise AI-generated title describing what it was about
  (e.g. "Homepage and Checkout Flow Redesign"). A manual rename always wins.
- **Automatic summary on meeting end.** The AI summary (action items, decisions, things to
  remember) is now generated automatically when a meeting ends — no need to click Generate.
  Toggle in Settings → After the meeting.

## [1.5.3] — 2026-07-13

### Fixed
- **Third speaker not detected** (13 Jul 6:30 PM test call with two remote participants).
  The inverse of the 1.5.0 bug, caused by its fix: the cluster merger's unconditional
  "same voice" radius (0.45) was calibrated on one meeting, but distance scales flip with
  call conditions — two different men on a phone-quality call measured only 0.32 apart
  (Saqib to a remote voice: 0.42), so the merger folded real people together. The
  unconditional radius is now 0.25 (a true same-voice split measures ~0.18); anything
  farther merges only with fragment-shape evidence (short backchannel utterances or
  sub-12s dust), which real speakers with sentence-length turns never trigger. Verified on
  both real recordings: the 3-person call now yields 3 speakers AND the Patriot 1:1 still
  yields exactly 2. The 6:30 PM meeting was repaired in place by re-diarizing its
  recording and re-attributing the transcript (Speaker 3 restored).
- `sknote-audiocheck diarize` can now dump merged segments to JSON (second argument) for
  transcript repair scripts.

## [1.5.2] — 2026-07-13

### Fixed
- **"Copy selected" was invisible after scrolling.** The button lived in the transcript's
  header row, which scrolls away with the content — selecting messages deep in a long
  transcript left no visible copy control. Selection actions now live in a floating bar
  pinned to the bottom of the transcript ("N selected · Copy selected · clear"), visible at
  any scroll position. Copied lines include the timestamp and speaker name
  (`[24:43] Jeff: …`), same format as "Copy all".

## [1.5.1] — 2026-07-13

### Fixed
- **Jeff's words landing on Saqib's side of the transcript** (e.g. "hold" at 24:43, "so" at
  24:52, "go?" at 24:32 in the Patriot call). On laptop speakers the mic hears the remote
  voice, and the two channels' ASR timestamps skew by a few hundred ms — so the first word
  of a remote sentence appeared on the mic channel *before* the system channel and slipped
  past the time-overlap echo test, becoming a phantom S1 line. Echo suppression now has two
  more signals: a short mic token whose words also appear on the system channel moments
  apart is dropped (skew-proof text match), and a sub-articulation blip (<0.2s — not a
  humanly articulable word) while the remote channel is active is dropped. Real
  interjections ("Got it.", proper word durations, different words) are preserved — covered
  by unit tests. The Patriot transcript was repaired in place: 25 echo fragments removed.

### Added
- **Copy multiple messages** from a meeting transcript: click messages to select them
  (checkmark + highlight), then "Copy N selected" copies just those lines with timestamps
  and speaker names. "Copy all" still copies the full transcript.

## [1.5.0] — 2026-07-13

### Fixed
- **Phantom extra speaker in 1:1 calls.** A two-person meeting (Patriot / Facebook-ads call)
  was diarized as three speakers: the remote participant's short backchannels ("yep",
  "mm-hmm", "wow") have noisy voice embeddings that fell outside the diarizer's tight
  assignment radius and spawned a "Speaker 3". Diarization now runs a post-pass that merges
  same-voice clusters using duration-weighted centroid embeddings — three tiers: clusters
  that are clearly the same voice always merge; small short-utterance clusters are absorbed
  into their nearest voice; sub-12-second "dust" clusters fold into the nearest substantial
  speaker. Verified on the actual meeting recording: raw diarizer produced 13 clusters,
  merged output is exactly the 2 real speakers (kept distinct from each other). Genuinely
  distinct quiet speakers (≥12s of real sentences) are preserved — covered by unit tests.
  The affected meeting's stored transcript was repaired in place (Speaker 3 → Jeff).
- **Unreadable speaker names in dark mode.** Speaker colors (e.g. Jeff's indigo `#4F46E5`)
  had ~2.8:1 contrast on the dark background. The app now uses a light appearance
  (per preference — it no longer follows system dark mode), and the speaker palette was
  reshaded so every speaker color measures ≥4.5:1 (WCAG AA) on light surfaces.

### Added
- `sknote-audiocheck diarize <audio-file>` — offline diagnostic that diarizes a recording
  and reports speaker counts raw vs merged, plus the pairwise centroid distance matrix
  (used to tune the merge thresholds against real meeting audio).

## [1.4.1] — 2026-07-12

### Fixed
- **"No microphone audio detected" during WhatsApp/Teams/FaceTime calls.** When any app runs
  an Apple voice-processing (echo-cancellation) session on the mic, macOS mutes every raw
  input client — our mic tap received bit-exact silence for the whole call even though mic
  permission was granted, so recordings captured only the remote side. Recording now probes
  the raw tap at start when the mic is already busy: if it's muted, capture switches to a
  direct AUVoiceIO (voice-processing) source, which keeps receiving real mic audio during the
  call. When the raw tap still carries signal (e.g. a call app using its own echo canceller),
  we stay on the raw path — joining as a voice-processing client there would mute the call
  app instead.
- Known limitation: if a voice-processing call starts *mid-recording*, the mic goes silent
  until the recording is restarted; the in-app warning banner now says so.

## [1.4.0] — 2026-07-12

### Fixed
- **False meeting detection.** Detection fired whenever the mic was in use and a meeting app
  was merely *running* in the background (e.g. Teams idle) — so a dictation app like Willow
  Voice triggered a bogus "Teams meeting" alert. Now uses Core Audio process objects to detect
  which app is *actually capturing the mic*, and only fires when that app is a meeting app.
- **Fragmented / duplicated transcript.** On laptop speakers the mic picks up the remote
  participants coming out of the speakers, so the same audio was transcribed on both the mic
  (S1) and system (S2) channels — producing duplicated, interleaved one-word fragments. Added
  cross-channel echo suppression: mic tokens that overlap a system token in time are dropped,
  and the remaining tokens coalesce into clean sentences. Local speech (mic active while system
  is quiet) is preserved. Tip: headphones avoid the echo entirely.

### Added
- **Copy buttons** on the transcript, summary, and notes — in both the Mac app and the web app.

## [1.3.0] — 2026-07-12

### Added — Supabase backend + Mac↔web sync (local-first)
- The Mac app now **mirrors every meeting to Supabase** (Postgres) in addition to the local
  store: meetings, transcript segments, summaries, chat, folders, and the audio recording
  (Supabase Storage). Local-first — recording never depends on connectivity; a catch-up sync
  runs at launch and after each save.
- **Web app and MCP server read from Supabase**, so you can review meetings from anywhere, not
  just the same LAN.
- Schema in `supabase/migrations/0001_init.sql` (RLS on; anon-key policies for single-user);
  `supabase/README.md` documents setup and the security tradeoff.
- New Swift `SupabaseSync` actor + live round-trip test (meeting/segments/summary/chat verified
  against the real project, then cleaned up).
- Fixed: audio Storage object name was uppercase while ids are lowercased everywhere else.

### Fixed
- Level meter (v1.2 dB scale) confirmed responsive on live audio.

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
