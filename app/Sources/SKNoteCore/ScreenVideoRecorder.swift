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

/// The subset of an `SCWindow` the window picker needs, so the selection heuristic is pure and
/// unit-testable without a live ScreenCaptureKit content list.
public struct CaptureWindow: Sendable, Equatable {
    public let bundleId: String?
    public let title: String?
    public let area: Double
    public let onScreen: Bool
    public init(bundleId: String?, title: String?, area: Double, onScreen: Bool) {
        self.bundleId = bundleId
        self.title = title
        self.area = area
        self.onScreen = onScreen
    }
}

/// Picks which of a meeting app's windows to record, so the capture is scoped to the meeting rather
/// than the whole screen.
public enum ScreenCaptureScope {
    /// Distinctive *call*-window title phrases. Deliberately specific ("google meet", not bare
    /// "meet"/"meeting") so a "Team meeting notes" doc tab or a "Zoom Workplace" home window does
    /// not masquerade as the call. Apps with no distinctive call title (notably Teams, whose call
    /// window is titled by subject/participant) fall through to the front-most rule below.
    static let callTitles = [
        "zoom meeting", "google meet", "meet.google.com",
        "webex meeting", "whereby", "gather.town", "around.co", "huddle",
    ]
    /// Ignore utility/toolbar windows smaller than this (points²).
    static let minArea = 40_000.0

    /// Index into `windows` of the best on-screen window owned by `bundleId` to record:
    /// a window with a distinctive call title if present, otherwise the front-most window (the one
    /// the user is looking at, which for a just-joined call is the call window). `nil` if the app
    /// has no suitable window, so the caller falls back to the full display.
    ///
    /// Assumes `windows` preserves ScreenCaptureKit's front-to-back z-order (it does), so
    /// "front-most" is the first surviving candidate.
    public static func pickWindowIndex(bundleId: String, from windows: [CaptureWindow]) -> Int? {
        let candidates = windows.indices.filter {
            windows[$0].bundleId == bundleId && windows[$0].onScreen && windows[$0].area >= minArea
        }
        guard !candidates.isEmpty else { return nil }
        // 1. Front-most window whose title distinctively names a call.
        if let call = candidates.first(where: { i in
            let t = (windows[i].title ?? "").lowercased()
            return callTitles.contains { t.contains($0) }
        }) { return call }
        // 2. Otherwise the front-most window of the app.
        return candidates.first
    }
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

    /// Start recording to the output .mov.
    ///
    /// - `explicitFilter`: a source the user chose in the native macOS picker (a window, an app, or
    ///   a display). Used as-is when provided.
    /// - Otherwise, when `appBundleId` names the meeting app (Zoom, Teams, or the browser running
    ///   Meet), the capture is scoped to just that app's meeting window; failing that, it falls back
    ///   to the full display so a recording is still produced.
    ///
    /// Returns the resolved scope (for logging).
    @discardableResult
    public func start(filter explicitFilter: sending SCContentFilter? = nil,
                      appBundleId: String? = nil) async throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ScreenVideoError("Screen Recording permission is required to record the screen.")
        }

        // Resolve what to capture: the user's picked source, else the meeting app's window, else the
        // full display.
        let filter: SCContentFilter
        var srcWidth: Double
        var srcHeight: Double
        let scope: String
        if let explicitFilter {
            filter = explicitFilter
            srcWidth = explicitFilter.contentRect.width * Double(explicitFilter.pointPixelScale)
            srcHeight = explicitFilter.contentRect.height * Double(explicitFilter.pointPixelScale)
            scope = "picked source"
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let appBundleId,
               let window = Self.meetingWindow(bundleId: appBundleId, in: content.windows) {
                filter = SCContentFilter(desktopIndependentWindow: window)
                srcWidth = window.frame.width
                srcHeight = window.frame.height
                scope = "window \"\(window.title ?? "")\" of \(appBundleId)"
            } else if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                srcWidth = Double(display.width)
                srcHeight = Double(display.height)
                scope = appBundleId == nil ? "full display" : "full display (no window for \(appBundleId!))"
            } else {
                throw ScreenVideoError("No display available to record.")
            }
        }
        if srcWidth < 2 || srcHeight < 2 { srcWidth = 1280; srcHeight = 720 }   // sane fallback

        // Downscale to at most 1600px wide (even dims for H.264) and cap the frame rate — a
        // meeting screen recording does not need retina or 30fps, and this keeps the encode
        // cheap next to the reliability-critical audio pipeline.
        let cap = 1600.0
        let scale = min(1.0, cap / max(1, srcWidth))
        let w = max(2, Int((srcWidth * scale).rounded(.down))) & ~1
        let h = max(2, Int((srcHeight * scale).rounded(.down))) & ~1

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
        SKLog.info(.capture, "screen video: recording started (\(w)x\(h) @12fps, \(scope))")
        return scope
    }

    /// The `SCWindow` to record for the meeting app, or nil to fall back to the full display.
    private static func meetingWindow(bundleId: String, in windows: [SCWindow]) -> SCWindow? {
        let infos = windows.map {
            CaptureWindow(bundleId: $0.owningApplication?.bundleIdentifier,
                          title: $0.title,
                          area: Double($0.frame.width * $0.frame.height),
                          onScreen: $0.isOnScreen)
        }
        guard let idx = ScreenCaptureScope.pickWindowIndex(bundleId: bundleId, from: infos) else { return nil }
        return windows[idx]
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
