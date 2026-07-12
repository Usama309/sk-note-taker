import Foundation
import AVFoundation
import AppKit
import SKNoteCore

// Diagnostic: run a live AudioSource for N seconds and report signal levels.
// Usage: sknote-audiocheck [mic|system|both|pick] [seconds] [--vp|--voiceio]
//   mic      — microphone via MicAudioSource
//   system   — system-audio tap via SystemAudioSource
//   both     — both, on a shared clock
//   pick     — run MicSourcePicker (probe + decision), then capture via the chosen source
//   --vp     — (mic only) AVAudioEngine voice processing (the old, broken behavior)
//   --voiceio— (mic only) VoiceIOMicSource: AUVoiceIO capture (survives other apps' calls)
//
// Run from Terminal so the mic-permission prompt attributes to Terminal.

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "mic"
let seconds = args.count > 2 ? (Double(args[2]) ?? 5) : 5
let useVP = args.contains("--vp")
let useVoiceIO = args.contains("--voiceio")

struct LevelStats {
    var count = 0
    var maxRMS: Float = 0
    var sumRMS: Float = 0
    var nonSilentChunks = 0
    var totalSamples = 0

    mutating func add(_ samples: [Float]) {
        count += 1
        totalSamples += samples.count
        guard !samples.isEmpty else { return }
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        maxRMS = max(maxRMS, rms)
        sumRMS += rms
        if rms > 0.001 { nonSilentChunks += 1 }
    }

    var meanRMS: Float { count > 0 ? sumRMS / Float(count) : 0 }

    func report(_ label: String) {
        print(String(format:
            "[%@] chunks=%d samples=%d maxRMS=%.5f meanRMS=%.5f nonSilentChunks=%d",
            label, count, totalSamples, maxRMS, meanRMS, nonSilentChunks))
        if maxRMS < 0.001 {
            print("  ❌ SILENT — the \(label) channel produced no signal.")
        } else {
            print("  ✅ SIGNAL PRESENT on \(label).")
        }
    }
}

let clock = SessionClock()

// Thread-safe accumulator so the collector task and main flow don't race.
final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = LevelStats()
    func add(_ samples: [Float]) { lock.lock(); stats.add(samples); lock.unlock() }
    var value: LevelStats { lock.lock(); defer { lock.unlock() }; return stats }
}

func runSource(_ source: any AudioSource, label: String) async -> LevelStats {
    let box = StatsBox()
    do {
        let stream = try await source.start()
        let deadline = Date().addingTimeInterval(seconds)
        let collector = Task {
            for await chunk in stream { box.add(chunk.samples) }
        }
        while Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        await source.stop()
        _ = await collector.result
    } catch {
        print("  ⚠️ \(label) failed to start: \(error.localizedDescription)")
    }
    return box.value
}

print("sknote-audiocheck: mode=\(mode) seconds=\(seconds) voiceProcessing=\(useVP)")
print("Make noise / play audio now…\n")

switch mode {
case "mic":
    let mic: any AudioSource = useVoiceIO
        ? VoiceIOMicSource(clock: clock)
        : MicAudioSource(clock: clock, voiceProcessing: useVP)
    let label = useVoiceIO ? "mic(voiceio)" : "mic"
    let s = await runSource(mic, label: label)
    s.report(label)
    exit(s.maxRMS >= 0.001 ? 0 : 1)

case "pick":
    let micBusy = MicActivity.micInUse()
    let others = MicActivity.bundleIdsUsingMic()
    print("Mic busy: \(micBusy)  identified users: \(others.isEmpty ? "none" : others.joined(separator: ", "))")
    let probe = micBusy ? await MicSourcePicker.probeRawTap() : nil
    if let probe {
        print("Raw-tap probe: chunks=\(probe.chunks) allZero=\(probe.allZero)")
    }
    let choice = MicSourcePicker.decide(othersOnMic: micBusy, probe: probe)
    print("Decision: \(choice.rawValue)")
    let mic: any AudioSource = choice == .voiceProcessing
        ? VoiceIOMicSource(clock: clock) : MicAudioSource(clock: clock)
    let s = await runSource(mic, label: "mic(\(choice.rawValue))")
    s.report("mic(\(choice.rawValue))")
    exit(s.maxRMS >= 0.001 ? 0 : 1)

case "system":
    let sys = SystemAudioSource(clock: clock)
    let s = await runSource(sys, label: "system")
    s.report("system")
    exit(s.maxRMS >= 0.001 ? 0 : 1)

case "both":
    let mic = MicAudioSource(clock: clock, voiceProcessing: useVP)
    let sys = SystemAudioSource(clock: clock)
    async let a = runSource(mic, label: "mic")
    async let b = runSource(sys, label: "system")
    let (ms, ss) = await (a, b)
    ms.report("mic")
    ss.report("system")
    exit(ms.maxRMS >= 0.001 && ss.maxRMS >= 0.001 ? 0 : 1)

case "status":
    // One-shot permission/status report.
    print("Microphone:    \(Permission.micStatus().rawValue)")
    print("System audio:  \(Permission.systemAudioStatus().rawValue)  (grants access to the tap)")
    let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    let app = MeetingAppRegistry.meetingApp(amongRunning: running)
    print("Detection:     mic-in-use=\(MicActivity.micInUse()), meeting app running=\(app ?? "none")")
    let micUsers = MicActivity.bundleIdsUsingMic()
    print("Mic users:     \(micUsers.isEmpty ? "none" : micUsers.joined(separator: ", "))")
    print("Meeting-using-mic: \(MeetingAppRegistry.meetingApp(amongRunning: micUsers) ?? "none (no false positive)")")
    exit(0)

case "probe":
    // Meeting-detection probe: report mic-in-use state + any detected meeting app, once.
    let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    let app = MeetingAppRegistry.meetingApp(amongRunning: running)
    let micUsed = MicActivity.micInUse()
    print("micInUse=\(micUsed) meetingApp=\(app ?? "none")")
    var engine = MeetingDetectionEngine(debounceHits: 1)
    let fired = engine.evaluate(now: 0, micActive: micUsed, meetingApp: app, isRecording: false)
    print(fired != nil ? "→ WOULD NOTIFY: \(fired!)" : "→ no notification")
    exit(0)

default:
    print("unknown mode \(mode)")
    exit(2)
}
