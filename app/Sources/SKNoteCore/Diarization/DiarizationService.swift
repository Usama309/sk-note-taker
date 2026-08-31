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
/// Strategy: accumulate all system-channel audio and re-run complete diarization over the full
/// buffer on an adaptive cadence (global clustering keeps speaker identities stable), plus a
/// final pass at meeting end. Expensive CoreML work runs outside the actor so incoming audio can
/// continue to be accepted while a pass is in progress. The mic channel never goes through here
/// because it is S1 by construction.
public actor DiarizationService {
    /// FluidAudio's model bundle is immutable after loading but does not currently declare
    /// `Sendable`. The box documents and contains that SDK boundary for the detached worker.
    private final class ModelsBox: @unchecked Sendable {
        let value: DiarizerModels
        init(_ value: DiarizerModels) { self.value = value }
    }

    private var models: ModelsBox?
    private var samples: [Float] = []
    /// Audio arriving while a detached pass reads `samples`. Keeping it separate avoids
    /// copy-on-write duplicating the entire meeting-sized buffer on the first live append.
    private var samplesArrivedDuringPass: [Float] = []
    private var firstChunkOffset: Double?
    private var lastRunSampleCount = 0
    private var passGeneration = 0
    private var currentPass: (generation: Int, task: Task<[SpeakerSegment]?, Never>)?
    private(set) public var segments: [SpeakerSegment] = []

    /// Re-diarize after this much new audio has accumulated.
    private let incrementalInterval: Double
    /// Speaker-embedding clustering threshold. FluidAudio's default (0.7) under-splits
    /// system-audio captures — macOS output processing compresses voice-embedding
    /// distances — so we default lower for the meeting use case.
    ///
    /// Measured on the FSL Blueprint call (17 Jul), a 3-person call where two remote
    /// colleagues were reported as one speaker: at 0.6 and 0.5 both landed in the same
    /// cluster; at 0.45 and below they separate correctly. 0.45 is the loosest value that
    /// separates them, so it splits real people while over-splitting the least. The
    /// resulting short/backchannel fragments are folded back by `SpeakerClusterMerger`.
    private let clusteringThreshold: Float

    public init(incrementalInterval: Double = 15.0, clusteringThreshold: Float = 0.45) {
        self.incrementalInterval = incrementalInterval
        self.clusteringThreshold = clusteringThreshold
    }

    /// Downloads (once) and loads the CoreML diarization models.
    public func prepare() async throws {
        guard models == nil else { return }
        models = ModelsBox(try await DiarizerModels.downloadIfNeeded())
    }

    public func feed(_ chunk: AudioChunk) {
        if firstChunkOffset == nil { firstChunkOffset = chunk.startTime }
        if currentPass == nil {
            samples.append(contentsOf: chunk.samples)
        } else {
            samplesArrivedDuringPass.append(contentsOf: chunk.samples)
        }
    }

    /// Runs an incremental pass if enough new audio arrived. Returns updated segments or nil.
    public func incrementalPass() async -> [SpeakerSegment]? {
        // There is no value in queuing another full-history pass behind one already running.
        guard currentPass == nil else { return nil }
        let newSamples = samples.count - lastRunSampleCount
        let totalSeconds = Double(samples.count) / 16_000
        let interval = Self.liveRefreshInterval(totalSeconds: totalSeconds,
                                                baseInterval: incrementalInterval)
        guard Double(newSamples) / 16_000 >= interval else { return nil }
        return await startPass()
    }

    /// Final full-quality pass over everything.
    public func finalPass() async -> [SpeakerSegment] {
        // Let an in-flight live pass release its snapshot first, merge any audio that arrived
        // alongside it, then make one definitive pass over the complete meeting.
        if let currentPass {
            let result = await currentPass.task.value
            _ = completePass(generation: currentPass.generation, result: result)
        }
        return await startPass() ?? segments
    }

    /// Complete-diarization cost grows with the entire meeting, so running it every 15 seconds is
    /// quadratic over time. Keep early labels responsive, then progressively reduce refreshes.
    /// The final pass still covers the full recording regardless of this cadence.
    public nonisolated static func liveRefreshInterval(totalSeconds: Double,
                                                       baseInterval: Double = 15) -> Double {
        if totalSeconds < 120 { return baseInterval }
        if totalSeconds < 600 { return max(baseInterval, 60) }
        return max(baseInterval, 180)
    }

    private func startPass() async -> [SpeakerSegment]? {
        guard let models, samples.count > 16_000 else { return nil } // need >1 s of audio
        lastRunSampleCount = samples.count
        let offset = firstChunkOffset ?? 0
        let threshold = clusteringThreshold
        // `feed` writes into `samplesArrivedDuringPass` until this task completes, so this array's
        // storage stays immutable and is not cloned as the live meeting continues.
        let audio = samples
        passGeneration += 1
        let generation = passGeneration
        let task: Task<[SpeakerSegment]?, Never> = Task.detached(priority: .utility) {
            do {
                var config = DiarizerConfig()
                config.clusteringThreshold = threshold
                let diarizer = DiarizerManager(config: config)
                diarizer.initialize(models: models.value)
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
                return result.segments.map {
                    SpeakerSegment(speakerId: merged[$0.speakerId] ?? $0.speakerId,
                                   start: Double($0.startTimeSeconds) + offset,
                                   end: Double($0.endTimeSeconds) + offset)
                }.sorted { $0.start < $1.start }
            } catch {
                SKLog.error(.diarizationPassFailed, .diarization,
                            "Diarization pass failed — speaker labels will not update this pass",
                            error: error)
                return nil
            }
        }
        currentPass = (generation, task)
        let result = await task.value
        return completePass(generation: generation, result: result)
    }

    /// Applies a pass only if it is still the current generation. Both `incrementalPass` and
    /// `finalPass` may await the same task due to actor reentrancy, so the generation guard also
    /// ensures live-arrival audio is merged exactly once.
    private func completePass(generation: Int,
                              result: [SpeakerSegment]?) -> [SpeakerSegment]? {
        guard currentPass?.generation == generation else { return nil }
        currentPass = nil
        if !samplesArrivedDuringPass.isEmpty {
            samples.append(contentsOf: samplesArrivedDuringPass)
            samplesArrivedDuringPass.removeAll(keepingCapacity: true)
        }
        if let result { segments = result }
        return result
    }

    /// Total seconds of system audio accumulated (for diagnostics).
    public var accumulatedSeconds: Double {
        Double(samples.count + samplesArrivedDuringPass.count) / 16_000
    }
}
