import Foundation

/// Chooses the microphone capture path for a live session.
///
/// While another process runs an Apple voice-processing session (WhatsApp/Teams/FaceTime
/// call), macOS mutes raw input clients — the normal `MicAudioSource` tap receives bit-exact
/// zeros. The fix is capturing through AUVoiceIO ourselves (`VoiceIOMicSource`), but joining
/// as a VPIO client would in turn mute a call app that captures raw with its own echo
/// canceller (e.g. Zoom). So the decision is empirical: when another app is on the mic, probe
/// the raw tap briefly — only the muted signature (buffers of exact digital zeros; real mics
/// always carry a noise floor) switches us to voice-processing capture.
public enum MicSourcePicker {
    public enum Choice: String, Sendable {
        case raw              // MicAudioSource — the normal path
        case voiceProcessing  // VoiceIOMicSource — another app's VPIO call is muting raw taps
    }

    public struct ProbeResult: Sendable {
        public let chunks: Int
        public let allZero: Bool
        public init(chunks: Int, allZero: Bool) {
            self.chunks = chunks
            self.allZero = allZero
        }
    }

    /// Pure decision — unit-testable.
    /// - othersOnMic: another process is actively capturing the microphone.
    /// - probe: what a short raw-tap capture delivered (nil when no probe was run).
    public static func decide(othersOnMic: Bool, probe: ProbeResult?) -> Choice {
        guard othersOnMic, let probe else { return .raw }
        // No buffers at all → engine couldn't run alongside the call; exact zeros → muted.
        if probe.chunks == 0 || probe.allZero { return .voiceProcessing }
        return .raw
    }

    /// Full runtime pick: probe the raw tap when the mic is already busy, return the source.
    ///
    /// "Busy" is the device-level running state, not the per-process bundle list — bundle
    /// mapping misses unbundled processes and app helpers, and we only need to know that
    /// SOMEONE else has input running (we haven't started our own capture yet).
    public static func pick(clock: SessionClock) async -> any AudioSource {
        let micBusy = MicActivity.micInUse()
        let probe: ProbeResult? = micBusy ? await probeRawTap() : nil
        let choice = decide(othersOnMic: micBusy, probe: probe)
        if choice == .voiceProcessing {
            let others = MicActivity.bundleIdsUsingMic()
            let message = "SKNoteTaker: raw mic tap muted by another voice-processing session "
                + "(\(others.isEmpty ? "unknown app" : others.joined(separator: ", "))) "
                + "— using AUVoiceIO capture\n"
            FileHandle.standardError.write(Data(message.utf8))
            return VoiceIOMicSource(clock: clock)
        }
        return MicAudioSource(clock: clock)
    }

    /// Runs the raw tap briefly and reports whether it delivered any non-zero sample.
    public static func probeRawTap(duration: Duration = .milliseconds(500)) async -> ProbeResult {
        let source = MicAudioSource(clock: SessionClock())
        do {
            let stream = try await source.start()
            let collector = Task { () -> ProbeResult in
                var chunks = 0
                var allZero = true
                for await chunk in stream {
                    chunks += 1
                    if chunk.samples.contains(where: { $0 != 0 }) { allZero = false }
                }
                return ProbeResult(chunks: chunks, allZero: allZero)
            }
            try? await Task.sleep(for: duration)
            await source.stop()
            return await collector.value
        } catch {
            return ProbeResult(chunks: 0, allZero: true)
        }
    }
}
