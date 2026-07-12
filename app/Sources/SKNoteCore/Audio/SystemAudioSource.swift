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
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .system

    private let clock: SessionClock
    private let ioQueue = DispatchQueue(label: "sk.notetaker.systemtap")
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init(clock: SessionClock) {
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        // 1. Global tap: everything except an empty exclusion list = all system audio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            throw AudioSourceError.deviceUnavailable("process tap (\(err)) — check System Audio Recording permission")
        }

        // 2. Aggregate device: real default output as main sub-device + our tap.
        let outputUID = try Self.defaultOutputDeviceUID()
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
            throw AudioSourceError.deviceUnavailable("aggregate device (\(err))")
        }

        // 3. Tap stream format.
        guard let tapFormat = Self.tapStreamFormat(tapID: tapID) else {
            cleanupAll()
            throw AudioSourceError.deviceUnavailable("tap format unreadable")
        }
        let debug = ProcessInfo.processInfo.environment["SKNOTE_DEBUG"] == "1"
        if debug {
            let asbd = tapFormat.streamDescription.pointee
            let line = "SKNOTE_DEBUG tapFormat rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) " +
                "fmt=\(asbd.mFormatID) flags=\(String(asbd.mFormatFlags, radix: 16)) " +
                "bytesPerFrame=\(asbd.mBytesPerFrame) interleaved=\(tapFormat.isInterleaved)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }

        // 4. IOProc on the aggregate — must pass a real queue (nil silently fails on macOS 26).
        let resampler = AudioResampler()
        let clock = self.clock
        var loggedBuffers = false
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [self] _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            if debug && !loggedBuffers {
                loggedBuffers = true
                var desc = "SKNOTE_DEBUG ioproc buffers=\(abl.count):"
                for b in abl { desc += " [ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)]" }
                FileHandle.standardError.write(Data((desc + "\n").utf8))
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
            let duration = Double(samples.count) / AudioResampler.targetRate
            let start = clock.advance(channel: .system, by: duration)
            state.withLock { $0 }?.yield(
                AudioChunk(channel: .system, samples: samples, startTime: start))
        }
        guard err == noErr, procID != nil else {
            cleanupAll()
            throw AudioSourceError.deviceUnavailable("IOProc (\(err))")
        }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            cleanupAll()
            throw AudioSourceError.permissionDenied("system audio recording (\(err))")
        }
        return stream
    }

    public func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        cleanupAll()
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
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

    private static func defaultOutputDeviceUID() throws -> String {
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
        return uid as String
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
