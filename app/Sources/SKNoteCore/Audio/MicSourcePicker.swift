import Foundation

/// Chooses the microphone capture path for a live session.
///
/// The default path is the shareable raw tap (`MicAudioSource`). A recording can start before
/// the user joins Google Meet or Zoom, and opening AUVoiceIO first can mute the raw microphone
/// client that the call opens later. Keeping the mic raw preserves both apps' access.
///
/// AUVoiceIO (`VoiceIOMicSource`) is reserved for one case: another app already runs a
/// voice-processing call (WhatsApp/Teams/FaceTime) and has muted raw input to bit-exact zeros.
/// If another app is actively capturing the mic raw with its own echo canceller (for example,
/// Zoom), joining as a VPIO client would mute its capture and break the call. We distinguish
/// those cases by probing the raw tap: real mics carry a noise floor, so non-zero input stays
/// on the raw path while an already-muted input switches to AUVoiceIO.
public enum MicSourcePicker {
    public enum Choice: String, Sendable {
        case raw              // MicAudioSource, the shareable normal path
        case voiceProcessing  // VoiceIOMicSource when another VPIO call already muted raw taps
    }

    public struct ProbeResult: Sendable {
        public let chunks: Int
        public let allZero: Bool
        public init(chunks: Int, allZero: Bool) {
            self.chunks = chunks
            self.allZero = allZero
        }
    }

    /// Pure decision, unit-testable.
    /// - othersOnMic: another process is actively capturing the microphone.
    /// - probe: what a short raw-tap capture delivered (nil when no probe was run).
    public static func decide(othersOnMic: Bool, probe: ProbeResult?) -> Choice {
        // Starting AUVoiceIO before Meet/Zoom opens its raw client can mute the call's mic.
        // Stay on the multi-client raw path unless another active call has already muted it.
        guard othersOnMic else { return .raw }
        // Another app is on the mic but we have no probe evidence: don't disturb it, stay raw.
        guard let probe else { return .raw }
        // No buffers at all means the engine couldn't run alongside the call. Exact zeros mean
        // the other app's VPIO session muted raw taps. Either way, use AUVoiceIO ourselves.
        if probe.chunks == 0 || probe.allZero { return .voiceProcessing }
        // Raw input still carries signal, so the other app captures raw (for example, Zoom
        // with its own canceller). Joining as a VPIO client would mute its call, so stay raw.
        return .raw
    }

    /// Full runtime pick: probe the raw tap when another process is already using the mic,
    /// then return the source that will coexist with that process.
    public static func pick(clock: SessionClock) async -> any AudioSource {
        // The per-process list avoids the false positives of the device-level "running
        // somewhere" flag. With no other client, stay raw so Meet/Zoom can join later. With an
        // active client, probe the raw input and use AUVoiceIO only if it is already muted.
        let others = MicActivity.bundleIdsUsingMic()
        let othersOnMic = !others.isEmpty
        let probe: ProbeResult? = othersOnMic ? await probeRawTap() : nil
        let choice = decide(othersOnMic: othersOnMic, probe: probe)
        if choice == .voiceProcessing {
            SKLog.info(.mic, "raw mic tap muted by another voice-processing session "
                       + "(\(others.joined(separator: ", "))); using AUVoiceIO capture")
            return VoiceIOMicSource(clock: clock)
        }
        let message = othersOnMic
            ? "using raw mic capture; another app is capturing raw: "
                + others.joined(separator: ", ")
            : "using shareable raw mic capture so Meet/Zoom can open the microphone later"
        SKLog.info(.mic, message)
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
