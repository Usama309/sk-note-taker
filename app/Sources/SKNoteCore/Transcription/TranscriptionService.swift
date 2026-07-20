import Foundation
import Speech
import AVFoundation
import CoreMedia

/// A finalized or volatile piece of transcription from one audio channel, on the session clock.
public struct TranscriptionResult: Sendable {
    public let channel: AudioChannel
    public let text: String
    public let start: Double      // seconds on session clock
    public let end: Double
    public let isFinal: Bool
    /// Word/run-level timings within this result (session clock) — used for diarization merge.
    public let tokens: [(text: String, start: Double, end: Double)]

    public init(channel: AudioChannel, text: String, start: Double, end: Double,
                isFinal: Bool, tokens: [(text: String, start: Double, end: Double)] = []) {
        self.channel = channel
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.tokens = tokens
    }
}

/// One on-device SpeechTranscriber pipeline per audio channel (mic and system get separate
/// instances so "me vs them" attribution is intrinsic).
public actor TranscriptionService {
    private let channel: AudioChannel
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var consumeTask: Task<Void, Never>?

    /// Audio fed so far, so CMTime-relative results can be mapped onto the session clock.
    /// SpeechAnalyzer reports time ranges relative to the audio it has been fed, which for us
    /// starts at the first chunk's session timestamp.
    private var sessionOffset: Double?

    public init(channel: AudioChannel, locale: Locale = Locale(identifier: "en-US")) {
        self.channel = channel
        self.locale = locale
    }

    /// Ensures the on-device model for the locale is installed (system-wide, one download).
    public static func ensureModel(locale: Locale = Locale(identifier: "en-US")) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw TranscriptionError.localeUnsupported(locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    /// Starts the pipeline; results (volatile + final) are delivered to `handler`.
    public func start(handler: @escaping @Sendable (TranscriptionResult) -> Void) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        let channel = self.channel
        let debug = ProcessInfo.processInfo.environment["SKNOTE_DEBUG"] == "1"
        consumeTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    if debug {
                        FileHandle.standardError.write(Data(
                            "SKNOTE_DEBUG asr[\(channel.rawValue)] final=\(result.isFinal) text=\(String(result.text.characters).prefix(60))\n".utf8))
                    }
                    let offset = await self.sessionOffset ?? 0
                    let mapped = Self.map(result: result, channel: channel, offset: offset)
                    if let mapped { handler(mapped) }
                }
                if debug {
                    FileHandle.standardError.write(Data(
                        "SKNOTE_DEBUG asr[\(channel.rawValue)] results stream finished\n".utf8))
                }
            } catch {
                SKLog.error(.transcriptionStreamEnded, .transcription,
                            "Transcriber stream ended for the \(channel.rawValue) channel — "
                            + "that channel will produce no further text this meeting",
                            error: error)
            }
        }
    }

    /// Persistent converter (16 kHz mono → analyzer format). Sample-rate conversion is
    /// stateful; recreating it per chunk corrupts audio at chunk boundaries.
    private var feedConverter: AVAudioConverter?

    /// Feed a 16 kHz mono chunk (session-clock stamped).
    public func feed(_ chunk: AudioChunk) {
        if sessionOffset == nil { sessionOffset = chunk.startTime }
        guard let format = analyzerFormat,
              let mono = AudioResampler.buffer(from: chunk.samples) else { return }
        let buffer: AVAudioPCMBuffer
        if format == mono.format {
            buffer = mono
        } else {
            if feedConverter == nil {
                feedConverter = AVAudioConverter(from: mono.format, to: format)
                feedConverter?.primeMethod = .none
            }
            guard let converter = feedConverter else { return }
            let ratio = format.sampleRate / mono.format.sampleRate
            let cap = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up) + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var served = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true; status.pointee = .haveData; return mono
            }
            guard convError == nil, out.frameLength > 0 else { return }
            buffer = out
        }
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // Finalization emits the trailing final results; DRAIN the consumer instead of
        // cancelling it, or those results are silently dropped.
        await consumeTask?.value
        consumeTask = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Result mapping

    private static func map(result: SpeechTranscriber.Result, channel: AudioChannel,
                            offset: Double) -> TranscriptionResult? {
        let attributed = result.text
        let plain = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }

        var tokens: [(text: String, start: Double, end: Double)] = []
        var minStart = Double.greatestFiniteMagnitude
        var maxEnd: Double = 0
        for run in attributed.runs {
            guard let range = run.audioTimeRange else { continue }
            let text = String(attributed[run.range].characters)
            let start = range.start.seconds + offset
            let end = range.end.seconds + offset
            tokens.append((text, start, end))
            minStart = min(minStart, start)
            maxEnd = max(maxEnd, end)
        }
        if tokens.isEmpty {
            // No timing info (some volatile results) — synthesize a zero range at the offset.
            minStart = offset
            maxEnd = offset
        }
        return TranscriptionResult(
            channel: channel, text: plain,
            start: minStart == .greatestFiniteMagnitude ? offset : minStart,
            end: maxEnd, isFinal: result.isFinal, tokens: tokens)
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case localeUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let id): "Transcription locale not supported: \(id)"
        }
    }
}
