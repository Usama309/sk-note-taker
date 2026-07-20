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
    private var stream: SCStream?

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
        let filter = SCContentFilter(display: display, excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true      // never record ourselves
        // Minimal video: SCStream needs a valid video config even when only audio is consumed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        let (out, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }
        TapLog.log("system capture: ScreenCaptureKit started (display \(display.displayID))")
        return out
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .audio)
        }
        stream = nil
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
        TapLog.log("system capture: ScreenCaptureKit stopped")
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
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
