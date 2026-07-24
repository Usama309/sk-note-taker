# Changelog

## [Unreleased]

### Added
- **Speaker tags (Zoom), scaffolding.** Groundwork for real participant names on the transcript:
  a name-attribution engine that labels each speaker cluster with the dominant name from the
  meeting-app UI, a macOS Accessibility permission flow, a Zoom accessibility reader that attaches
  read-only to the Zoom app and feeds active-speaker names into the transcript, a Settings →
  Speaker tags row (Zoom "Set up / Ready / Connected") with a debug "dump accessibility tree"
  action, and lifecycle wiring so the reader runs during Zoom meetings when Accessibility is
  granted. The live active-speaker extraction is tuned against a real Zoom call.
- **Upcoming events view.** A new **Upcoming** item appears in the sidebar once Google Calendar
  is connected. It lists all your upcoming events grouped by day (Today / Tomorrow / date).
  Clicking an event opens it in the detail pane with its time, location, guests, and description,
  plus actions to **Start notes** (a recording pre-titled after the event), **Join** the call, or
  **Open in Google Calendar**. The home-screen card gained a "See all" link, and its rows now open
  the event too.
- **Google Calendar sign-in (in-app, browser-based).** A "Connect Google Calendar" button in
  Settings opens the system browser to Google's login using OAuth 2.0 with a loopback redirect and
  PKCE. Once connected, the next few events from your primary calendar appear on the home screen
  (each with Join and "Start notes" actions). The client secret and sign-in tokens live only in
  the macOS Keychain, never in the app's files. One-time setup: paste an OAuth client ID/secret
  (type "Desktop app") created in Google Cloud with the Calendar API enabled. A blocked or
  abandoned sign-in can be cancelled and times out after 3 minutes rather than hanging.
- **Expandable project folders.** Each folder now has a disclosure arrow; clicking a folder
  rotates the arrow and expands it inline to list every recording inside it (indented in the
  sidebar) while also filtering the middle column to that folder. Clicking a nested recording
  opens it directly in the detail pane. Clicking the folder again collapses it.
- **Redesigned sidebar.** A sectioned layout: a **Library** section (All Meetings + a **Starred**
  filter, each with live counts) and a **Projects** section (folders shown with a stable colour
  dot and count, a "+" to add one inline). A profile card pinned to the bottom shows the user
  avatar, name, "Local workspace", and a settings gear. Drag-and-drop filing and the drag-over
  highlight carry over to every row.
- **Redesigned meeting detail view.** A cleaner header (editable title, star/favourite, overflow
  menu, "New recording", share) with a metadata row and participant avatars; an underline tab
  bar (Summary / Transcript / Notes / Chat); and a right rail with an Action items card (owner
  avatars) and a Participants card (Host badge). Prev/next arrows step through the list.
- **WhatsApp-style waveform audio player** with play/pause, a clickable amplitude waveform that
  fills as it plays, a **speed** menu (0.75×–2×), and a **volume** control. The waveform is
  computed off the main thread from the recording.
- **Star / favourite meetings** (persisted). The saved AI chat per meeting stays available in
  the Chat tab.
- **File meetings into folders by drag-and-drop.** Drag a meeting from the list onto a folder
  in the sidebar (the folder highlights as you hover); drop onto "All Meetings" to unfile.
  A right-click "Move to Folder" submenu does the same precisely.
- **Meeting-detection popup.** When a Zoom / Meet / Teams / WhatsApp call starts (a call app
  running with the mic active), a custom floating panel appears top-right, on top of other apps
  (even a fullscreen call). Styled like a native macOS notification: the SK logo, a "<App>
  meeting started" title, a "Take notes with SK Note Taker" subtitle, and a single **Start**
  button that launches the note directly in compact mode. A thin bar fills left→right over the
  ~40s window, then the popup auto-dismisses. Hovering pauses the countdown and reveals a
  macOS-style close (x) chip at the top-left corner to dismiss it. Replaces the plain system
  notification, which couldn't control the lifetime, draw the bar, or launch into compact mode.
  A "Preview meeting popup" menu item (and Cmd-Shift-D) shows it on demand.
- **In-window Settings button.** A gear next to "New Folder" in the sidebar opens Settings
  directly; previously only the macOS menu / Cmd-comma did.
- **Pause / resume during a recording.** A pause button in the meeting header (and in compact
  mode) freezes the timeline stopwatch-style — the paused stretch is neither recorded nor
  transcribed, and resuming continues seamlessly with no silent gap and no jumped timer.
- **Compact floating transcript mode.** A button shrinks the window to a narrow strip docked to
  the right edge that floats on top of other apps, showing the live transcript and the Ask-AI
  pane, so a meeting can be followed over Zoom/Outlook without the full app in the way.
  Recording keeps running; an expand button restores the previous window.

### Changed
- **In-meeting AI is faster and terser.** The live assistant now runs on the fast Haiku model
  with a stricter "answer in 1–3 sentences, no preamble" prompt, so it's usable mid-call.
- **"TL;DR" renamed to "Quick summary"** in generated summaries (plainer language).

### Fixed
- **Saving Google Calendar credentials showed no feedback.** The "Saved" badge and the Connect
  button didn't react because the saved-credentials state lived on the non-observable service; it
  now mirrors into an observable property, so the UI updates the instant credentials are saved.
  (The credentials were always being written to the Keychain correctly.)
- **Ending an empty meeting popped a "No transcript" error.** A recording with no speech no
  longer triggers an auto-summary attempt (and its alert).
- **"All Meetings" and folder rows were not clickable in the sidebar.** They relied on
  `List(selection:)`, whose rows did not register clicks; they are now buttons that reliably
  switch the meeting-list filter, with the active one highlighted.
- **Remote voices collapsing onto the mic, and the recording running slow / behind real time.**
  A chain of related capture-pipeline bugs, root-caused across several real calls plus a
  multi-agent investigation:
  - *Timeline drift.* `SessionClock` stamped each channel by summing only its own produced
    audio, so ScreenCaptureKit's ~2 s startup offset (and any gap) left the system channel a
    permanent step behind the mic; once it exceeded `RecordingWriter`'s 2 s holdback, every
    later system sample was stamped "too late" and dropped, blanking the remote side of the
    recording at a hard ~60 s cliff. Live capture now anchors both channels to one wall clock
    (`SessionClock(anchorToWallClock:)`); offline reprocess keeps pure audio-content timing.
  - *Mic blanked while the remote played.* `RecordingWriter` advanced a single shared write
    frontier to the *faster* channel's position (`max` across channels), so a mic chunk that
    arrived a beat behind the system channel was discarded — your voice was transcribed but
    silent in the recording. The frontier is now a staleness- and lag-guarded *minimum*, with
    a contiguous zero-filling flush and a drain-everything `finish()`, so neither channel is
    dropped and the tail is never lost.
  - *Recorder ran at ~40 % of real time and fell further behind over the call.* The mic
    (AUVoiceIO) and ScreenCaptureKit deliver ~10 ms buffers ~100×/s; per-tiny-chunk recorder +
    ASR + diarizer work on two channels couldn't sustain real time on an older Mac, and the
    live diarization (which re-analyzes the whole accumulated buffer) got heavier over time.
    The pump now coalesces buffers into ~80 ms batches, writes the recording before feeding the
    ASR (durability first), publishes the live meters at 15 Hz, and runs diarization + transcript
    assembly off the main actor at low priority so they can never starve real-time audio.
  - *Restart storm and lost tail.* The captured-silence watchdog now only arms after real audio
    has been heard (45 s window), so it no longer restarts on ordinary opening silence; and
    `teardownSources()` drains the buffered backlog before cancelling (bounded to 8 s) so the
    end of the meeting is written instead of discarded.
  - *Diagnostics.* Every meeting now logs a `Clock check` (audio vs wall + per-channel cursors),
    a `Pump time` breakdown (recorder / ASR / diarizer), and any dropped-late samples, so a
    future regression is a number in the log rather than a guess. Covered by new
    `SessionClockTests` and `RecordingWriterGapTests`.
- **System audio going silent ~2 minutes into a call while the stream stayed "alive".** In a
  real Zoom call the mic/system split was correct for the first ~134 s, then the system
  channel went permanently empty and the remote participant was captured only via the mic
  (labelled as the local user). Unlike the earlier ~101 s stall, ScreenCaptureKit kept
  firing audio callbacks the whole time — they just carried silence — so the callback-stall
  watchdog never fired and the flight recorder showed the stream still running. Two fixes:
  (1) a power assertion (`idleDisplaySleepDisabled` / `idleSystemSleepDisabled`) held for the
  whole capture, because SCK's display-bound audio capture stops delivering real audio when
  the display sleeps — the leading suspect given the failure hit right after the user stepped
  away from the Mac; and (2) a second watchdog branch that restarts the stream when it keeps
  firing callbacks but captures no real sound for 20 s, recovering regardless of cause. The
  heartbeat now also logs "last SOUND ms ago" (not just last callback), so a silence failure
  is visible in the log instead of looking healthy. A restart is logged as a warning
  (recovery), not an error.


### Fixed
- **Remote voice doubled onto the microphone (heard twice, transcribed twice).** With audio
  on the laptop speakers, the mic recorded the remote participant coming out of the speakers,
  so the same voice landed on both channels — audible as a doubled/echoed voice on playback,
  and transcribed twice ("Omni" on the mic speaker, "Omni Road" on the system speaker). Cause:
  the mic used the raw capture path with no echo cancellation, because `MicActivity.micInUse()`
  (a coarse device-level "running somewhere" flag) falsely reported another app on the mic
  when nothing was. `MicSourcePicker` now bases that decision on the accurate per-process check
  (`bundleIdsUsingMic`), so with no other app truly capturing it takes the AUVoiceIO path,
  whose echo canceller removes the speaker bleed. Verified: with audio playing through the
  speakers the recorded mic channel dropped from roughly matching the system channel (ratio
  ~1.0) to a ratio of 0.02 — the mic is now essentially clean of the remote voice. A real
  native call (Zoom/Teams capturing the mic raw) still keeps the raw path so its capture isn't
  disturbed.


### Added
- **Your name, asked once and used for the microphone speaker.** First run now asks for a name
  in the onboarding sheet, and Settings → You keeps it editable. Anything captured on the
  microphone is labelled with it (falling back to "Me" when blank) instead of a generic
  "Speaker 1", which read as a stranger. The name is stamped onto the meeting's mic speaker
  when a session starts, not just prettified in the view, so it flows everywhere the
  transcript goes: summaries, chat, copied text, exports, MCP and the web view. A per-meeting
  rename still wins over the global name, and existing meetings keep showing "Me".
- **Desktop logging with error codes.** Diagnostics went to stderr, which is discarded for a
  Finder-launched app — which is why a capture failure mid-meeting left no trace and had to be
  reverse-engineered from the recorded audio. Everything now lands in two files that are
  created on first use, so they can be checked after any meeting without tooling:
  `~/Desktop/SK Note Taker Logs/sknotetaker.log` (every entry, chronological) and
  `errors.log` (errors only, one detailed block each). Errors carry a stable code
  (`CAP-004`, `TAP-005`, `AI-001`, …), the category, the meeting they occurred in, and the
  underlying error's domain and OS status code. Each meeting is bracketed by banners and ends
  with a summary line (`900s, 0 error(s), 0 warning(s)`) plus a per-channel report of whether
  mic and system actually carried audio. Every previously silent failure path is wired in:
  capture start/stall/restart, process-tap rebuilds, mic permission and voice-processing,
  transcription stream, diarization, recording writes, store reads, cloud sync, AI requests
  and session start/save. Files rotate at 10 MB. `--selftest-logging` writes sample entries
  to confirm the pipeline end to end.


### Fixed
- **ScreenCaptureKit capture stalling ~100 s into a meeting.** In the 19 Jul demo call the
  mic/system split was correct for the first 101 s — every remote line landed on the system
  channel and every local line on the mic — and then the system channel went permanently
  silent, so the remote speaker was labelled "Me" for the rest of the call. No error, no
  `didStopWithError`, and `tap.log` showed the stream still nominally running. Cause:
  `SCStream` always captures video, and the stream was configured with a video surface and a
  queue depth but only an `.audio` output was registered. Nothing consumed the video frames,
  the queue filled, and the whole stream stalled — silently taking audio with it. A `.screen`
  output is now registered on its own queue and discards frames, keeping the queue draining.
  Added a liveness watchdog that restarts the stream if audio callbacks stop for >3 s, and a
  30-second heartbeat to `tap.log` (callback counts, time since last callback, restart count)
  so any future silent failure is diagnosable after the fact. Verified over a 6-minute
  endurance run: 357/357 s continuous audio, 18,004 callbacks, zero restarts needed —
  previously it died at 101 s.

### Changed
- **System audio now captured via ScreenCaptureKit instead of a Core Audio process tap.** The
  process tap binds its aggregate device to whichever output device was default when it was
  built; a call app engaging its audio engine (Zoom installs its own virtual output) left the
  aggregate pointing at a stale device and its IOProc went deaf. Measured across five
  consecutive real meetings, the system channel died 15–22 s in and never recovered, which
  collapsed every remote voice onto the microphone and mislabelled remote speakers as "Me".
  ScreenCaptureKit captures the system audio graph rather than a specific device, so there is
  no device binding to go stale. New `ScreenCaptureAudioSource`; `SystemAudioCapture` picks it
  and falls back to the old process tap automatically when Screen Recording isn't granted, so
  capture never hard-fails. The stream excludes our own process audio. Permission reporting
  now reflects the Screen Recording grant that the primary path needs.
- **Stable code-signing identity, so privacy grants survive rebuilds.** macOS records the
  Screen Recording grant against the app's code signature. The build signed ad-hoc, whose
  signature changes on every rebuild, so each build silently lost the grant — System Settings
  still showed the app enabled while `CGPreflightScreenCaptureAccess()` reported denied and
  capture quietly fell back to the process tap. `scripts/make-signing-identity.sh` creates a
  local self-signed code-signing certificate once, and `build-app.sh` now prefers a real Apple
  Development identity, then that local one, then ad-hoc. The designated requirement is now
  `identifier + certificate root` rather than a per-build hash, verified identical across two
  consecutive builds — so the permission is granted once and persists.
- **Messaging-app transcript layout.** What the microphone captured is you, so it now renders
  right-aligned and labeled **"Me"** (or your assigned name); everyone arriving on the system
  channel stays left-aligned under their own speaker name. Applies to the live meeting view
  and to every saved transcript, past and future. This also removes a real source of
  confusion: the app reserves Speaker 1 for the mic and numbers remote people from 2, so a
  line correctly attributed to the user still read as "Speaker 1" and looked misattributed.
  The bubble is right-aligned but its text stays left-aligned — right-aligned body text gives
  a ragged left edge and is harder to read in English.

### Fixed
- **Two remote speakers reported as one (3-person call showed 2 people).** On the FSL
  Blueprint call, Afaq and Waqas were both labelled Speaker 2. Two independent causes, both
  measured against that recording's system channel:
  1. **Clustering under-split.** FluidAudio's clustering threshold (0.6) put both voices in
     one cluster; a sweep on the real audio showed they separate at 0.45 and below. Default
     lowered 0.6 → 0.45 (the loosest value that separates them, so it over-splits least).
  2. **The merge pass then re-swallowed the survivor.** `SpeakerClusterMerger.absorbDistance`
     was 0.85, wide enough to absorb a genuinely different voice measured 0.751 away purely
     because only 1.2 s of him had been captured. Tightened 0.85 → 0.70, which sits between a
     real backchannel (≈0.64) and a distinct person (0.751).
  Verified end-to-end by re-processing the real recording: "Sorry, bro." → S2 (Afaq) and
  "My gosh, sorry." → S3 (Waqas), where both were previously S2.
- **"Redo speaker detection" left the transcript pane showing the OLD attribution.** The
  detail view loaded the transcript once on appear and never re-read it, so after a redo the
  speaker chips updated (they come from the observable meeting) while the messages still
  showed the pre-redo speakers — the fix looked like it had failed when the saved data was
  already correct. The view now keys its load on a `transcriptRevision` counter that the
  redo bumps.
- **Real one-syllable words deleted as echo.** The echo filter dropped ANY sub-0.2 s mic token
  within 0.75 s of remote audio, silently eating real words like "how", "no", "so". It now
  also requires the token to be ISOLATED — a faint echo blip stands alone, whereas the first
  word of a sentence has more local speech right behind it. (Note: the specific missing "How"
  on the FSL call turned out to be an ASR miss at utterance onset, not this filter.)
- **System-audio tap dying ~15 s into a meeting (root cause of "everything is detected as
  the mic").** Analysis of real stereo recordings showed the system (remote) channel carrying
  audio only for the first ~15 seconds and then going to pure digital silence for the rest of
  the meeting, while the mic carried everything — so every remote voice collapsed onto the mic
  and was labelled Speaker 1. The Core Audio process-tap aggregate was bound to the default
  output device captured once at start; when a meeting app (Zoom/Teams) switches or
  reconfigures the default output as the call connects, the aggregate points at a now-idle
  device and its IOProc stops firing permanently. `SystemAudioSource` now rebuilds the
  tap+aggregate chain on ANY of four signals: (1) the default output device changes, (2) the
  bound output device reconfigures its nominal sample rate or stream config (VPIO engagement
  flips the built-in speakers, leaving the tap stale), (3) the IOProc stops firing entirely
  (>2.5 s), or (4) the IOProc keeps firing but delivers only silence while the output device
  is actively rendering for a client (>3 s, rate-limited) — the exact mid-meeting-deaf
  signature. The output stream and session clock are stable across rebuilds, so the system
  channel stays continuous. Added an append-only flight recorder at Application Support/
  SKNoteTaker/tap.log and a hidden `--selftest-systime [--switch]` diagnostic (both run under
  the app bundle's TCC grant, plus `--selftest-meeting` which runs a real MeetingSession).
  Two bugs in the first healing pass were then fixed: the silence-rebuild was gated on the
  output device reporting "running" (false in the real failure, so it never fired), and tap
  liveness was judged by "any nonzero sample" when a deaf tap actually emits a near-zero
  noise floor (RMS ~3e-5) — so silence was never detected. Liveness now requires real energy
  (RMS > 1e-3), the running-device gate is gone, and a proactive refresh rebuilds the chain
  at least every 10 s (only during a >300 ms quiet gap, so it never clips speech).
  Verified: baseline and full-pipeline capture deliver continuously (46/46 s with a music
  reference) under the real grant. The exact real-meeting death could not be reproduced
  synthetically (it is timing/environment specific), so final confirmation still comes from a
  real call — tap.log now records every build/rebuild for that.

### Added
- **`EchoCanceller`** (reference-based NLMS acoustic echo canceller). Groundwork for removing
  residual speaker→mic echo once the system reference is reliable again: it subtracts the
  clean system channel from the mic. Validated offline on a real recording (~15 dB echo
  reduction with the local voice preserved); not yet wired into the live/reprocess pipeline.

### Fixed (earlier this session)
- **Remote voice bleeding into the mic channel (mislabeled as "Speaker 1").** On laptop
  speakers the remote participant's voice comes out of the speakers and the raw microphone
  re-records it, so the same audio was transcribed on the mic channel and attributed to the
  local user (S1). The mic path now defaults to AUVoiceIO capture, whose acoustic echo
  canceller subtracts the speaker output from the mic, so the local channel stays "just you".
  `MicSourcePicker` takes this path whenever it's safe — nobody else on the mic, or another
  app's voice-processing call has already muted raw taps — and still falls back to the raw tap
  only when another app is actively capturing the mic *raw* with its own canceller (e.g. Zoom),
  where opening our own VPIO session would mute that app's call. Known limitation: while a
  raw-capturing call app like Zoom holds the mic on speakers, capture-side AEC is unavailable
  (use headphones, or rely on the post-transcription echo suppression).

## [1.7.0] — 2026-07-14

Speaker-separation release. Addresses remote participants collapsing into a single
"Speaker 2" in multi-person calls.

### Added
- **Stereo recording (mic-L / system-R).** Meetings now save the microphone and system
  audio as separate channels instead of a mono mix. This isolates the remote-participant
  stream so speaker detection can re-run cleanly on it — mixing the two polluted diarization
  with the local mic and its echo. Playback is unaffected. New `RecordingLoader` /
  `MeetingReprocessor` in SKNoteCore.
- **"Redo speaker detection."** In the Speakers sheet of any recorded meeting, re-run
  detection on the recording. It re-transcribes (fresh word timings), re-diarizes, and
  re-assembles — so speaker changes that the live pass had merged into one long block become
  real, separate turns. Validated on real recordings: the 14 Jul 51-minute call went from
  everyone collapsed into one speaker (1748s in 15 blocks) to four distinct speakers
  (1367 / 192 / 110 / 362s) with natural turn-taking; the 13 Jul call separated into three.

### Notes
- On **new stereo recordings** the local speaker stays cleanly labeled "Speaker 1 (you)"
  while remote voices separate into Speaker 2/3/… On **legacy mono recordings**, Redo still
  separates the distinct voices but can't peel the local speaker out of the mix (rename as
  needed).
- Investigated but not shipped: reducing the live diarization interval (over-splits on small
  buffers) and segment-level re-attribution of the saved transcript (the live pass had
  already coalesced audio into long blocks with no word timings to split on) — which is why
  the fix reprocesses from the recording instead.

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
