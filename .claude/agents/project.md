# SK Note Taker — Project Agent

## What this is
Native macOS meeting note-taker (Granola-style) with real-time transcription, **speaker
diarization** (Granola doesn't have this), per-meeting speaker naming, AI summaries/Q&A via the
**Claude Code CLI** (no API key), project/client folders, an MCP server, and a local web view.

## Stack
- **Mac app**: Swift 6 / SwiftUI, macOS 26 target. Swift Package + app bundle build script
  (same pattern as WindowKeeper — bundle needed for stable TCC permissions).
- **ASR**: Apple SpeechAnalyzer/SpeechTranscriber (on-device, macOS 26).
- **System audio**: Core Audio process tap; **mic**: AVAudioEngine.
- **Diarization**: FluidAudio Swift package (on-device CoreML).
- **AI**: `claude -p` subprocess (headless, JSON output). Never call the Anthropic API directly.
- **MCP server + web view**: TypeScript/Node under `mcp/` and `web/`, reading the same data dir.
- **Data dir**: `~/Library/Application Support/SKNoteTaker/` (JSON per meeting + folders.json).

## GitHub account
- This repo lives on the PERSONAL account: `saqibkamransaif` (private).
- The Mac's default active gh account is `SaqibK-PH` (work). Before push/gh ops:
  `gh auth switch -h github.com -u saqibkamransaif` — switch back to SaqibK-PH after.

## Rules
- Laravel/React global standards do NOT apply here (Swift/TS project).
- Meeting data is personal — never commit runtime data, logs, or transcripts.
- Update CHANGELOG.md on every confirmed change; tests in `tests/`, reports in `tests/reports/`.
