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

    /// Uptime (ns) of the last audio callback — liveness of the stream itself.
    private let lastCallbackNanos = Mutex<UInt64>(0)
    private let audioCallbacks = Mutex<Int>(0)
    private let nonSilentCallbacks = Mutex<Int>(0)
    private var watchdog: DispatchSourceTimer?
    private var lastHeartbeatNanos: UInt64 = 0
    private var restarts = 0

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
            throw AudioSourceError.permissionDenied(
                "screen recording (required to capture system audio)")
        }

        // Any display works — audio is captured from the whole system graph, not the pixels.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AudioSourceError.deviceUnavailable("no display available for ScreenCaptureKit")
        }
        try await startStream()

        let (out, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }
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
            throw AudioSourceError.deviceUnavailable("no display available for ScreenCaptureKit")
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
        lastHeartbeatNanos = now
        TapLog.log("system capture: ScreenCaptureKit started (display \(display.displayID))")
    }

    public func stop() async {
        ctlQueue.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
        }
        await teardownStream()
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
        let a = audioCallbacks.withLock { $0 }, ns = nonSilentCallbacks.withLock { $0 }
        TapLog.log("system capture: ScreenCaptureKit stopped "
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
        TapLog.log("ScreenCaptureKit RESTART (\(reason))")
        await teardownStream()
        do {
            try await startStream()
        } catch {
            TapLog.log("ScreenCaptureKit restart failed: \(error.localizedDescription)")
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: ctlQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let last = self.lastCallbackNanos.withLock { $0 }

            // Heartbeat every 30 s, so a silent failure is diagnosable after the fact.
            if now &- self.lastHeartbeatNanos > 30_000_000_000 {
                self.lastHeartbeatNanos = now
                let a = self.audioCallbacks.withLock { $0 }
                let ns = self.nonSilentCallbacks.withLock { $0 }
                let quiet = (now &- last) / 1_000_000
                TapLog.log("SCK heartbeat: audio callbacks=\(a), with sound=\(ns), "
                           + "last callback \(quiet) ms ago")
            }

            // A live SCStream delivers audio continuously, even over silence. If callbacks
            // stop entirely the stream has stalled — restart it.
            if last != 0, now > last, (now &- last) > 3_000_000_000 {
                Task { await self.restart(reason: "no audio callbacks for 3s") }
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
            nonSilentCallbacks.withLock { $0 += 1 }
        }

        let duration = Double(samples.count) / AudioResampler.targetRate
        let start = clock.advance(channel: .system, by: duration)
        state.withLock { $0 }?.yield(
            AudioChunk(channel: .system, samples: samples, startTime: start))
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        TapLog.log("ScreenCaptureKit stream stopped with error: \(error.localizedDescription)")
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
            TapLog.log("ScreenCaptureKit unavailable (\(error.localizedDescription)) — "
                       + "falling back to Core Audio process tap")
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
