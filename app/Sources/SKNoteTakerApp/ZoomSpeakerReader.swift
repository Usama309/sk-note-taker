import Foundation
import AppKit
import ApplicationServices
import SKNoteCore

/// Reads the Zoom desktop app's UI over the macOS Accessibility API to learn who the active
/// speaker is, so their real name can be attached to the transcript (Granola-style speaker tags).
///
/// Zoom exposes no API for this. The reader walks Zoom's accessibility hierarchy into a plain
/// `AXNode` tree and hands it to the pure `ZoomAX` interpreters (in SKNoteCore, unit-tested) to
/// extract the participant roster and the active speaker. It attaches read-only (never clicks or
/// types), polls at ~1.4 Hz, and degrades to nothing when Accessibility is not granted or Zoom is
/// not the meeting app.
///
/// Because the exact "who is talking" signal is UI-shape dependent and can differ per Zoom build,
/// every poll also appends a compact diagnostic (roster, mute states, spotlight, speaking markers,
/// and what CHANGED since the last poll) to `zoom-speaker-debug.log`. That auto-captures the real
/// signal from a live call under whatever conditions the user is in, so tuning never needs a manual
/// tree dump.
final class ZoomSpeakerReader: @unchecked Sendable {
    static let zoomBundleId = "us.zoom.xos"

    private var task: Task<Void, Never>?

    // AX attribute name literals (avoid the non-Sendable kAX… globals).
    private static let axChildren = "AXChildren"
    private static let axRole = "AXRole"
    private static let axSubrole = "AXSubrole"
    private static let axTitle = "AXTitle"
    private static let axValue = "AXValue"
    private static let axDescription = "AXDescription"
    private static let axWindows = "AXWindows"

    var isRunning: Bool { task != nil }

    /// Whether the Zoom desktop app is currently running (a prerequisite for reading it).
    static func zoomIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleId).isEmpty
    }

    /// Begin polling Zoom for the active speaker. `onActiveSpeaker` fires when the active speaker
    /// changes: a name when someone is talking, `nil` when nobody is (so the open span is closed
    /// and one speaker's name does not bleed onto the next). Called on a background task.
    func start(onActiveSpeaker: @escaping @Sendable (String?) -> Void) {
        stop()
        SKLog.info(.session, "Zoom speaker reader: starting (accessibility=\(Permission.accessibilityStatus().rawValue))")
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var last: String??            // nil = never reported; .some(nil) = reported "no speaker"
            var previousTree: AXNode?
            var lastDiag = Date.distantPast
            while !Task.isCancelled {
                let tree = self.readTree()
                let roster = tree.map { ZoomAX.roster(in: $0) } ?? []
                let active = tree.flatMap { ZoomAX.activeSpeaker(in: $0, roster: roster) }

                let value: String? = active?.name
                if last == nil || last! != value {
                    last = .some(value)
                    onActiveSpeaker(value)
                }

                // Auto-capture: append a diagnostic at most every ~2s, but only while there is a
                // meeting worth logging (a known roster or an active speaker) so an idle Zoom does
                // not spam the log.
                if let tree, active != nil || !roster.isEmpty,
                   Date().timeIntervalSince(lastDiag) >= 2.0 {
                    lastDiag = Date()
                    let diag = ZoomAX.diagnostics(in: tree, previous: previousTree, roster: roster)
                    self.appendDebug(diag, activeStrategy: active?.strategy)
                    previousTree = tree
                }

                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Debug: manual full dump (Settings → Speaker tags → Dump Zoom accessibility tree)

    /// An indented dump of Zoom's whole accessibility tree, for identifying nodes during a live
    /// call. Still available as a manual escape hatch; routine tuning uses `zoom-speaker-debug.log`.
    func dumpTree(maxDepth: Int = 25) -> String {
        guard let tree = readTree(maxDepth: maxDepth) else { return "Zoom is not running (or no AX element)." }
        var out = "Zoom AX tree (accessibility=\(Permission.accessibilityStatus().rawValue)):\n"
        var nodes = 0
        func render(_ node: AXNode, depth: Int) {
            nodes += 1
            var line = String(repeating: "  ", count: max(0, depth)) + node.role
            if let s = node.subrole, !s.isEmpty { line += " [\(s)]" }
            if let t = node.title, !t.isEmpty { line += " title=\"\(t)\"" }
            if let v = node.value, !v.isEmpty { line += " value=\"\(v)\"" }
            if let d = node.desc, !d.isEmpty { line += " desc=\"\(d)\"" }
            out += line + "\n"
            for c in node.children { render(c, depth: depth + 1) }
        }
        render(tree, depth: 0)
        out += "(\(nodes) nodes)\n"
        // Also surface the interpreters' current read, so the dump is self-checking.
        let roster = ZoomAX.roster(in: tree)
        out += "roster: \(roster.joined(separator: ", "))\n"
        out += "activeSpeaker: \(ZoomAX.activeSpeaker(in: tree, roster: roster).map { "\($0.name) [\($0.strategy)]" } ?? "(none)")\n"
        return out
    }

    // MARK: - AX → AXNode

    private func readTree(maxDepth: Int = 40) -> AXNode? {
        guard let app = zoomAppElement() else { return nil }
        return buildNode(app, depth: 0, maxDepth: maxDepth)
    }

    private func buildNode(_ el: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        let kids = depth < maxDepth ? children(el).map { buildNode($0, depth: depth + 1, maxDepth: maxDepth) } : []
        return AXNode(
            role: string(el, Self.axRole) ?? "?",
            subrole: string(el, Self.axSubrole),
            title: string(el, Self.axTitle),
            value: string(el, Self.axValue),
            desc: string(el, Self.axDescription),
            children: kids
        )
    }

    private func zoomAppElement() -> AXUIElement? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.zoomBundleId).first else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        copyAttr(el, attr) as? String
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        if let kids = copyAttr(el, Self.axChildren) as? [AXUIElement] { return kids }
        // The app element exposes windows rather than children at the top.
        if let wins = copyAttr(el, Self.axWindows) as? [AXUIElement] { return wins }
        return []
    }

    // MARK: - Auto-capture log

    private func appendDebug(_ body: String, activeStrategy: String?) {
        let url = SKLog.directory.appendingPathComponent("zoom-speaker-debug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = activeStrategy.map { "active=\($0)" } ?? "active=(none)"
        let block = "── \(stamp)  \(header)\n\(body)\n"
        try? FileManager.default.createDirectory(at: SKLog.directory, withIntermediateDirectories: true)
        if let data = block.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
