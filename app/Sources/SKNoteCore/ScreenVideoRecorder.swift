import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

public struct ScreenVideoError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Records the screen (video only) to a .mov via a DEDICATED ScreenCaptureKit stream, kept fully
/// separate from the system-audio stream so it can never destabilise the diarization audio path.
/// Downscaled and frame-rate-capped to keep encoding light on the CPU (VideoToolbox H.264).
/// Uses movie fragments so a crash still leaves a playable partial file.
public final class ScreenVideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let url: URL
    private let videoQueue = DispatchQueue(label: "sk.notetaker.screenvideo")
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false      // touched only on videoQueue

    public init(outputURL: URL) {
        self.url = outputURL
        super.init()
    }

    public static func permissionGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Start recording the given display (nil = main display) to the output .mov.
    public func start(displayID: CGDirectDisplayID? = nil) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ScreenVideoError("Screen Recording permission is required to record the screen.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display: SCDisplay
        if let displayID, let d = content.displays.first(where: { $0.displayID == displayID }) {
            display = d
        } else if let d = content.displays.first {
            display = d
        } else {
            throw ScreenVideoError("No display available to record.")
        }

        // Downscale to at most 1600px wide (even dims for H.264) and cap the frame rate — a
        // meeting screen recording does not need retina or 30fps, and this keeps the encode
        // cheap next to the reliability-critical audio pipeline.
        let cap = 1600.0
        let scale = min(1.0, cap / Double(display.width))
        let w = max(2, Int((Double(display.width) * scale).rounded(.down))) & ~1
        let h = max(2, Int((Double(display.height) * scale).rounded(.down))) & ~1

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)   // playable partial on crash
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(input) else { throw ScreenVideoError("Cannot configure the video writer.") }
        writer.add(input)
        lock.withLock { self.writer = writer; self.input = input; self.adaptor = adaptor }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 12)   // ~12 fps
        config.queueDepth = 5
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
        SKLog.info(.capture, "screen video: recording started (\(w)x\(h) @12fps, display \(display.displayID))")
    }

    /// Stop capture and finalize the .mov. Returns true if a valid movie was written.
    @discardableResult
    public func stop() async -> Bool {
        if let s = stream {
            try? await s.stopCapture()            // drains callbacks; safe to finalize after
            try? s.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        let (wr, inp): (AVAssetWriter?, AVAssetWriterInput?) = lock.withLock {
            let w = writer; let i = input
            writer = nil; input = nil; adaptor = nil
            return (w, i)
        }
        guard let wr, wr.status == .writing else {
            SKLog.warn(.capture, "screen video: no frames captured; nothing saved")
            return false
        }
        inp?.markAsFinished()
        await wr.finishWriting()
        let ok = wr.status == .completed
        SKLog.info(.capture, "screen video: \(ok ? "saved" : "finalize failed") \(url.lastPathComponent)")
        return ok
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        // Only complete frames (SCK also delivers idle/blank frames to keep timing).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let (wr, inp, ad): (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInputPixelBufferAdaptor?) =
            lock.withLock { (writer, input, adaptor) }
        guard let wr, let inp, let ad else { return }

        if !started {
            started = true
            wr.startWriting()
            wr.startSession(atSourceTime: pts)
        }
        if inp.isReadyForMoreMediaData {
            ad.append(pixelBuffer, withPresentationTime: pts)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        SKLog.error(.captureStreamError, .capture, "Screen video stream stopped", error: error)
    }
}
