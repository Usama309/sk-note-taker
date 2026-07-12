import Foundation

/// Merges finalized transcription results (mic + system channels) with diarizer speaker
/// segments into the persisted transcript:
///
/// - Mic channel is always speaker key "S1" (the machine owner) — dual-stream capture makes
///   local attribution intrinsic.
/// - System-channel tokens are attributed to diarizer speakers by midpoint overlap, then
///   diarizer ids are mapped to stable keys S2, S3, … in order of first appearance.
/// - Consecutive same-speaker tokens coalesce into utterance segments.
///
/// The assembler retains raw ASR results so speaker attribution can be fully recomputed
/// whenever the diarizer re-clusters (it re-runs over the whole meeting).
public struct TranscriptAssembler: Sendable {
    public var maxUtteranceGap: Double

    public init(maxUtteranceGap: Double = 1.5) {
        self.maxUtteranceGap = maxUtteranceGap
    }

    private struct Token {
        var text: String
        var start: Double
        var end: Double
        var source: AudioChannel
        var speakerKey: String
    }

    /// Builds the full transcript + the speakers map for meeting.json.
    public func assemble(
        finals: [TranscriptionResult],
        speakerSegments: [SpeakerSegment]
    ) -> (segments: [TranscriptSegment], speakers: [String: SpeakerInfo]) {

        // Stable mapping: diarizer id -> S2, S3, … by first appearance in the timeline.
        var diarizerKey: [String: String] = [:]
        for seg in speakerSegments.sorted(by: { $0.start < $1.start }) {
            if diarizerKey[seg.speakerId] == nil {
                diarizerKey[seg.speakerId] = "S\(diarizerKey.count + 2)"
            }
        }

        var tokens: [Token] = []
        for result in finals where result.isFinal {
            let resultTokens: [(text: String, start: Double, end: Double)] =
                result.tokens.isEmpty
                    ? [(result.text, result.start, result.end)]
                    : result.tokens
            for tok in resultTokens {
                let text = tok.text
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let key: String
                switch result.channel {
                case .mic:
                    key = "S1"
                case .system:
                    let mid = (tok.start + tok.end) / 2
                    let id = Self.speakerId(atTime: mid, in: speakerSegments)
                    key = id.flatMap { diarizerKey[$0] } ?? "S2"
                }
                tokens.append(Token(text: text, start: tok.start, end: tok.end,
                                    source: result.channel, speakerKey: key))
            }
        }
        tokens.sort { $0.start < $1.start }

        // Coalesce into utterances.
        var segments: [TranscriptSegment] = []
        for token in tokens {
            if var last = segments.last,
               last.speaker == token.speakerKey,
               token.start - last.end <= maxUtteranceGap {
                last.text = Self.join(last.text, token.text)
                last.end = max(last.end, token.end)
                segments[segments.count - 1] = last
            } else {
                segments.append(TranscriptSegment(
                    id: segments.count,
                    speaker: token.speakerKey,
                    source: token.source,
                    start: token.start,
                    end: token.end,
                    text: token.text.trimmingCharacters(in: .whitespaces)))
            }
        }

        // Speakers map: S1 = mic; diarized keys from the system stream.
        var speakers: [String: SpeakerInfo] = [:]
        let usedKeys = Set(segments.map(\.speaker))
        if usedKeys.contains("S1") {
            speakers["S1"] = SpeakerInfo(label: "Speaker 1", source: .mic)
        }
        for key in usedKeys where key != "S1" {
            let number = Int(key.dropFirst()) ?? 2
            speakers[key] = SpeakerInfo(label: "Speaker \(number)", source: .system)
        }
        return (segments, speakers)
    }

    /// Max-overlap lookup: the diarizer segment containing the midpoint, else nearest.
    static func speakerId(atTime t: Double, in segments: [SpeakerSegment]) -> String? {
        if let hit = segments.first(where: { t >= $0.start && t < $0.end }) {
            return hit.speakerId
        }
        return segments.min {
            min(abs(t - $0.start), abs(t - $0.end)) < min(abs(t - $1.start), abs(t - $1.end))
        }?.speakerId
    }

    private static func join(_ a: String, _ b: String) -> String {
        let trimmedB = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return trimmedB }
        if trimmedB.isEmpty { return a }
        // Attach punctuation directly; otherwise separate words with a space.
        if trimmedB.first?.isPunctuation == true { return a + trimmedB }
        return a + " " + trimmedB
    }
}
