import Foundation
import Testing
@testable import SKNoteCore

/// Tests for the post-diarization cluster merge that would have caught the phantom
/// "Speaker 3" bug: a 2-person call where one voice's short backchannels ("yep", "mm-hmm")
/// spawned a third speaker cluster.
@Suite("Speaker cluster merger")
struct SpeakerClusterMergerTests {

    /// Deterministic unit vector in 256-D, tilted `angle` radians away from `base` toward
    /// an orthogonal direction — cosine distance to base is exactly 1 - cos(angle).
    private func embedding(base: Int = 0, tiltToward other: Int = 1, angle: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[base] = cos(angle)
        v[other] = sin(angle)
        return v
    }

    private func segment(
        _ speaker: String, start: Double, duration: Double, embedding: [Float]
    ) -> SpeakerClusterMerger.Segment {
        .init(speakerId: speaker, start: start, end: start + duration, embedding: embedding)
    }

    /// The Patriot-meeting shape: one dominant voice plus a small cluster of short
    /// backchannels whose centroid is close-but-not-identical → must fold into the
    /// dominant speaker.
    @Test func phantomBackchannelClusterMergesIntoDominantVoice() {
        var segments: [SpeakerClusterMerger.Segment] = []
        // Speaker "1": 20 long segments, embeddings right on the voice axis.
        for i in 0..<20 {
            segments.append(segment("1", start: Double(i) * 30, duration: 20,
                                    embedding: embedding(angle: 0.05)))
        }
        // Speaker "2": short backchannels whose centroid sits at cosine distance ≈ 0.59 —
        // outside the same-voice range (0.45), inside the absorb range (0.72), so only the
        // minor-cluster path can fold it.
        for i in 0..<8 {
            segments.append(segment("2", start: Double(i) * 60 + 25, duration: 1.5,
                                    embedding: embedding(angle: 1.2)))
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map["2"] == "1", "backchannel cluster should fold into the dominant voice")
    }

    /// Two clusters with nearly identical centroids merge regardless of size (same voice
    /// split by re-clustering instability).
    @Test func nearIdenticalCentroidsAlwaysMerge() {
        var segments: [SpeakerClusterMerger.Segment] = []
        for i in 0..<5 {
            segments.append(segment("1", start: Double(i) * 20, duration: 10,
                                    embedding: embedding(angle: 0.1)))
            segments.append(segment("2", start: Double(i) * 20 + 10, duration: 8,
                                    embedding: embedding(angle: 0.2)))   // d ≈ 0.005 to "1"
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map.count == 1, "one of the two same-voice clusters should be relabeled")
    }

    /// Genuinely different voices — orthogonal embeddings — must NOT merge when the quiet
    /// one has spoken enough (past the dust floor) in real sentences (past the
    /// backchannel shape test).
    @Test func distinctQuietSpeakerIsPreserved() {
        var segments: [SpeakerClusterMerger.Segment] = []
        for i in 0..<20 {
            segments.append(segment("1", start: Double(i) * 30, duration: 20,
                                    embedding: embedding(angle: 0)))
        }
        // Orthogonal voice (cosine distance 1.0): 16s total in 4s sentences.
        for i in 0..<4 {
            segments.append(segment("2", start: Double(i) * 100 + 25, duration: 4,
                                    embedding: embedding(angle: .pi / 2)))
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map.isEmpty, "a distinct voice with substantive speech must survive")
    }

    /// A cluster totaling under the dust floor (~12s over a whole meeting) can't establish
    /// an identity — it folds into the nearest substantial cluster even at max distance.
    @Test func dustClusterIsAbsorbedRegardlessOfDistance() {
        var segments: [SpeakerClusterMerger.Segment] = []
        for i in 0..<20 {
            segments.append(segment("1", start: Double(i) * 30, duration: 20,
                                    embedding: embedding(angle: 0)))
        }
        // Orthogonal but only 8s total — below the dust floor.
        for i in 0..<2 {
            segments.append(segment("2", start: Double(i) * 200 + 25, duration: 4,
                                    embedding: embedding(angle: .pi / 2)))
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map["2"] == "1", "sub-dust-floor clusters fold into the dominant voice")
    }

    /// A minor cluster that is moderately distant but made of LONG segments is trusted as
    /// a real speaker (reliable embeddings) — only short-utterance clusters are absorbed.
    @Test func minorClusterWithLongSegmentsIsPreserved() {
        var segments: [SpeakerClusterMerger.Segment] = []
        for i in 0..<20 {
            segments.append(segment("1", start: Double(i) * 30, duration: 20,
                                    embedding: embedding(angle: 0)))
        }
        for i in 0..<2 {
            segments.append(segment("2", start: Double(i) * 200 + 25, duration: 10,
                                    embedding: embedding(angle: 0.9)))   // d ≈ 0.38...
        }
        // d(0.9) = 1 - cos(0.9) ≈ 0.378 < sameVoice 0.45 — would merge unconditionally.
        // Push it outside same-voice range but inside absorb range:
        segments.removeLast(2)
        for i in 0..<2 {
            segments.append(segment("2", start: Double(i) * 200 + 25, duration: 10,
                                    embedding: embedding(angle: 1.1)))   // d ≈ 0.55
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map.isEmpty, "long-segment clusters are reliable and must not be absorbed")
    }

    /// The 3-person-call regression (13 Jul 6:30 PM meeting): two different men on a
    /// phone-quality call measured only d≈0.32 apart — closer than one voice's own
    /// backchannel fragments in another meeting. Two substantial clusters with real
    /// sentence-length segments must NEVER merge on distance alone.
    @Test func twoSubstantialVoicesOnCompressedCallStaySeparate() {
        var segments: [SpeakerClusterMerger.Segment] = []
        // Remote speaker A: 45s in long turns.
        for i in 0..<9 {
            segments.append(segment("3", start: Double(i) * 12, duration: 5,
                                    embedding: embedding(angle: 0)))
        }
        // Remote speaker B (Wakas): two long turns, centroid d ≈ 0.32 from A.
        for i in 0..<2 {
            segments.append(segment("4", start: 110 + Double(i) * 12, duration: 7.7,
                                    embedding: embedding(angle: 0.823)))
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map.isEmpty, "different voices on compressed call audio must stay separate")
    }

    /// Chained merges relabel transitively: if 3 folds into 2 and 2 folds into 1, the map
    /// must send both to 1.
    @Test func chainedMergesResolveTransitively() {
        var segments: [SpeakerClusterMerger.Segment] = []
        for i in 0..<10 {
            segments.append(segment("1", start: Double(i) * 30, duration: 20,
                                    embedding: embedding(angle: 0)))
        }
        for i in 0..<3 {
            segments.append(segment("2", start: Double(i) * 90 + 22, duration: 1.5,
                                    embedding: embedding(angle: 0.3)))
            segments.append(segment("3", start: Double(i) * 90 + 26, duration: 1.5,
                                    embedding: embedding(angle: 0.35)))
        }
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map["2"] == "1" && map["3"] == "1")
    }

    @Test func emptyAndInvalidEmbeddingsAreIgnored() {
        let segments = [
            segment("1", start: 0, duration: 5, embedding: []),
            segment("2", start: 6, duration: 5, embedding: [Float](repeating: 0, count: 256)),
        ]
        let map = SpeakerClusterMerger.mergeMap(for: segments)
        #expect(map.isEmpty)
    }
}
