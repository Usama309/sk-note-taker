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

        // Cross-channel echo suppression: on laptop speakers (no headphones) the mic picks up
        // the remote participants coming out of the speakers, so the SAME audio gets
        // transcribed on both the mic (S1) and system (S2/S3) channels — producing duplicated,
        // interleaved, one-word fragments. Three signals, because the two channels' ASR
        // timestamps skew by a few hundred ms and the overlap test alone misses leading
        // fragments ("hold", "so") that the mic hears slightly before the system channel:
        //   1. Time overlap — a mic token that heavily overlaps a system token is echo.
        //   2. Text match — a short mic token whose words also appear in a system token
        //      moments apart is the mic's copy of the same audio.
        //   3. Blip — a sub-articulation mic token (<0.2s) while the remote channel is
        //      active is a faint-echo artifact, not speech.
        // Real local speech (mic active while the system channel is quiet) triggers none.
        let systemTokens = tokens.filter { $0.source == .system }
        if !systemTokens.isEmpty {
            tokens = tokens.filter { tok in
                guard tok.source == .mic else { return true }
                let dur = max(tok.end - tok.start, 0.01)
                let words = Self.normalizedWords(tok.text)
                for s in systemTokens {
                    let overlap = min(tok.end, s.end) - max(tok.start, s.start)
                    if overlap > 0, overlap / dur > 0.4 { return false }
                    let gap = max(s.start - tok.end, tok.start - s.end)
                    if gap < 1.0, dur < 0.75, !words.isEmpty,
                       Self.containsWordRun(Self.normalizedWords(s.text), run: words) {
                        return false
                    }
                    if dur < 0.2, gap < 0.75 { return false }
                }
                return true
            }
        }

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

    /// Lowercased words with punctuation stripped — the unit for echo text-matching.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .alphanumerics.inverted) }
            .filter { !$0.isEmpty }
    }

    /// Whether `words` contains `run` as a consecutive sub-sequence.
    static func containsWordRun(_ words: [String], run: [String]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        for start in 0...(words.count - run.count)
        where Array(words[start..<(start + run.count)]) == run {
            return true
        }
        return false
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
