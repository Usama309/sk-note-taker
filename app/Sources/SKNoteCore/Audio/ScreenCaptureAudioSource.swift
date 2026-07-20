import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import Synchronization

/// Captures system audio (the remote side of a meeting) via ScreenCaptureKit.
///
/// WHY THIS REPLACED THE PROCESS TAP: the Core Audio process-tap + aggregate-device approach
/// binds the capture chain to whichever output device was default when it was built. A call
/// app engaging its audio engine (Zoom installs its own virtual device) leaves the aggregate
/// pointing at a stale/idle device and its IOProc goes deaf — measured on five consecutive
/// real meetings, the system channel died 15–22 s in and never recovered, collapsing every
/// remote voice onto the microphone. ScreenCaptureKit taps the display's audio graph instead
/// of a specific device, so there is no device binding to go stale.
///
/// Audio-only: the stream is configured with a 2×2 video surface at a very low frame rate
/// (SCStream requires *some* video config) and we only register an audio output. Our own
/// output is excluded so the app can never record itself.
///
/// Requires the Screen Recording TCC grant.
public final class ScreenCaptureAudioSource: NSObject, AudioSource, SCStreamOutput,
                                             SCStreamDelegate, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let clock: SessionClock
    private let resampler = AudioResampler()
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let sampleQueue = DispatchQueue(label: "sk.notetaker.sck.audio")
    /// Video frames are captured but discarded; they get their own queue so a slow video
    /// callback can never delay audio delivery.
    private let videoQueue = DispatchQueue(label: "sk.notetaker.sck.video")
    /// Serialises start / stop / restart so the watchdog can't race the lifecycle.
    private let ctlQueue = DispatchQueue(label: "sk.notetaker.sck.ctl")
    private var stream: SCStream?
    private var running = false

    /// Uptime (ns) of the last audio callback — liveness of the STREAM (callbacks arriving).
    private let lastCallbackNanos = Mutex<UInt64>(0)
    /// Uptime (ns) of the last callback carrying real sound — liveness of the AUDIO. The
    /// stream can keep firing callbacks that carry only silence while it has quietly stopped
    /// capturing the actual system output (observed ~2 min into a real Zoom call).
    private let lastAudioNanos = Mutex<UInt64>(0)
    private let audioCallbacks = Mutex<Int>(0)
    private let nonSilentCallbacks = Mutex<Int>(0)
    private var watchdog: DispatchSourceTimer?
    private var lastHeartbeatNanos: UInt64 = 0
    private var lastSilenceRestartNanos: UInt64 = 0
    private var restarts = 0
    /// Keeps the display (and system) awake while capturing — SCK's display-bound audio
    /// capture stops delivering real audio if the display sleeps mid-meeting.
    private var sleepAssertion: NSObjectProtocol?

    public init(clock: SessionClock) {
        self.clock = clock
        super.init()
    }

    public static func permissionGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()   // fires the prompt / opens the pane once
            let err = AudioSourceError.permissionDenied(
                "screen recording (required to capture system audio)")
            SKLog.error(.captureScreenPermissionDenied, .capture,
                        "Screen Recording not granted — system audio cannot be captured via "
                        + "ScreenCaptureKit. Grant it in System Settings → Privacy & Security → "
                        + "Screen & System Audio Recording.", error: err)
            throw err
        }
        do {
            try await startStream()
        } catch {
            SKLog.error(.captureStartFailed, .capture,
                        "ScreenCaptureKit failed to start", error: error)
            throw error
        }

        let (out, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }
        // Hold the display and system awake for the whole capture. SCK captures the display's
        // audio graph, which stops delivering real audio when the display sleeps — a strong
        // suspect for capture dying ~2 min into a call while the user stepped away.
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "SK Note Taker system-audio capture")
        ctlQueue.sync {
            running = true
            startWatchdog()
        }
        return out
    }

    /// Builds and starts the SCStream. Also used by the watchdog to restart a stalled stream.
    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            let err = AudioSourceError.deviceUnavailable("no display available for ScreenCaptureKit")
            SKLog.error(.captureNoDisplay, .capture, "No display available to attach the audio stream to", error: err)
            throw err
        }
        let filter = SCContentFilter(display: display, excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true      // never record ourselves
        // SCStream always captures video, even when we only want audio. Keep the surface
        // tiny and slow, but we MUST still consume the frames (see the .screen output
        // registered below): with video enqueued and never dequeued the queue fills and the
        // whole stream stalls, taking audio down with it — silently, with no error and no
        // didStopWithError. That is what killed capture ~101 s into a real meeting.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4)   // 4 fps, drained below
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream

        let now = DispatchTime.now().uptimeNanoseconds
        lastCallbackNanos.withLock { $0 = now }
        lastAudioNanos.withLock { $0 = now }   // grace period before the silence-restart can fire
        lastHeartbeatNanos = now
        lastSilenceRestartNanos = now
        SKLog.info(.capture, "system capture: ScreenCaptureKit started (display \(display.displayID))")
    }

    public func stop() async {
        ctlQueue.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
        }
        await teardownStream()
        if let sleepAssertion {
            ProcessInfo.processInfo.endActivity(sleepAssertion)
            self.sleepAssertion = nil
        }
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
        let a = audioCallbacks.withLock { $0 }, ns = nonSilentCallbacks.withLock { $0 }
        SKLog.info(.capture, "system capture: ScreenCaptureKit stopped "
                   + "(audio callbacks=\(a), with sound=\(ns), restarts=\(restarts))")
    }

    private func teardownStream() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        try? s.removeStreamOutput(self, type: .audio)
        try? s.removeStreamOutput(self, type: .screen)
        stream = nil
    }

    /// Restarts a stalled stream, keeping the same output continuation and session clock so
    /// downstream sees one continuous channel.
    private func restart(reason: String) async {
        guard ctlQueue.sync(execute: { running }) else { return }
        restarts += 1
        // A restart is a RECOVERY, not a hard failure (capture continues), so it's a warning,
        // not an error. A genuine total failure shows up as repeated restarts plus a silent
        // recording — visible in the heartbeat's restart count and "last SOUND ms ago".
        SKLog.warn(.capture,
                   "ScreenCaptureKit restart #\(restarts) — \(reason)")
        await teardownStream()
        do {
            try await startStream()
        } catch {
            SKLog.error(.captureRestartFailed, .capture,
                        "ScreenCaptureKit restart failed — system audio will stay silent until the "
                        + "next attempt", error: error)
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: ctlQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let last = self.lastCallbackNanos.withLock { $0 }

            let lastAudio = self.lastAudioNanos.withLock { $0 }
            let sinceAudioMs = lastAudio == 0 ? 0 : (now &- lastAudio) / 1_000_000

            // Heartbeat every 30 s, so a silent failure is diagnosable after the fact.
            if now &- self.lastHeartbeatNanos > 30_000_000_000 {
                self.lastHeartbeatNanos = now
                let a = self.audioCallbacks.withLock { $0 }
                let ns = self.nonSilentCallbacks.withLock { $0 }
                let quiet = (now &- last) / 1_000_000
                SKLog.info(.capture, "SCK heartbeat: audio callbacks=\(a), with sound=\(ns), "
                           + "last callback \(quiet) ms ago, last SOUND \(sinceAudioMs) ms ago")
            }

            // 1. Callbacks stopped entirely — the stream stalled.
            if last != 0, now > last, (now &- last) > 3_000_000_000 {
                Task { await self.restart(reason: "no audio callbacks for 3s") }
                return
            }
            // 2. Callbacks keep firing but carry only silence for 20 s — the stream is alive
            //    yet no longer capturing the real system output (the observed mid-call death,
            //    where the remote kept talking but the system channel went empty). A fresh
            //    stream re-attaches to the current audio graph. Rate-limited; a restart during
            //    a genuinely quiet stretch is harmless (there is no audio to lose).
            if lastAudio != 0, now > lastAudio, (now &- lastAudio) > 20_000_000_000,
               now &- self.lastSilenceRestartNanos > 20_000_000_000 {
                self.lastSilenceRestartNanos = now
                Task { await self.restart(reason: "no captured sound for 20s while running") }
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        // Video frames exist only to keep the stream's queue draining — consume and discard.
        // Without this the queue fills and the entire stream (including audio) stalls.
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        lastCallbackNanos.withLock { $0 = nowNanos }
        audioCallbacks.withLock { $0 += 1 }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbdPointer = formatDescription.audioStreamBasicDescription.map({ $0 }) else {
            return
        }
        var asbd = asbdPointer
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        // Copy the sample buffer's audio into an AVAudioPCMBuffer we own, then resample to
        // the pipeline's 16 kHz mono.
        var samples: [Float] = []
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            samples = resampler.resample(pcm)
        }
        guard !samples.isEmpty else { return }
        var energy: Float = 0
        for s in samples { energy += s * s }
        if (energy / Float(samples.count)).squareRoot() > 0.001 {
            lastAudioNanos.withLock { $0 = nowNanos }
            nonSilentCallbacks.withLock { $0 += 1 }
        }

        let duration = Double(samples.count) / AudioResampler.targetRate
        let start = clock.advance(channel: .system, by: duration)
        state.withLock { $0 }?.yield(
            AudioChunk(channel: .system, samples: samples, startTime: start))
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        SKLog.error(.captureStreamError, .capture,
                    "ScreenCaptureKit stream stopped unexpectedly", error: error)
        Task { await self.restart(reason: "stream stopped with error") }
    }
}

/// System-audio capture with automatic fallback: ScreenCaptureKit first (device-independent,
/// survives a call app reconfiguring audio), and the Core Audio process tap only if SCK is
/// unavailable — e.g. Screen Recording not granted yet.
public final class SystemAudioCapture: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let clock: SessionClock
    private var active: (any AudioSource)?

    public init(clock: SessionClock) {
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let screen = ScreenCaptureAudioSource(clock: clock)
        do {
            let stream = try await screen.start()
            active = screen
            return stream
        } catch {
            SKLog.error(.captureFellBackToTap, .capture,
                        "ScreenCaptureKit unavailable — falling back to the Core Audio process "
                        + "tap, which is known to go deaf mid-meeting. Grant Screen Recording "
                        + "to use the reliable path.", error: error)
            let tap = SystemAudioSource(clock: clock)
            let stream = try await tap.start()
            active = tap
            return stream
        }
    }

    public func stop() async {
        await active?.stop()
        active = nil
    }
}
