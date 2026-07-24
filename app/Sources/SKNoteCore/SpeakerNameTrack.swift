import Foundation
import Synchronization

/// A stretch of meeting time (session-clock seconds) during which a named participant was the
/// active speaker, as reported by the meeting app's UI (Zoom Accessibility / a Meet extension).
public struct NameSpan: Sendable, Hashable {
    public let name: String
    public let start: Double
    public let end: Double

    public init(name: String, start: Double, end: Double) {
        self.name = name
        self.start = start
        self.end = end
    }
}

/// Accumulates "who is the active speaker right now" signals into contiguous name spans on the
/// session timeline. A meeting-app reader calls `record(name:at:)` roughly 1-2x/second; the
/// transcript assembler reads `snapshot()` to attach real participant names to speaker clusters.
///
/// Reference type with an internal Mutex so the reader (a background poll) and the assembler
/// (a detached task) can touch it without a data race.
public final class SpeakerNameTrack: Sendable {
    private struct State {
        var spans: [NameSpan] = []
        var currentName: String?
        var currentStart: Double = 0
        var lastTime: Double = 0
    }
    private let state = Mutex(State())

    public init() {}

    public var isEmpty: Bool {
        state.withLock { $0.spans.isEmpty && $0.currentName == nil }
    }

    /// Record that `name` is the active speaker at session time `t`. The same name in a row
    /// extends the open span; a new name closes the open span at `t` and starts a fresh one.
    public func record(name: String, at t: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.withLock { s in
            if t > s.lastTime { s.lastTime = t }
            if let cur = s.currentName {
                if cur == trimmed { return }
                s.spans.append(NameSpan(name: cur, start: s.currentStart, end: max(s.currentStart, t)))
            }
            s.currentName = trimmed
            s.currentStart = t
        }
    }

    /// Close the open span (e.g. nobody is highlighted as active, or the meeting ended).
    public func clearActive(at t: Double) {
        state.withLock { s in
            if t > s.lastTime { s.lastTime = t }
            guard let cur = s.currentName else { return }
            s.spans.append(NameSpan(name: cur, start: s.currentStart, end: max(s.currentStart, t)))
            s.currentName = nil
        }
    }

    /// Every span so far, including the still-open current span extended to `now`
    /// (defaults to the latest recorded time).
    public func snapshot(now: Double? = nil) -> [NameSpan] {
        state.withLock { s in
            var out = s.spans
            if let cur = s.currentName {
                let end = max(s.currentStart, now ?? s.lastTime)
                out.append(NameSpan(name: cur, start: s.currentStart, end: end))
            }
            return out
        }
    }
}
