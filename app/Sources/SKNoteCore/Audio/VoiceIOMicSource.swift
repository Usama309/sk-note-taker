import Foundation
import AVFoundation
import AudioToolbox
import Synchronization

/// Microphone capture through the raw AUVoiceIO (VoiceProcessingIO) audio unit.
///
/// WHY THIS EXISTS: while any process (WhatsApp, Teams, FaceTime…) has an active Apple
/// voice-processing session on the input device, macOS mutes every *raw* input client —
/// `MicAudioSource`'s AVAudioEngine tap receives bit-exact zero buffers for the whole call.
/// Voice-processing clients, however, keep receiving real mic audio. So during such calls we
/// capture through AUVoiceIO ourselves. We can't use AVAudioEngine's
/// `setVoiceProcessingEnabled` for this (input-only engines render silence — the v1 bug), so
/// this drives the audio unit directly: input callback + `AudioUnitRender` on element 1, with
/// a silent output render so the duplex unit actually runs.
///
/// CAUTION: an active VPIO session mutes *other* raw input clients system-wide. Only select
/// this source when the raw tap is already muted (see `MicSourcePicker`) — otherwise we would
/// silence a call app that captures raw with its own echo canceller (e.g. Zoom).
public final class VoiceIOMicSource: AudioSource, @unchecked Sendable {
    public let channel: AudioChannel = .mic

    private let clock: SessionClock
    private let resampler = AudioResampler()
    private let state = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let lastLevel = Mutex<Float>(0)

    private var unit: AudioUnit?
    private var format: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?
    /// Retained while the unit is running so the C callback's refCon stays valid.
    private var retainedSelf: Unmanaged<VoiceIOMicSource>?

    public init(clock: SessionClock) {
        self.clock = clock
    }

    /// 0…1 RMS level of the most recent mic chunk (for a UI meter).
    public var inputLevel: Float { lastLevel.withLock { $0 } }

    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await MicAudioSource.permissionGranted() else {
            throw AudioSourceError.permissionDenied("microphone")
        }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioSourceError.deviceUnavailable("AUVoiceIO component not found")
        }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let au = newUnit else {
            throw AudioSourceError.deviceUnavailable("AUVoiceIO instantiation failed")
        }
        unit = au

        // Enable input (element 1); output (element 0) is on by default.
        var one: UInt32 = 1
        var err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &one, 4)
        guard err == noErr else {
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("AUVoiceIO enable input failed (\(err))")
        }

        // Don't duck other audio (the user is listening to a call) — best effort, macOS 14+.
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: .init(false), mDuckingLevel: .min)
        _ = AudioUnitSetProperty(
            au, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
            kAudioUnitScope_Global, 0, &ducking,
            UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))

        // Use the unit's native input format (element 1, output scope).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &asbd, &size)
        guard err == noErr, asbd.mSampleRate > 0,
              let avFormat = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 16384) else {
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("no microphone input (AUVoiceIO format)")
        }
        format = avFormat
        renderBuffer = buffer

        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained

        var inputCB = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, _, frames, _ in
                let source = Unmanaged<VoiceIOMicSource>.fromOpaque(refCon).takeUnretainedValue()
                source.handleInput(flags: flags, timestamp: timestamp, frames: frames)
                return noErr
            },
            inputProcRefCon: retained.toOpaque())
        err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 1, &inputCB,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else {
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("AUVoiceIO input callback failed (\(err))")
        }

        // Silent output render — the duplex unit needs an output chain to deliver input.
        var renderCB = AURenderCallbackStruct(
            inputProc: { _, flags, _, _, _, ioData in
                if let ioData {
                    for buf in UnsafeMutableAudioBufferListPointer(ioData) {
                        if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                    }
                }
                flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                return noErr
            },
            inputProcRefCon: nil)
        err = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &renderCB,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else {
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("AUVoiceIO render callback failed (\(err))")
        }

        guard AudioUnitInitialize(au) == noErr else {
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("AUVoiceIO initialize failed")
        }
        guard AudioOutputUnitStart(au) == noErr else {
            AudioUnitUninitialize(au)
            cleanupUnit()
            throw AudioSourceError.deviceUnavailable("AUVoiceIO start failed")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        state.withLock { $0 = continuation }
        return stream
    }

    public func stop() async {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
        }
        cleanupUnit()
        state.withLock { cont in
            cont?.finish()
            cont = nil
        }
    }

    private func cleanupUnit() {
        if let au = unit {
            AudioComponentInstanceDispose(au)
            unit = nil
        }
        retainedSelf?.release()
        retainedSelf = nil
    }

    /// Runs on the audio I/O thread: pull the rendered input, resample, stamp, emit.
    private func handleInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             timestamp: UnsafePointer<AudioTimeStamp>,
                             frames: UInt32) {
        guard let au = unit, let buffer = renderBuffer,
              frames <= buffer.frameCapacity else { return }

        let abl = buffer.mutableAudioBufferList
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let bytesPerFrame = format?.streamDescription.pointee.mBytesPerFrame ?? 4
        for i in 0..<bufs.count {
            bufs[i].mDataByteSize = frames * bytesPerFrame
        }
        guard AudioUnitRender(au, flags, timestamp, 1, frames, abl) == noErr else { return }
        buffer.frameLength = frames

        let samples = resampler.resample(buffer)
        guard !samples.isEmpty else { return }
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        lastLevel.withLock { $0 = rms }
        let duration = Double(samples.count) / AudioResampler.targetRate
        let start = clock.advance(channel: .mic, by: duration)
        state.withLock { $0 }?.yield(
            AudioChunk(channel: .mic, samples: samples, startTime: start))
    }
}
