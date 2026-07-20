import Foundation
import AVFoundation
import AppKit
import FluidAudio
import SKNoteCore

// Diagnostic: run a live AudioSource for N seconds and report signal levels.
// Usage: sknote-audiocheck [mic|system|both|pick] [seconds] [--vp|--voiceio]
//   mic      — microphone via MicAudioSource
//   system   — system-audio tap via SystemAudioSource
//   both     — both, on a shared clock
//   pick     — run MicSourcePicker (probe + decision), then capture via the chosen source
//   diarize <audio-file> — run speaker diarization over a recording and report the speaker
//              count raw (no merge) vs through DiarizationService (same-voice clusters merged)
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

func runSource(_ source: any SKNoteCore.AudioSource, label: String) async -> LevelStats {
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
    let mic: any SKNoteCore.AudioSource = useVoiceIO
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
    let mic: any SKNoteCore.AudioSource = choice == .voiceProcessing
        ? VoiceIOMicSource(clock: clock) : MicAudioSource(clock: clock)
    let s = await runSource(mic, label: "mic(\(choice.rawValue))")
    s.report("mic(\(choice.rawValue))")
    exit(s.maxRMS >= 0.001 ? 0 : 1)

case "system":
    let sys = SystemAudioSource(clock: clock)
    let s = await runSource(sys, label: "system")
    s.report("system")
    exit(s.maxRMS >= 0.001 ? 0 : 1)

case "systime":
    // Capture system audio and print per-second RMS, to see WHEN the tap stops delivering.
    // Usage: sknote-audiocheck systime [seconds]
    let sys = SystemAudioSource(clock: clock)
    final class Timeline: @unchecked Sendable {
        let lock = NSLock(); var buckets: [Int: (n: Int, sum: Float, nz: Int)] = [:]
        func add(_ t: Double, _ samples: [Float]) {
            let sec = Int(t)
            let e = samples.reduce(Float(0)) { $0 + $1 * $1 }
            let nz = samples.contains { $0 != 0 } ? 1 : 0
            lock.lock(); var b = buckets[sec] ?? (0,0,0)
            b.n += samples.count; b.sum += e; b.nz += nz; buckets[sec] = b; lock.unlock()
        }
    }
    let tl = Timeline()
    do {
        let stream = try await sys.start()
        let deadline = Date().addingTimeInterval(seconds)
        let collector = Task { for await c in stream { tl.add(c.startTime, c.samples) } }
        while Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        await sys.stop(); _ = await collector.result
    } catch { print("system start failed: \(error)") ; exit(1) }
    print("second : RMS      nonzero-chunks")
    var lastLive = -1
    for sec in 0..<Int(seconds) {
        let b = tl.buckets[sec]
        let rms = (b != nil && b!.n > 0) ? (b!.sum / Float(b!.n)).squareRoot() : 0
        let nz = b?.nz ?? 0
        if rms > 0.0005 { lastLive = sec }
        print(String(format: "  %3d  : %.5f   %d", sec, rms, nz))
    }
    print("\nLast second with audio: \(lastLive)  (of \(Int(seconds)))")
    exit(0)

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

case "diarize":
    // Offline speaker-count check over a recording: raw diarizer output vs
    // DiarizationService (which folds same-voice clusters). Validates the phantom-speaker
    // fix against real meeting audio.
    guard args.count > 2 else {
        print("usage: sknote-audiocheck diarize <audio-file>")
        exit(2)
    }
    let url = URL(fileURLWithPath: args[2])

    func loadAudio16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
            interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw NSError(domain: "audiocheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot convert \(file.processingFormat) to 16k mono"])
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)!
        var out: [Float] = []
        var done = false
        while !done {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32_768)!
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                inBuf.frameLength = 0
                try? file.read(into: inBuf, frameCount: 32_768)
                if inBuf.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            done = status == .endOfStream || (status == .haveData && outBuf.frameLength == 0)
        }
        return out
    }

    func report(_ label: String, _ segs: [(id: String, start: Double, end: Double)]) {
        print("\n[\(label)] \(Set(segs.map(\.id)).count) speaker(s)")
        let bySpeaker = Dictionary(grouping: segs, by: \.id)
        for (id, group) in bySpeaker.sorted(by: { $0.key < $1.key }) {
            let total = group.reduce(0.0) { $0 + ($1.end - $1.start) }
            let mean = total / Double(group.count)
            print(String(format: "  speaker %@: %3d segments, %6.1fs speech, mean seg %.1fs",
                         id, group.count, total, mean))
        }
    }

    do {
        let samples = try loadAudio16kMono(url)
        print(String(format: "Loaded %.1fs of audio from %@",
                     Double(samples.count) / 16_000, url.lastPathComponent))

        // Raw pass — same config the live service uses, no merging.
        let models = try await DiarizerModels.downloadIfNeeded()
        // SKNOTE_CT overrides the clustering threshold, for sweeping against real audio.
        let ct = Float(ProcessInfo.processInfo.environment["SKNOTE_CT"] ?? "") ?? 0.45
        print("clusteringThreshold = \(ct)")
        var config = DiarizerConfig()
        config.clusteringThreshold = ct
        let raw = DiarizerManager(config: config)
        raw.initialize(models: models)
        let rawResult = try raw.performCompleteDiarization(samples, sampleRate: 16_000)
        report("RAW (no merge)", rawResult.segments.map {
            (id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        })

        // Duration-weighted centroid per cluster + pairwise cosine distances — shows how
        // separable real voices are from phantom fragments.
        var centroids: [String: (sum: [Float], dur: Double)] = [:]
        for seg in rawResult.segments {
            let mag = sqrt(seg.embedding.reduce(Float(0)) { $0 + $1 * $1 })
            guard mag > 1e-6 else { continue }
            let dur = Double(seg.endTimeSeconds - seg.startTimeSeconds)
            let weighted = seg.embedding.map { $0 / mag * Float(dur) }
            if var c = centroids[seg.speakerId] {
                c.sum = zip(c.sum, weighted).map(+)
                c.dur += dur
                centroids[seg.speakerId] = c
            } else {
                centroids[seg.speakerId] = (sum: weighted, dur: dur)
            }
        }
        let unit: [String: [Float]] = centroids.mapValues { c in
            let mag = sqrt(c.sum.reduce(Float(0)) { $0 + $1 * $1 })
            return c.sum.map { $0 / mag }
        }
        print("\nPairwise centroid cosine distances:")
        let ids = unit.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                let d = 1 - zip(unit[a]!, unit[b]!).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                print(String(format: "  %3@ ↔ %-3@ d=%.3f", a, b, d))
            }
        }

        // Through DiarizationService — includes the same-voice cluster merge.
        let service = DiarizationService(clusteringThreshold: ct)
        try await service.prepare()
        await service.feed(AudioChunk(channel: .system, samples: samples, startTime: 0))
        let merged = await service.finalPass()
        report("MERGED (DiarizationService)", merged.map {
            (id: $0.speakerId, start: $0.start, end: $0.end)
        })

        // Optional: dump merged segments as JSON (for transcript repair scripts).
        if args.count > 3 {
            let rows = merged.map { ["speaker": $0.speakerId as Any,
                                     "start": $0.start, "end": $0.end] }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: args[3]))
            print("\nWrote \(merged.count) merged segments to \(args[3])")
        }
    } catch {
        print("diarize failed: \(error)")
        exit(1)
    }
    exit(0)

case "redo":
    // Re-diarize a meeting's recording and re-attribute its saved transcript's system
    // speakers — the post-meeting fix, validated here before wiring into the app.
    // Usage: sknote-audiocheck redo <meeting-dir> [--write]
    guard args.count > 2 else {
        print("usage: sknote-audiocheck redo <meeting-dir> [--write]")
        exit(2)
    }
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    let write = args.contains("--write")

    /// Loads a recording at 16 kHz. Returns the system channel (right) when the file is
    /// stereo (new mic-L / system-R recordings), else the mono mix (legacy recordings).
    func loadSystemChannel16k(_ url: URL) throws -> (samples: [Float], wasStereo: Bool) {
        let file = try AVAudioFile(forReading: url)
        let channels = file.processingFormat.channelCount
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: channels, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw NSError(domain: "audiocheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot convert to 16k"])
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)!
        var perChannel: [[Float]] = Array(repeating: [], count: Int(channels))
        var done = false
        while !done {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32_768)!
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                inBuf.frameLength = 0
                try? file.read(into: inBuf, frameCount: 32_768)
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if outBuf.frameLength > 0 {
                for ch in 0..<Int(channels) {
                    perChannel[ch].append(contentsOf: UnsafeBufferPointer(
                        start: outBuf.floatChannelData![ch], count: Int(outBuf.frameLength)))
                }
            }
            done = status == .endOfStream || (status == .haveData && outBuf.frameLength == 0)
        }
        if channels >= 2 { return (perChannel[1], true) }   // system = right channel
        return (perChannel[0], false)
    }

    func breakdown(_ t: Transcript) -> String {
        var dur: [String: Double] = [:], cnt: [String: Int] = [:]
        for s in t.segments where s.source == .system {
            dur[s.speaker, default: 0] += s.end - s.start
            cnt[s.speaker, default: 0] += 1
        }
        return dur.keys.sorted().map {
            String(format: "%@: %d segs, %.0fs", $0, cnt[$0] ?? 0, dur[$0] ?? 0)
        }.joined(separator: " | ")
    }

    _ = loadSystemChannel16k   // (kept for ad-hoc diagnostics)
    do {
        let tData = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let transcript = try SKJSON.decoder.decode(Transcript.self, from: tData)
        let recURL = dir.appendingPathComponent("recording.m4a")
        let (mic, system) = try RecordingLoader.channels(at: recURL)
        print(String(format: "Reprocessing %.1fs (%@) — re-ASR + re-diarize…",
                     Double(system.count) / 16_000, mic == nil ? "mono mix" : "stereo"))

        let (newT, speakers) = try await MeetingReprocessor.reprocess(recordingURL: recURL)
        let sysSpeakers = Set(newT.segments.filter { $0.source == .system }.map(\.speaker))
        print("System speakers after reprocess: \(sysSpeakers.sorted())")
        print("  BEFORE  \(breakdown(transcript))")
        print("  AFTER   \(breakdown(newT))")

        if write {
            try SKJSON.encoder.encode(newT).write(
                to: dir.appendingPathComponent("transcript.json"))
            let mURL = dir.appendingPathComponent("meeting.json")
            var meeting = try SKJSON.decoder.decode(Meeting.self, from: Data(contentsOf: mURL))
            var merged: [String: SpeakerInfo] = [:]
            for (key, var info) in speakers {
                if let name = meeting.speakers[key]?.name { info.name = name }
                merged[key] = info
            }
            meeting.speakers = merged
            try SKJSON.encoder.encode(meeting).write(to: mURL)
            print("  WROTE updated transcript.json + meeting.json")
        }
    } catch {
        print("redo failed: \(error)")
        exit(1)
    }
    exit(0)

case "aec":
    // Reference-based echo cancellation over a stereo recording. Reports how much of the
    // remote echo is removed from the mic (ERLE, higher = better) and whether the local
    // voice is preserved when the far-end is quiet. Usage: sknote-audiocheck aec <rec.m4a>
    //   [taps] [mu]
    guard args.count > 2 else {
        print("usage: sknote-audiocheck aec <recording.m4a> [taps] [mu]")
        exit(2)
    }
    let recURL = URL(fileURLWithPath: args[2])
    let taps = args.count > 3 ? (Int(args[3]) ?? 1536) : 1536
    let mu = args.count > 4 ? (Float(args[4]) ?? 0.5) : 0.5
    do {
        let (micOpt, system) = try RecordingLoader.channels(at: recURL)
        guard let mic = micOpt else {
            print("recording is mono (legacy) — AEC needs the stereo mic+system channels.")
            exit(1)
        }
        let n = min(mic.count, system.count)
        let canceller = EchoCanceller(taps: taps, mu: mu)
        let d0 = canceller.estimateDelay(mic: mic, reference: system)
        print(String(format: "Loaded %.1fs stereo. Estimated echo delay = %d samples (%.1f ms).",
                     Double(n) / 16_000, d0, Double(d0) / 16.0))
        print(String(format: "Running EchoCanceller (taps=%d mu=%.2f)…", taps, mu))
        let start = Date()
        let cleaned = canceller.process(mic: mic, reference: system)
        print(String(format: "  processed in %.1fs", Date().timeIntervalSince(start)))

        // Metrics over 200 ms windows. ERLE is only meaningful on ECHO-DOMINATED windows
        // (far-end active AND the mic is a delayed copy of the reference); double-talk and
        // near-only windows are excluded because there the output is *supposed* to keep the
        // local voice.
        let win = 3200, act: Float = 0.01
        func rms(_ x: ArraySlice<Float>) -> Float {
            x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
        }
        // Correlation of mic vs reference at the estimated delay, over a window.
        func echoCorr(_ t: Int) -> Float {
            var dot: Float = 0, em: Float = 0, er: Float = 0
            var i = t
            while i < t + win {
                let mi = mic[i]
                let ri = (i - d0) >= 0 ? system[i - d0] : 0
                dot += mi * ri; em += mi * mi; er += ri * ri
                i += 1
            }
            return (em > 1e-9 && er > 1e-9) ? dot / (em.squareRoot() * er.squareRoot()) : 0
        }
        var echoIn: Float = 0, echoOut: Float = 0, echoWins = 0
        var erleSum: Float = 0
        var nearMicPow: Float = 0, nearOutPow: Float = 0     // near-only (voice preservation)
        var t = 0
        while t + win <= n {
            let mr = rms(mic[t..<t+win]), sr = rms(system[t..<t+win])
            let inE = mic[t..<t+win].reduce(Float(0)) { $0 + $1 * $1 }
            let outE = cleaned[t..<t+win].reduce(Float(0)) { $0 + $1 * $1 }
            if sr > act, abs(echoCorr(t)) > 0.30, mr < 3 * sr {   // echo-dominated
                echoIn += inE; echoOut += outE; echoWins += 1
                if inE > 0, outE > 0 { erleSum += 10 * log10(inE / outE) }
            } else if mr > 2 * act, sr < act {                   // near-only → untouched
                nearMicPow += inE; nearOutPow += outE
            }
            t += win
        }
        if echoOut > 0 {
            print(String(format: "ERLE on echo windows = %.1f dB aggregate, %.1f dB mean/window (n=%d)  [higher=more echo removed]",
                         10 * log10(echoIn / echoOut), erleSum / Float(max(echoWins, 1)), echoWins))
        } else {
            print("No echo-dominated windows found to measure.")
        }
        if nearMicPow > 0 {
            print(String(format: "Near-end voice retention = %.1f dB (0 = perfectly preserved)",
                         10 * log10(nearOutPow / nearMicPow)))
        }
        print("  ✅ AEC ran." )
        exit(0)
    } catch {
        print("aec failed: \(error)")
        exit(1)
    }

default:
    print("unknown mode \(mode)")
    exit(2)
}
