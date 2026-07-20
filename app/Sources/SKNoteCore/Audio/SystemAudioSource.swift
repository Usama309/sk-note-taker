import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Synchronization

/// Captures ALL system audio output (the remote side of a meeting) via a Core Audio process
/// tap wrapped in a private aggregate device — the modern, audio-only alternative to
/// ScreenCaptureKit (no screen-recording permission, no purple indicator).
///
/// Requires the "System Audio Recording Only" TCC grant (NSAudioCaptureUsageDescription);
/// the prompt fires on first IO start and only for signed binaries.
///
/// RESILIENCE: real meetings showed the tap going silent for the rest of the call after the
/// meeting app fully engages its audio engine (~15–25 s in), through several distinct
/// mechanisms. The chain therefore rebuilds itself when ANY of these fire:
///   1. The default output device changes (app switched output).
///   2. The bound output device's nominal sample rate or stream configuration changes
///      (VPIO engagement reconfigures the built-in speakers, e.g. 48 kHz → 24 kHz — the tap
///      keeps clocking but its stream is stale).
///   3. The IOProc stops firing (aggregate died outright).
///   4. The IOProc keeps firing but delivers ONLY silence while the output device reports it
///      is actively rendering for some client — audio is audibly playing yet the tap hears
///      nothing, which is exactly the observed mid-meeting death. Rate-limited so genuine
///      quiet moments don't cause rebuild churn.
///
/// The output stream and session clock are stable across rebuilds, so downstream sees one
/// continuous system channel. Every event is appended to Application Support/SKNoteTaker/
/// tap.log so real-meeting failures are diagnosable after the fact.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let clock: SessionClock
    private let ioQueue = DispatchQueue(label: "sk.notetaker.systemtap")
    /// Serialises build / teardown / rebuild so device-change and watchdog can't race.
    private let ctlQueue = DispatchQueue(label: "sk.notetaker.systemtap.ctl")
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let resampler = AudioResampler()
    private let debug = ProcessInfo.processInfo.environment["SKNOTE_DEBUG"] == "1"

    // Current chain (guarded by ctlQueue).
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var running = false

    /// Uptime (ns) of the last IOProc callback — liveness of the aggregate itself.
    private let lastCallbackNanos = Mutex<UInt64>(0)
    /// Uptime (ns) of the last callback whose tap buffer carried any NONZERO sample —
    /// liveness of the *audio*, not just the clock.
    private let lastAudioNanos = Mutex<UInt64>(0)
    private var watchdog: DispatchSourceTimer?
    private var defaultOutputListenerInstalled = false
    private var deviceConfigListenerDevice = AudioObjectID(kAudioObjectUnknown)
    /// Rate limit for silence-triggered rebuilds (uptime ns of the last one).
    private var lastSilenceRebuildNanos: UInt64 = 0
    /// Uptime (ns) of the last chain (re)build — drives the proactive periodic refresh.
    private var lastBuildNanos: UInt64 = 0

    public init(clock: SessionClock) {
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }
        // SKNOTE_NO_HEAL=1 disables all self-healing, reproducing the pre-fix behavior
        // (used by the self-test to A/B the resilience fix).
        let heal = ProcessInfo.processInfo.environment["SKNOTE_NO_HEAL"] != "1"
        try ctlQueue.sync {
            SKLog.info(.capture, "start (heal=\(heal))")
            try buildChain()
            if heal {
                installDefaultOutputListener()
                startWatchdog()
            }
            running = true
        }
        return stream
    }

    public func stop() async {
        ctlQueue.sync {
            running = false
            stopWatchdog()
            removeDefaultOutputListener()
            removeDeviceConfigListener()
            teardownChain()
            SKLog.info(.capture, "stop")
        }
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
    }

    // MARK: - Chain build / teardown (ctlQueue only)

    private func buildChain() throws {
        // 1. Global tap: everything except an empty exclusion list = all system audio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            SKLog.info(.capture, "build FAILED: process tap err=\(err)")
            throw AudioSourceError.deviceUnavailable("process tap (\(err)) — check System Audio Recording permission")
        }

        // 2. Aggregate device: real default output as main sub-device + our tap.
        let (outputUID, outputID) = try Self.defaultOutputDevice()
        outputDeviceID = outputID
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SK Note Taker Tap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapDriftCompensationKey as String: true,
                 kAudioSubTapUIDKey as String: description.uuid.uuidString]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            cleanupTap()
            SKLog.info(.capture, "build FAILED: aggregate err=\(err)")
            throw AudioSourceError.deviceUnavailable("aggregate device (\(err))")
        }

        // 3. Tap stream format.
        guard let tapFormat = Self.tapStreamFormat(tapID: tapID) else {
            cleanupAll()
            SKLog.info(.capture, "build FAILED: tap format unreadable")
            throw AudioSourceError.deviceUnavailable("tap format unreadable")
        }
        let asbd = tapFormat.streamDescription.pointee
        SKLog.info(.capture, String(format: "built: output=%@ (id %u) tap rate=%.0f ch=%u",
                          outputUID, outputID, asbd.mSampleRate, asbd.mChannelsPerFrame))

        // Watch the bound output device for reconfiguration (sample-rate / stream changes).
        installDeviceConfigListener(on: outputID)

        // 4. IOProc on the aggregate — must pass a real queue (nil silently fails on macOS 26).
        let clock = self.clock
        let resampler = self.resampler
        let debug = self.debug
        var loggedBuffers = false
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [self] _, inInputData, _, _, _ in
            // Liveness: stamp every callback (even silent ones) so the watchdog knows the
            // aggregate is alive.
            let now = DispatchTime.now().uptimeNanoseconds
            lastCallbackNanos.withLock { $0 = now }
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            if debug && !loggedBuffers {
                loggedBuffers = true
                var desc = "ioproc buffers=\(abl.count):"
                for b in abl { desc += " [ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)]" }
                SKLog.info(.capture, desc)
            }
            // The aggregate exposes the physical output device's streams AND the tap's
            // stream. Pick the buffer matching the tap format's channel count (the last
            // such buffer — device streams come first).
            let tapChannels = tapFormat.streamDescription.pointee.mChannelsPerFrame
            var tapBuffer: AudioBuffer?
            for buf in abl where buf.mNumberChannels == tapChannels && buf.mDataByteSize > 0 {
                tapBuffer = buf
            }
            guard let buf = tapBuffer, let data = buf.mData else { return }
            let frameCount = AVAudioFrameCount(
                buf.mDataByteSize / (tapFormat.streamDescription.pointee.mBytesPerFrame))
            guard frameCount > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount)
            else { return }
            pcm.frameLength = frameCount
            memcpy(pcm.audioBufferList.pointee.mBuffers.mData, data, Int(buf.mDataByteSize))
            let samples = resampler.resample(pcm)
            guard !samples.isEmpty else { return }
            // A deaf tap still emits a near-zero noise floor (RMS ~3e-5), NOT exact zeros, so
            // "any nonzero sample" wrongly reads as live. Require real energy (RMS > ~1e-3).
            var energy: Float = 0
            for s in samples { energy += s * s }
            if (energy / Float(samples.count)).squareRoot() > 0.001 {
                lastAudioNanos.withLock { $0 = now }
            }
            let duration = Double(samples.count) / AudioResampler.targetRate
            let start = clock.advance(channel: .system, by: duration)
            state.withLock { $0 }?.yield(
                AudioChunk(channel: .system, samples: samples, startTime: start))
        }
        guard err == noErr, procID != nil else {
            cleanupAll()
            SKLog.info(.capture, "build FAILED: ioproc err=\(err)")
            throw AudioSourceError.deviceUnavailable("IOProc (\(err))")
        }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            cleanupAll()
            SKLog.info(.capture, "build FAILED: start err=\(err)")
            throw AudioSourceError.permissionDenied("system audio recording (\(err))")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lastCallbackNanos.withLock { $0 = now }
        lastAudioNanos.withLock { $0 = now }   // grace period before silence logic can fire
        lastBuildNanos = now
    }

    private func teardownChain() {
        removeDeviceConfigListener()
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        cleanupAll()
    }

    /// Tear down and rebuild the chain against the CURRENT default output device. Called from
    /// the listeners and the watchdog; serialised on ctlQueue.
    private func rebuild(reason: String) {
        guard running else { return }
        SKLog.info(.capture, "REBUILD: \(reason)")
        teardownChain()
        do {
            try buildChain()
        } catch {
            SKLog.info(.capture, "rebuild FAILED (\(reason)): \(error)")
            SKLog.error(.tapRebuildFailed, .capture,
                        "Process-tap rebuild failed (\(reason))", error: error)
        }
    }

    // MARK: - Watchdog + listeners

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: ctlQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let lastCB = self.lastCallbackNanos.withLock { $0 }
            // 1. Aggregate stopped clocking entirely.
            if lastCB != 0, now > lastCB, (now - lastCB) > 2_500_000_000 {
                self.rebuild(reason: "ioproc stalled")
                return
            }
            // 2. Aggregate clocks but the tap hears NOTHING — the observed mid-meeting death,
            //    where a call app engages its audio path and the global tap goes deaf while
            //    callbacks keep firing. We do NOT gate this on the output device reporting
            //    "running" (that guard was false in the real failure and blocked the rebuild).
            //    A fresh tap re-attaches and hears audio again. Retried every ~2 s: during a
            //    genuinely quiet stretch a rebuild is harmless (nothing to lose); during
            //    deafness it resurrects the channel.
            let lastAudio = self.lastAudioNanos.withLock { $0 }
            let silentFor = (lastAudio != 0 && now > lastAudio) ? now - lastAudio : 0
            if silentFor > 2_000_000_000,
               now - self.lastSilenceRebuildNanos > 2_000_000_000 {
                self.lastSilenceRebuildNanos = now
                self.rebuild(reason: "tap silent \(silentFor / 1_000_000_000)s — refreshing")
                return
            }
            // 3. Proactive backstop: the tap has been observed to go deaf ~15–20 s into a call
            //    with the IOProc still clocking and the device unchanged, so no reactive signal
            //    fires. A fresh tap works, so refresh the chain at least every 10 s regardless.
            //    Rebuild is ~15 ms and only runs when the channel has been quiet for ≥300 ms,
            //    so it never clips mid-word during continuous remote speech.
            if self.lastBuildNanos != 0, now > self.lastBuildNanos,
               (now - self.lastBuildNanos) > 10_000_000_000,
               silentFor > 300_000_000 {
                self.rebuild(reason: "proactive refresh")
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func installDefaultOutputListener() {
        guard !defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ctlQueue) { [weak self] _, _ in
            self?.rebuild(reason: "default output device changed")
        }
        defaultOutputListenerInstalled = (status == noErr)
    }

    private func removeDefaultOutputListener() {
        guard defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, ctlQueue) { _, _ in }
        defaultOutputListenerInstalled = false
    }

    /// Rebuild when the bound output device reconfigures under us: VPIO engagement flips the
    /// built-in speakers' nominal sample rate / stream configuration, leaving the tap stale.
    private func installDeviceConfigListener(on deviceID: AudioObjectID) {
        removeDeviceConfigListener()
        for selector in [kAudioDevicePropertyNominalSampleRate,
                         kAudioDevicePropertyStreamConfiguration] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectAddPropertyListenerBlock(deviceID, &address, ctlQueue) {
                [weak self] _, _ in
                self?.rebuild(reason: "output device reconfigured (selector \(selector))")
            }
        }
        deviceConfigListenerDevice = deviceID
    }

    private func removeDeviceConfigListener() {
        guard deviceConfigListenerDevice != kAudioObjectUnknown else { return }
        for selector in [kAudioDevicePropertyNominalSampleRate,
                         kAudioDevicePropertyStreamConfiguration] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(
                deviceConfigListenerDevice, &address, ctlQueue) { _, _ in }
        }
        deviceConfigListenerDevice = kAudioObjectUnknown
    }

    // MARK: - Core Audio plumbing

    private func cleanupAll() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        cleanupTap()
    }

    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func defaultOutputDevice() throws -> (uid: String, id: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioSourceError.deviceUnavailable("default output device (\(err))")
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else {
            throw AudioSourceError.deviceUnavailable("output device UID (\(err))")
        }
        return (uid as String, deviceID)
    }

    private static func tapStreamFormat(tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
