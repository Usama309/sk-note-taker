import Foundation
import FluidAudio

/// A speaker-labeled time interval on the session clock.
public struct SpeakerSegment: Sendable, Equatable {
    public let speakerId: String     // diarizer-native id, e.g. "1"
    public let start: Double
    public let end: Double

    public init(speakerId: String, start: Double, end: Double) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
    }
}

/// On-device speaker diarization of the system-audio stream via FluidAudio (CoreML/ANE).
///
/// Strategy: accumulate all system-channel audio and re-run complete diarization over the
/// full buffer on a cadence (global clustering keeps speaker identities stable), plus a
/// final pass at meeting end. The mic channel never goes through here — it is S1 by
/// construction.
public actor DiarizationService {
    private var models: DiarizerModels?
    private var samples: [Float] = []
    private var firstChunkOffset: Double?
    private var lastRunSampleCount = 0
    private(set) public var segments: [SpeakerSegment] = []

    /// Re-diarize after this much new audio has accumulated.
    private let incrementalInterval: Double
    /// Speaker-embedding clustering threshold. FluidAudio's default (0.7) under-splits
    /// system-audio captures — macOS output processing compresses voice-embedding
    /// distances — so we default lower for the meeting use case.
    private let clusteringThreshold: Float

    public init(incrementalInterval: Double = 15.0, clusteringThreshold: Float = 0.6) {
        self.incrementalInterval = incrementalInterval
        self.clusteringThreshold = clusteringThreshold
    }

    /// Downloads (once) and loads the CoreML diarization models.
    public func prepare() async throws {
        guard models == nil else { return }
        models = try await DiarizerModels.downloadIfNeeded()
    }

    public func feed(_ chunk: AudioChunk) {
        if firstChunkOffset == nil { firstChunkOffset = chunk.startTime }
        samples.append(contentsOf: chunk.samples)
    }

    /// Runs an incremental pass if enough new audio arrived. Returns updated segments or nil.
    public func incrementalPass() async -> [SpeakerSegment]? {
        let newSamples = samples.count - lastRunSampleCount
        guard Double(newSamples) / 16_000 >= incrementalInterval else { return nil }
        return await runPass()
    }

    /// Final full-quality pass over everything.
    public func finalPass() async -> [SpeakerSegment] {
        await runPass() ?? segments
    }

    private func runPass() async -> [SpeakerSegment]? {
        guard let models, samples.count > 16_000 else { return nil } // need >1 s of audio
        lastRunSampleCount = samples.count
        let offset = firstChunkOffset ?? 0
        let audio = samples
        do {
            var config = DiarizerConfig()
            config.clusteringThreshold = clusteringThreshold
            let diarizer = DiarizerManager(config: config)
            diarizer.initialize(models: models)
            let result = try diarizer.performCompleteDiarization(audio, sampleRate: 16_000)
            // Fold same-voice clusters back together: the tight live threshold lets short
            // backchannels ("yep", "mm-hmm") spawn a phantom extra speaker.
            let merged = SpeakerClusterMerger.mergeMap(for: result.segments.map {
                SpeakerClusterMerger.Segment(
                    speakerId: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds),
                    embedding: $0.embedding)
            })
            segments = result.segments.map {
                SpeakerSegment(speakerId: merged[$0.speakerId] ?? $0.speakerId,
                               start: Double($0.startTimeSeconds) + offset,
                               end: Double($0.endTimeSeconds) + offset)
            }.sorted { $0.start < $1.start }
            return segments
        } catch {
            FileHandle.standardError.write(
                Data("SKNoteTaker: diarization pass failed: \(error)\n".utf8))
            return nil
        }
    }

    /// Total seconds of system audio accumulated (for diagnostics).
    public var accumulatedSeconds: Double { Double(samples.count) / 16_000 }
}
