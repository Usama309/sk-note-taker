import Foundation
import CoreAudio
import AVFoundation
import SKNoteCore

/// Hidden diagnostic entry points, run from the signed app bundle so they inherit the app's
/// System-Audio-Recording TCC grant (the standalone CLI tool does not have it).
///
/// Usage:
///   SK Note Taker.app/Contents/MacOS/SKNoteTaker --selftest-systime <seconds> [--switch]
///
/// `--switch` reproduces the real failure trigger (a meeting app switching the default output
/// device mid-call) by flipping the default output device to another device and back while
/// capturing, then reports whether the system tap kept delivering audio across the change.
/// Thread-safe done flag for pumping the run loop in the meeting self-test.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum SelfTest {

    static func run(_ args: [String]) -> Bool {
        // Proves the logging pipeline end to end in the real app: writes one entry of each
        // level plus representative errors, then prints where they landed. Run this to
        // confirm the Desktop logs are working before relying on them.
        if args.contains("--selftest-logging") {
            print("Log folder: \(SKLog.directory.path)")
            SKLog.beginMeeting(title: "Logging self-test", id: UUID())
            SKLog.info(.app, "informational entry — should appear ONLY in the full log")
            SKLog.warn(.mic, "warning entry — full log only")
            SKLog.error(.captureStalled, .capture,
                        "sample: system audio stopped arriving mid-meeting")
            SKLog.error(.tapStartFailed, .capture, "sample: with an underlying OS error",
                        error: NSError(domain: "com.apple.coreaudio", code: -10877,
                                       userInfo: [NSLocalizedDescriptionKey: "device not found"]))
            SKLog.error(.aiRequestFailed, .ai, "sample: Claude request failed",
                        error: NSError(domain: "SKNoteTaker", code: 42,
                                       userInfo: [NSLocalizedDescriptionKey: "usage limit reached"]))
            SKLog.endMeeting(title: "Logging self-test", durationSec: 0)
            print("Wrote 3 sample errors. Check:")
            print("  \(SKLog.fullLogURL.path)")
            print("  \(SKLog.errorLogURL.path)")
            return true
        }
        // Runs the Zoom reader against the currently-running Zoom under the app's Accessibility
        // grant and prints the interpreter's roster + active-speaker read (plus the full tree to
        // the Desktop log). Lets us confirm roster extraction against the REAL live Zoom AX tree.
        if args.contains("--selftest-zoomdump") {
            let reader = ZoomSpeakerReader()
            let dump = reader.dumpTree()
            let url = SKLog.directory.appendingPathComponent("zoom-ax-tree.txt")
            try? FileManager.default.createDirectory(at: SKLog.directory, withIntermediateDirectories: true)
            try? dump.write(to: url, atomically: true, encoding: .utf8)
            let tail = dump.split(separator: "\n").suffix(3).joined(separator: "\n")
            print("Zoom running: \(ZoomSpeakerReader.zoomIsRunning())")
            print(tail)
            print("Full tree: \(url.path)")
            return true
        }
        if let i = args.firstIndex(of: "--selftest-screenrec") {
            let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 4
            let appIdx = args.firstIndex(of: "--app")
            let bundleId = appIdx.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let done = Flag()
            Task { await runScreenRec(seconds: seconds, appBundleId: bundleId); done.set() }
            while !done.get() {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-meeting") {
            let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 40
            // runMeeting is @MainActor, so we must NOT block the main thread — pump the main
            // run loop until it finishes instead of waiting on a semaphore (which deadlocks).
            let done = Flag()
            Task { @MainActor in await runMeeting(seconds: seconds); done.set() }
            while !done.get() {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            return true
        }
        guard let i = args.firstIndex(of: "--selftest-systime") else { return false }
        let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 30
        let doSwitch = args.contains("--switch")
        let withMic = args.contains("--with-mic")
        let sem = DispatchSemaphore(value: 0)
        Task {
            await runSysTime(seconds: seconds, doSwitch: doSwitch, withMic: withMic)
            sem.signal()
        }
        sem.wait()
        return true
    }

    /// Runs a REAL MeetingSession (full pipeline: mic + system tap + transcription + diarizer
    /// + recorder) for `seconds`, then reports the recorded system channel's per-second RMS.
    /// This is the faithful reproduction of a user meeting — the tap death only appears with
    /// the whole pipeline running. Writes the report to Application Support/SKNoteTaker/
    /// selftest.log and leaves the recording for offline analysis.
    @MainActor
    static func runMeeting(seconds: Double) async {
        print("SELFTEST full meeting for \(Int(seconds))s")
        let store = MeetingStore()
        let session = await MeetingSession.live(title: "SELFTEST meeting", store: store)
        await session.start()
        if case .failed(let why) = session.phase { print("start failed: \(why)"); return }
        let id = session.meeting.id
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        await session.finish()
        let url = await store.recordingURL(for: id)
        print("recording: \(url.path)")

        // Per-second RMS of the recorded system (right) channel.
        var report = "meeting recording: \(url.lastPathComponent)\n"
        if let (_, system) = try? RecordingLoader.channels(at: url) {
            let sr = 16_000
            var live = 0, total = 0
            report += "sec :  sysR RMS\n"
            var sec = 0
            while (sec + 1) * sr <= system.count {
                let win = Array(system[sec*sr ..< (sec+1)*sr])
                let rms = (win.reduce(Float(0)) { $0 + $1 * $1 } / Float(win.count)).squareRoot()
                report += String(format: " %3d : %.5f\n", sec, rms)
                total += 1; if rms > 0.0008 { live += 1 }
                sec += 1
            }
            report += "\nsystem channel ALIVE: \(live)/\(total)s\n"
        } else {
            report += "(could not load recording channels)\n"
        }
        print(report)
        let out = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SKNoteTaker/selftest.log")
        try? report.write(to: out, atomically: true, encoding: .utf8)
    }

    /// Records the screen for `seconds` via ScreenVideoRecorder and reports whether a valid,
    /// non-empty, playable .mov came out. Runs under the app's Screen Recording grant.
    static func runScreenRec(seconds: Double, appBundleId: String? = nil) async {
        print("SELFTEST screen recording for \(Int(seconds))s (app: \(appBundleId ?? "full display"))")
        print("screen recording perm: \(Permission.screenRecordingStatus().rawValue)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-selftest-screen.mov")
        let rec = ScreenVideoRecorder(outputURL: url)
        var report = ""
        do {
            try await rec.start(appBundleId: appBundleId)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            let ok = await rec.stop()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber)?.intValue ?? 0
            var dur = 0.0
            var dims = "?"
            if FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                dur = (try? await asset.load(.duration))?.seconds ?? 0
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize) {
                    dims = "\(Int(size.width))x\(Int(size.height))"
                }
            }
            let pass = ok && bytes > 10_000 && dur > 0.5
            report = "screen rec: ok=\(ok) bytes=\(bytes) duration=\(String(format: "%.2f", dur))s dims=\(dims)\n"
                + (pass ? "✅ screen recording works" : "❌ screen recording FAILED")
        } catch {
            report = "❌ start failed: \(error)"
        }
        print(report)
        let out = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SKNoteTaker/selftest.log")
        try? report.write(to: out, atomically: true, encoding: .utf8)
    }

    static func runSysTime(seconds: Double, doSwitch: Bool, withMic: Bool = false) async {
        print("SELFTEST system-audio capture for \(Int(seconds))s (switch=\(doSwitch) withMic=\(withMic))")

        // Faithful-meeting mode: start the mic source concurrently (as MeetingSession does),
        // because the tap death is triggered by the app's own concurrent mic capture, not by
        // the call app alone. Drained and discarded; we only measure the system channel.
        var micSource: (any SKNoteCore.AudioSource)?
        var micDrain: Task<Void, Never>?
        let outputs = AudioDevices.outputDevices()
        print("Output devices:")
        for d in outputs { print("  \(d.id)  \(d.name)  [\(d.uid)]") }
        let original = AudioDevices.defaultOutput()
        print("Default output: \(original.map { "\($0)" } ?? "unknown")")

        let clock = SessionClock()
        // Production path: ScreenCaptureKit with process-tap fallback. `--tap` forces the old
        // process tap so the two can be compared head to head.
        let src: any SKNoteCore.AudioSource = CommandLine.arguments.contains("--tap")
            ? SystemAudioSource(clock: clock)
            : SystemAudioCapture(clock: clock)
        print("system source: \(type(of: src))")
        print("screen recording: \(Permission.screenRecordingStatus().rawValue)")

        if withMic {
            let mic = await MicSourcePicker.pick(clock: clock)
            print("mic source: \(type(of: mic))")
            do {
                let micStream = try await mic.start()
                micSource = mic
                micDrain = Task { for await _ in micStream {} }
            } catch {
                print("mic start failed: \(error)")
            }
        }

        final class Buckets: @unchecked Sendable {
            let lock = NSLock()
            var chunks: [Int: Int] = [:]
            var energy: [Int: Float] = [:]
            var samples: [Int: Int] = [:]
            func add(_ t: Double, _ s: [Float]) {
                let sec = Int(t)
                let e = s.reduce(Float(0)) { $0 + $1 * $1 }
                lock.lock()
                chunks[sec, default: 0] += 1
                energy[sec, default: 0] += e
                samples[sec, default: 0] += s.count
                lock.unlock()
            }
        }
        let b = Buckets()

        do {
            let stream = try await src.start()
            let collector = Task { for await c in stream { b.add(c.startTime, c.samples) } }

            // Schedule a default-output-device switch to reproduce the meeting-app trigger.
            if doSwitch, let other = outputs.first(where: { $0.id != (original ?? 0) }) {
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    print(">>> t≈8s: switching default output → \(other.name)")
                    AudioDevices.setDefaultOutput(other.id)
                    try? await Task.sleep(for: .seconds(8))
                    if let original { print(">>> t≈16s: switching default output back"); AudioDevices.setDefaultOutput(original) }
                }
            }

            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            await src.stop()
            _ = await collector.value
        } catch {
            print("SELFTEST start failed: \(error)")
            if let original { AudioDevices.setDefaultOutput(original) }
            await micSource?.stop(); micDrain?.cancel()
            return
        }
        await micSource?.stop(); micDrain?.cancel()
        if let original { AudioDevices.setDefaultOutput(original) }

        // Results go to a file too: launched via `open` (required for correct TCC
        // attribution of the system-audio grant) stdout is not visible to the caller.
        var lines: [String] = ["second : chunks   RMS"]
        var alive = 0, dead = 0, audible = 0
        for sec in 0..<Int(seconds) {
            let c = b.chunks[sec] ?? 0
            let n = max(b.samples[sec] ?? 0, 1)
            let rms = ((b.energy[sec] ?? 0) / Float(n)).squareRoot()
            lines.append(String(format: "  %3d  : %4d   %.5f", sec, c, rms))
            if sec >= 2 && sec < Int(seconds) - 1 {
                if c > 0 { alive += 1 } else { dead += 1 }
                if rms > 0.0005 { audible += 1 }
            }
        }
        lines.append("")
        lines.append("seconds WITH callbacks: \(alive)   WITHOUT: \(dead)   with AUDIBLE audio: \(audible)")
        lines.append(dead == 0
              ? "✅ tap callbacks continuous"
              : "❌ tap callbacks stopped for \(dead)s")
        let report = lines.joined(separator: "\n")
        print(report)
        let out = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SKNoteTaker/selftest.log")
        try? report.write(to: out, atomically: true, encoding: .utf8)
    }
}

/// Minimal Core Audio output-device enumeration + default-output control for the self-test.
enum AudioDevices {
    struct Device { let id: AudioObjectID; let name: String; let uid: String }

    static func defaultOutput() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = id
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &dev)
    }

    static func outputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Output device = has output streams.
            var sa = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ssize) == noErr, ssize > 0
            else { return nil }
            return Device(id: id, name: stringProp(id, kAudioObjectPropertyName) ?? "?",
                          uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "?")
        }
    }

    private static func stringProp(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var str: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &str) { p in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p)
        }
        return err == noErr ? (str as String) : nil
    }
}
