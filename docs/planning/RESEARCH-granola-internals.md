# Granola — Local Installation Research (v7.394.2, July 2026)

From inspecting /Applications/Granola.app and ~/Library/Application Support/Granola/.

## Architecture

- **Electron app** (React + Redux/Zustand), universal binary, min macOS 12.
- **Encrypted SQLite** (`granola.db`, better-sqlite3-multiple-ciphers) — not readable without key.
- **Backend**: Supabase + WorkOS SSO; WebSocket sync; pull-based sync engine with intervals
  (documents 10 min, lists 1 min, entities 30 min).
- Helper: `GranolaMacWebcam` — virtual camera system extension (meeting watermark).
- Telemetry: PostHog + Sentry.

## Audio capture (the important part)

Declared Info.plist usage strings:

```
NSAudioCaptureUsageDescription:  "During your meetings, Granola transcribes your microphone"
NSScreenCaptureUsageDescription: "During your meetings, Granola uses screen capture to transcribe system audio"
NSMicrophoneUsageDescription:    "During your meetings, Granola transcribes your microphone"
NSCalendarsUsageDescription:     calendar for upcoming meetings
```

- **Microphone**: direct Core Audio device capture, device-switch following.
- **System audio**: captured via system-audio capture permission (screen-capture API family);
  dropout detection with auto-restart (threshold 30 s).
- **ASR**: streamed to AssemblyAI ("assembly-universal") or Deepgram — cloud, real time; audio
  is then discarded (no local recording).
- **Summaries**: Claude **Sonnet 4.6** (default), Nova 3 fallback — via their backend.
- Echo cancellation disabled on headphones; automatic gain compensation.

## Data model (inferred from cache/feature flags)

- Document = meeting record: transcript segments (speaker_id, source mic|system, timestamps,
  confidence), summary (model, regen count), participants, sharing/permissions, folders/lists.
- Lists with auto-add rules + "List Auto-Pilot" AI rules (domain-based, recurring-meeting).
- Chat with multi-document context, model selection (Auto / Nova 3 / Sonnet 4.6), web search,
  citations to transcript segments.
- Transcription retention default 3 days (then transcript details purged).
- Feature flag "real-time speaker labels" exists as an **upsell experiment** — confirms
  diarization is not shipped on desktop.

## Takeaways for SK Note Taker

1. Mirror the dual-stream model: mic + system audio as separate tracked sources.
2. We do ASR **on-device** (SpeechAnalyzer) — better privacy than Granola's cloud ASR, no
   per-minute cost, and we can keep the audio (recording playback is a Granola gap).
3. Plain-JSON local store instead of encrypted SQLite — single-user, local-only, MCP/web
   friendly. Encryption can come later.
4. Their sync/workspace/team layer is out of scope for v1 (single user, local + LAN web view).
