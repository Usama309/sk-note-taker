import Foundation

/// Merges diarizer speaker clusters that are actually the same voice.
///
/// The live diarizer's assignment threshold is deliberately tight (macOS output processing
/// compresses voice-embedding distances, so a loose threshold merges distinct remote
/// speakers). The cost: short utterances — backchannels like "yep", "mm-hmm" — have noisy
/// embeddings that can land outside the radius and spawn a phantom speaker. This pass runs
/// after diarization with the benefit of hindsight: duration-weighted centroids computed
/// over each cluster's full speech are far more stable than any single short segment, so
/// same-voice clusters can be folded together without loosening the live threshold.
enum SpeakerClusterMerger {

    /// A diarized segment paired with its voice embedding (from FluidAudio).
    struct Segment {
        let speakerId: String
        let start: Double
        let end: Double
        let embedding: [Float]
    }

    struct Tuning {
        /// Centroid cosine distance below which two clusters are always the same voice.
        /// Deliberately strict: distance scales vary wildly with call conditions —
        /// a same-voice re-clustering split measured d=0.18, while two different men on a
        /// phone-quality call measured d=0.32. Substantial clusters above this stay
        /// separate; only fragmentary clusters (below) merge at larger distances.
        var sameVoiceDistance: Float = 0.25
        /// A minor backchannel cluster is absorbed within this radius. Measured on real
        /// meeting audio: distinct voices sit ≈0.9 apart, while a voice's own backchannel
        /// fragments land 0.6–0.85 from its main cluster.
        var absorbDistance: Float = 0.85
        /// "Minor" means total speech below this fraction of the cluster it would join…
        var minorShare: Double = 0.25
        /// …and made of short utterances on average (noisy embeddings).
        var minorMeanSegmentDuration: Double = 3.5
        /// Dust: a cluster with less total speech than this over the whole meeting can't
        /// establish a distinct identity — it folds into its nearest non-dust cluster
        /// regardless of distance. (A phantom speaker in the UI hurts more than a few
        /// misattributed seconds.) Scaled down for very short meetings via dustShare.
        var dustTotalDuration: Double = 12.0
        /// Dust ceiling as a fraction of all diarized speech (guards short meetings).
        var dustShare: Double = 0.05

        static let `default` = Tuning()
    }

    private struct Cluster {
        var totalDuration: Double
        var segmentCount: Int
        var centroid: [Float]      // duration-weighted, L2-normalized

        var meanSegmentDuration: Double {
            segmentCount > 0 ? totalDuration / Double(segmentCount) : 0
        }
    }

    /// Returns a relabeling map (original speaker id → merged speaker id). Ids absent from
    /// the map are unchanged. Clusters without any valid embedding are left alone.
    static func mergeMap(for segments: [Segment], tuning: Tuning = .default) -> [String: String] {
        var clusters: [String: Cluster] = [:]
        for seg in segments {
            guard let unit = normalized(seg.embedding) else { continue }
            let duration = max(seg.end - seg.start, 0.05)
            // Centroid accumulates Σ (unit embedding × duration); normalized after the loop.
            let weighted = unit.map { $0 * Float(duration) }
            if var cluster = clusters[seg.speakerId] {
                cluster.totalDuration += duration
                cluster.segmentCount += 1
                cluster.centroid = weightedSum(cluster.centroid, weightA: 1, weighted, weightB: 1)
                clusters[seg.speakerId] = cluster
            } else {
                clusters[seg.speakerId] = Cluster(
                    totalDuration: duration, segmentCount: 1, centroid: weighted)
            }
        }
        for (id, cluster) in clusters {
            var c = cluster
            c.centroid = normalized(c.centroid) ?? c.centroid
            clusters[id] = c
        }

        // Repeatedly fold the closest qualifying pair until none qualifies.
        let totalSpeech = clusters.values.reduce(0) { $0 + $1.totalDuration }
        let dustFloor = min(tuning.dustTotalDuration, tuning.dustShare * totalSpeech)
        var mapping: [String: String] = [:]
        while clusters.count > 1 {
            var best: (from: String, into: String, distance: Float)?
            for (idA, a) in clusters {
                for (idB, b) in clusters where idA < idB {
                    let d = cosineDistance(a.centroid, b.centroid)
                    // Fold the smaller cluster into the larger one.
                    let (small, big) = a.totalDuration <= b.totalDuration ? (idA, idB) : (idB, idA)
                    let smallCluster = clusters[small]!, bigCluster = clusters[big]!
                    let sameVoice = d < tuning.sameVoiceDistance
                    let phantom = d < tuning.absorbDistance
                        && smallCluster.totalDuration < tuning.minorShare * bigCluster.totalDuration
                        && smallCluster.meanSegmentDuration < tuning.minorMeanSegmentDuration
                    let dust = smallCluster.totalDuration < dustFloor
                        && bigCluster.totalDuration >= dustFloor
                    guard sameVoice || phantom || dust else { continue }
                    if best == nil || d < best!.distance {
                        best = (from: small, into: big, distance: d)
                    }
                }
            }
            guard let merge = best else { break }
            let from = clusters.removeValue(forKey: merge.from)!
            var into = clusters[merge.into]!
            into.centroid = normalized(weightedSum(
                into.centroid, weightA: into.totalDuration,
                from.centroid, weightB: from.totalDuration)) ?? into.centroid
            into.totalDuration += from.totalDuration
            into.segmentCount += from.segmentCount
            clusters[merge.into] = into
            // Redirect the folded id — and anything already pointing at it.
            mapping[merge.from] = merge.into
            for (key, value) in mapping where value == merge.from {
                mapping[key] = merge.into
            }
        }
        return mapping
    }

    // MARK: - Vector helpers

    private static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        let magnitude = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 1e-6 else { return nil }
        return v.map { $0 / magnitude }
    }

    private static func weightedSum(
        _ a: [Float], weightA: Double, _ b: [Float], weightB: Double
    ) -> [Float] {
        guard a.count == b.count else { return a }
        let wa = Float(weightA), wb = Float(weightB)
        return zip(a, b).map { $0 * wa + $1 * wb }
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return 1 - zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
