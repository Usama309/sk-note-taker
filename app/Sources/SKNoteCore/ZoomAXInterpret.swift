import Foundation

/// A plain, `Sendable` snapshot of one macOS Accessibility element: role + text + children, with
/// the live `AXUIElement` pointers stripped out. `ZoomSpeakerReader` (in the app target) walks the
/// Zoom desktop app into a tree of these; the pure interpreters below turn that tree into a
/// participant roster and an active-speaker guess.
///
/// The split exists so every Zoom-UI-shape heuristic is unit-testable from a hand-built or
/// dump-derived tree, without a live Zoom call. Zoom exposes no speaker API, so the active-speaker
/// signal must be discovered from the real UI; `diagnostics(...)` records exactly what Zoom emits
/// on each poll so a real call auto-captures the vocabulary instead of relying on a manual dump.
public struct AXNode: Sendable, Hashable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var desc: String?
    public var children: [AXNode]

    public init(role: String, subrole: String? = nil, title: String? = nil,
                value: String? = nil, desc: String? = nil, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.desc = desc
        self.children = children
    }

    /// desc + value + title joined, the unit for text matching.
    public var hay: String {
        [desc, value, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// This node plus every descendant, depth-first.
    public func flattened() -> [AXNode] {
        var out = [self]
        for c in children { out.append(contentsOf: c.flattened()) }
        return out
    }

    /// The first descendant (or self) matching `predicate`, depth-first.
    public func first(where predicate: (AXNode) -> Bool) -> AXNode? {
        if predicate(self) { return self }
        for c in children { if let hit = c.first(where: predicate) { return hit } }
        return nil
    }
}

/// The active speaker identified from Zoom's UI, plus which signal found it (for logging/tuning).
public struct ActiveSpeaker: Sendable, Equatable {
    public let name: String
    public let strategy: String
    public init(name: String, strategy: String) {
        self.name = name
        self.strategy = strategy
    }
}

/// Pure interpreters over a Zoom Accessibility tree. No AppKit, no live AX — fully testable.
public enum ZoomAX {

    // MARK: Name cleaning

    private static let nonNames: Set<String> = [
        "zoom", "participants", "more", "unmute", "mute", "start video", "stop video",
        "invite", "host", "mute all", "close", "pop out", "upgrade zoom", "participant"
    ]

    /// Turn a raw label like "Muhammad Usama (Host, me)" into "Muhammad Usama", or nil if it does
    /// not look like a person's name.
    public static func cleanName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut at the first "(" or "," — Zoom appends "(Host, me)" and ", active speaker" /
        // ", Computer audio muted" style tags after the name.
        if let cut = s.firstIndex(where: { $0 == "(" || $0 == "," }) {
            s = String(s[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty, s.count <= 60 else { return nil }
        guard s.rangeOfCharacter(from: .letters) != nil else { return nil }
        if nonNames.contains(s.lowercased()) { return nil }
        return s
    }

    /// Name out of an accessibility description like "View Alice Smith's profile".
    static func nameFromProfile(_ desc: String) -> String? {
        guard desc.hasPrefix("View ") else { return nil }
        var body = String(desc.dropFirst("View ".count))
        for suffix in ["'s profile", "\u{2019}s profile", "s profile"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count))
            return cleanName(body)
        }
        return nil
    }

    /// Name out of "More options for Alice Smith, collapsed".
    static func nameFromMoreOptions(_ desc: String) -> String? {
        guard desc.hasPrefix("More options for ") else { return nil }
        var body = String(desc.dropFirst("More options for ".count))
        if let comma = body.firstIndex(of: ",") { body = String(body[..<comma]) }
        return cleanName(body)
    }

    // MARK: Roster

    /// The participant roster — real names gathered from every reliable name-bearing node Zoom
    /// exposes (the Participants list, per-tile "View X's profile" buttons, and the per-row
    /// "More options for X" menus). De-duplicated, order preserved.
    public static func roster(in root: AXNode) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func add(_ n: String?) {
            guard let n, !seen.contains(n) else { return }
            seen.insert(n); names.append(n)
        }

        // 1. The Participants list outline: rows of static text "Name (tags)".
        if let list = root.first(where: {
            ($0.role == "AXOutline" || $0.role == "AXList") &&
            ($0.desc?.localizedCaseInsensitiveContains("participant") ?? false)
        }) {
            for node in list.flattened() where node.role == "AXStaticText" {
                if let v = node.value { add(cleanName(v)) }
            }
        }
        // 2. + 3. Name-bearing controls anywhere in the meeting window.
        for node in root.flattened() {
            if let d = node.desc {
                add(nameFromProfile(d))
                add(nameFromMoreOptions(d))
            }
        }
        return names
    }

    // MARK: Active speaker

    /// High-confidence phrases Zoom might use to mark the talking participant. Kept conservative on
    /// purpose: a wrong name mislabels a whole cluster, so we only feed the transcript an explicit
    /// speaking marker (and only when it resolves to a known roster name). Everything else Zoom
    /// exposes is recorded by `diagnostics` for tuning rather than trusted blindly.
    private static let hardMarkers = ["active speaker", "is speaking", "is talking"]
    private static let softMarkers = [" speaking", " talking"]

    /// The current active speaker, or nil if no trustworthy signal. `roster` (when non-empty)
    /// constrains the result to a known participant.
    public static func activeSpeaker(in root: AXNode, roster: [String]) -> ActiveSpeaker? {
        for node in root.flattened() {
            let h = node.hay
            guard !h.isEmpty else { continue }
            let lower = h.lowercased()

            let hard = hardMarkers.contains { lower.contains($0) }
            let soft = softMarkers.contains { lower.contains($0) }
            guard hard || soft else { continue }

            // Prefer a roster name embedded in the node's text.
            if let hit = roster.first(where: { h.localizedCaseInsensitiveContains($0) }) {
                return ActiveSpeaker(name: hit, strategy: hard ? "marker" : "marker-soft")
            }
            // No roster (panel closed): trust an explicit hard marker's own text, with the marker
            // words stripped so "Alice Smith, active speaker" resolves to "Alice Smith".
            if hard, roster.isEmpty {
                var text = node.value ?? node.desc ?? ""
                for m in hardMarkers + softMarkers {
                    text = text.replacingOccurrences(of: m, with: "", options: .caseInsensitive)
                }
                if let name = cleanName(text) {
                    return ActiveSpeaker(name: name, strategy: "marker-noroster")
                }
            }
        }
        return nil
    }

    // MARK: Diagnostics (auto-capture for tuning)

    /// A compact, human-readable snapshot of everything name/speaker-relevant Zoom exposed this
    /// poll, plus what CHANGED since the previous poll. The changed lines are the payload: whatever
    /// toggles as people talk is the real active-speaker signal, captured automatically from a live
    /// call under whatever conditions the user is in.
    public static func diagnostics(in root: AXNode, previous: AXNode?, roster: [String]) -> String {
        var lines: [String] = []
        let count = participantCount(in: root)
        lines.append("participants: \(count.map(String.init) ?? "?")   roster(\(roster.count)): \(roster.joined(separator: ", "))")

        // Mute / video state per participant row.
        let states = muteStates(in: root)
        if !states.isEmpty {
            lines.append("states: " + states.map { "\($0.name)=\($0.muted ? "muted" : "unmuted")\($0.videoOff ? "/novideo" : "")" }.joined(separator: "; "))
        }
        // Spotlight / focused tile.
        if let tab = root.first(where: { $0.role == "AXTabGroup" && ($0.desc?.isEmpty == false) }) {
            lines.append("spotlight(AXTabGroup): \"\(tab.desc ?? "")\"")
        }
        // Any node carrying a speaking-ish word — reveals whether Zoom emits one at all.
        let speaking = root.flattened().filter { n in
            let l = n.hay.lowercased()
            return (hardMarkers + softMarkers).contains { l.contains($0) }
        }
        lines.append("speaking-candidates: " + (speaking.isEmpty ? "(none)"
            : speaking.map { "[\($0.role)] \($0.hay)" }.joined(separator: " | ")))

        // What changed vs the previous poll (the dynamic speaking indicator lives here).
        if let previous {
            let (added, removed) = interestingDelta(from: previous, to: root, roster: roster)
            if !added.isEmpty { lines.append("changed +: " + added.joined(separator: " | ")) }
            if !removed.isEmpty { lines.append("changed -: " + removed.joined(separator: " | ")) }
            if added.isEmpty && removed.isEmpty { lines.append("changed: (none)") }
        }
        return lines.joined(separator: "\n")
    }

    /// "Participants (N)" count if Zoom shows it.
    static func participantCount(in root: AXNode) -> Int? {
        for node in root.flattened() {
            let h = node.hay
            guard let r = h.range(of: "Participants (") else { continue }
            let rest = h[r.upperBound...]
            if let close = rest.firstIndex(of: ")") {
                return Int(rest[..<close])
            }
        }
        return nil
    }

    struct MuteState: Equatable { let name: String; let muted: Bool; let videoOff: Bool }

    /// Per-row mute/video state from the participants list. `muted` is inferred from the presence of
    /// an "Unmute" action (Zoom labels the button with the inverse of the current state).
    static func muteStates(in root: AXNode) -> [MuteState] {
        guard let list = root.first(where: {
            ($0.role == "AXOutline" || $0.role == "AXList") &&
            ($0.desc?.localizedCaseInsensitiveContains("participant") ?? false)
        }) else { return [] }

        var out: [MuteState] = []
        for row in list.flattened() where row.role == "AXRow" || row.role == "AXCell" {
            let texts = row.flattened().filter { $0.role == "AXStaticText" }
            guard let raw = texts.first?.value, let name = cleanName(raw) else { continue }
            let controls = row.flattened()
            let muted = controls.contains { ($0.desc == "Unmute" || $0.title == "Unmute") }
            let unmuted = controls.contains { ($0.desc == "Mute" || $0.title == "Mute") }
            let videoOff = controls.contains { ($0.desc == "Start video" || $0.title == "Start video") }
            // Only emit rows where we could read a state, and de-dupe (AXRow wraps AXCell).
            if (muted || unmuted), !out.contains(where: { $0.name == name }) {
                out.append(MuteState(name: name, muted: muted && !unmuted, videoOff: videoOff))
            }
        }
        return out
    }

    /// Name/speaker-relevant hay strings that appeared or disappeared between two polls.
    static func interestingDelta(from a: AXNode, to b: AXNode, roster: [String]) -> (added: [String], removed: [String]) {
        func interesting(_ n: AXNode) -> String? {
            let h = n.hay
            let l = h.lowercased()
            let hasMarker = (hardMarkers + softMarkers).contains { l.contains($0) }
            let hasState = l.contains("muted") || l.contains("speaking") || l.contains("talking")
            let hasName = roster.contains { h.localizedCaseInsensitiveContains($0) }
            return (hasMarker || hasState || hasName) ? "[\(n.role)] \(h)" : nil
        }
        let before = Set(a.flattened().compactMap(interesting))
        let after = Set(b.flattened().compactMap(interesting))
        return (added: Array(after.subtracting(before)).sorted(),
                removed: Array(before.subtracting(after)).sorted())
    }
}
