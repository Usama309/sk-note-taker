import Foundation

/// Chooses the microphone capture path for a live session.
///
/// The default path is AUVoiceIO (`VoiceIOMicSource`): its acoustic echo canceller subtracts
/// the speaker output (the remote participant's voice on laptop speakers) from the mic, so the
/// local channel stays "just you" instead of also transcribing the echo and mislabeling it as
/// Speaker 1. We take that path whenever it's safe:
///   - Nobody else is on the mic → open our own voice-processing session freely (no other raw
///     client exists to be muted by it).
///   - Another app runs a voice-processing call (WhatsApp/Teams/FaceTime) → macOS has already
///     muted raw input clients to bit-exact zeros, so `MicAudioSource` would capture silence;
///     AUVoiceIO still receives real mic audio.
///
/// The one case we stay on the raw tap: another app is actively capturing the mic *raw* with
/// its own echo canceller (e.g. Zoom). Joining as a VPIO client would mute ITS capture and
/// break the user's actual call — worse than losing echo cancellation on our side. We detect
/// this by probing the raw tap: real mics always carry a noise floor, so a live non-zero
/// signal means someone else is capturing raw.
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
        // Nobody else on the mic: we're free to open a voice-processing session, and we want
        // it for the echo canceller (removes speaker bleed from the mic).
        guard othersOnMic else { return .voiceProcessing }
        // Another app is on the mic but we have no probe evidence → don't disturb it, stay raw.
        guard let probe else { return .raw }
        // No buffers at all → engine couldn't run alongside the call; exact zeros → the other
        // app's VPIO session muted raw taps. Either way, capture through AUVoiceIO ourselves.
        if probe.chunks == 0 || probe.allZero { return .voiceProcessing }
        // Raw tap still carries signal → the other app captures raw (e.g. Zoom with its own
        // canceller). Joining as a VPIO client would mute its call, so we stay raw.
        return .raw
    }

    /// Full runtime pick: probe the raw tap when the mic is already busy, return the source.
    ///
    /// "Busy" is the device-level running state, not the per-process bundle list — bundle
    /// mapping misses unbundled processes and app helpers, and we only need to know that
    /// SOMEONE else has input running (we haven't started our own capture yet).
    public static func pick(clock: SessionClock) async -> any AudioSource {
        // Whether ANOTHER app is truly capturing the mic. `MicActivity.micInUse()` reads the
        // device-level "running somewhere" flag, which has false positives — it can read true
        // with NO process actually on the mic. That false positive pushed us onto the raw path
        // (no echo cancellation), so the remote voice coming out of the speakers bled into the
        // mic and got recorded on both channels — the "doubled voice". The per-process check is
        // accurate: a real Zoom/Teams call still shows up here, but idle-device false positives
        // don't. When nobody else holds the mic we take the AUVoiceIO path, whose echo
        // canceller removes that speaker bleed.
        let others = MicActivity.bundleIdsUsingMic()
        let othersOnMic = !others.isEmpty
        let probe: ProbeResult? = othersOnMic ? await probeRawTap() : nil
        let choice = decide(othersOnMic: othersOnMic, probe: probe)
        if choice == .voiceProcessing {
            let message = othersOnMic
                ? "raw mic tap muted by another voice-processing session "
                    + "(\(others.joined(separator: ", "))) — using AUVoiceIO capture"
                : "using AUVoiceIO capture for acoustic echo cancellation "
                    + "(removes speaker bleed from the mic)"
            SKLog.info(.mic, message)
            return VoiceIOMicSource(clock: clock)
        }
        SKLog.info(.mic, "using raw mic capture (another app is capturing raw: "
                   + "\(others.joined(separator: ", ")))")
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
