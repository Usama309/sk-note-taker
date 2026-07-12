# Tech Research — macOS 26 Transcription / Diarization / Claude CLI (July 2026)

Condensed engineering findings; full details in git history of this file.

## 1. Speech-to-text: SpeechAnalyzer / SpeechTranscriber (macOS 26, `import Speech`)

- On-device, async/await native, designed for hours-long multi-speaker audio. Use instead of
  legacy SFSpeechRecognizer.
- `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with
  `reportingOptions: [.volatileResults]`, `attributeOptions: [.audioTimeRange]`.
- Model assets via `AssetInventory.assetInstallationRequest(supporting:)` →
  `downloadAndInstall()`. Assets shared system-wide.
- Feed via `AsyncStream<AnalyzerInput>` (wraps AVAudioPCMBuffer, convert to
  `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` first).
- Results: `result.text: AttributedString` (runs carry `.audioTimeRange` CMTimeRange),
  `result.isFinal` (volatile → replaced; final → immutable).
- On-device path needs mic TCC only (no speech-recognition prompt).

## 2. System audio capture: Core Audio process taps (winner over ScreenCaptureKit)

- Audio-only TCC category ("System Audio Recording Only"), no purple screen indicator.
- Info.plist: `NSAudioCaptureUsageDescription`. Binary MUST be signed or the prompt never fires.
  Deployment target ≥ 14.4. Reset: `tccutil reset SystemAudioCaptureRequests <bundle-id>`.
- Flow: `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` (= tap everything) →
  `AudioHardwareCreateProcessTap` → aggregate device with real default-output as main
  sub-device + tap in `kAudioAggregateDeviceTapListKey` + `TapAutoStartKey: true` →
  `AudioDeviceCreateIOProcIDWithBlock` (NOT AVAudioEngine — it can't attach to tap aggregates).
- Gotchas: pass a real dispatch queue (nil silently fails on macOS 26); rebuild aggregate on
  default-output-device change; `isExclusive` is a direction flag.
- Reference: insidegui/AudioCap.

## 3. Mic capture + echo

- AVAudioEngine `inputNode.installTap`, with `try inputNode.setVoiceProcessingEnabled(true)`
  (AEC + noise suppression + AGC) so remote voices from speakers don't bleed into mic stream.
- Mic and system tap are separate HAL clients — no conflict. Dual-stream gives free
  "me vs them" attribution.

## 4. Diarization: FluidAudio

- SPM: `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0")`
  (latest 0.15.5, Apache 2.0, macOS 14+, CoreML/ANE).
- Models auto-download from HuggingFace (`FluidInference/speaker-diarization-coreml`):
  `DiarizerModels.downloadIfNeeded()` → `DiarizerManager(config:)` → `initialize(models:)` →
  `performCompleteDiarization(samples16k, sampleRate: 16000)` → `TimedSpeakerSegment`
  (speakerId, startTimeSeconds, endTimeSeconds).
- Requires 16 kHz mono Float32.
- Streaming diarizers exist (LSEENDDiarizer / SortformerDiarizer, ~100 ms updates).
- Merge with ASR: token midpoint vs speaker segment max-overlap; coalesce runs into utterances.
  Diarize only the system stream; mic stream is always the local user.

## 5. Claude Code CLI headless

- `claude -p "<prompt>" --output-format json` → `{ result, session_id, usage, ... }`.
  Verified working on this machine (subscription OAuth from keychain; do NOT use --bare).
- `--json-schema '<schema>'` → validated `.structured_output` (ideal for action items JSON).
- stdin as Unix filter (≤10 MB); `--model sonnet|haiku`; `--resume <session_id>` for follow-up
  Q&A over same context.
- From Swift: Process via `/bin/zsh -lc` (login shell for PATH), run off main actor, generous
  timeout. Measured ~35 s first call on this machine — all AI calls must be async with UI
  progress state.
- App cannot be App-Sandboxed (subprocess + keychain) → Developer ID / local signed build.

## 6. MCP server (TypeScript)

- `@modelcontextprotocol/sdk` v1.x (pin ^1.29; v2 is beta) + zod.
- `McpServer` + `registerTool`/`registerResource` + `StdioServerTransport`.
- Never write to stdout except JSON-RPC; log to stderr.

## Testing constraint (autonomous run)

TCC prompts (mic, system audio) can't be clicked by an agent. Therefore the engine abstracts
audio input behind an `AudioSource` protocol: `MicSource`, `SystemTapSource`, `FileSource`.
Full pipeline (ASR + diarization + merge + summary) is integration-tested by feeding
synthesized multi-voice WAV files (macOS `say -v <voice>`) through `FileSource`. Live-capture
paths are exercised as far as permission checks allow, with clear first-run UX for granting.
