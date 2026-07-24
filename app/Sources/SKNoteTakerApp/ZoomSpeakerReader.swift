import Foundation
import AppKit
import ApplicationServices
import SKNoteCore

/// Reads the Zoom desktop app's UI over the macOS Accessibility API to learn who the active
/// speaker is, so their real name can be attached to the transcript (Granola-style speaker tags).
///
/// Zoom exposes no API for this, so the active-speaker extraction is UI-shape dependent and must
/// be tuned against a live call. `dumpTree()` prints Zoom's accessibility hierarchy so the exact
/// name/active-speaker nodes can be identified; `currentActiveSpeaker()` is the extractor refined
/// from that. The reader attaches read-only (it never clicks or types), polls at ~1.4 Hz, and
/// degrades to nothing when Accessibility is not granted or Zoom is not the meeting app.
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

    /// Begin polling Zoom for the active speaker. `onActiveSpeaker` fires only when the name
    /// changes, on the main actor.
    func start(onActiveSpeaker: @escaping @Sendable (String) -> Void) {
        stop()
        SKLog.info(.session, "Zoom speaker reader: starting (accessibility=\(Permission.accessibilityStatus().rawValue))")
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var last: String?
            while !Task.isCancelled {
                if let name = self.currentActiveSpeaker(), name != last {
                    last = name
                    onActiveSpeaker(name)
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Extraction (refined against a live Zoom call)

    /// The current active speaker's display name, or nil if it can't be determined.
    ///
    /// PROVISIONAL: this heuristic is a starting point. Run `dumpTree()` during a live Zoom call
    /// to see the real hierarchy, then tighten the match. Today it looks for a static-text node
    /// whose accessibility description/parent marks it as the active or talking participant.
    func currentActiveSpeaker() -> String? {
        guard let app = zoomAppElement() else { return nil }
        var found: String?
        walk(app, depth: 0, maxDepth: 40) { el, _ in
            let role = self.string(el, Self.axRole) ?? ""
            let desc = self.string(el, Self.axDescription) ?? ""
            let value = self.string(el, Self.axValue) ?? ""
            let title = self.string(el, Self.axTitle) ?? ""
            let hay = (desc + " " + value + " " + title).lowercased()
            // Zoom tends to describe the active tile with words like "active speaker" / "talking".
            if role == "AXStaticText" || role == "AXImage" {
                if hay.contains("active speaker") || hay.contains("is talking") || hay.contains("speaking") {
                    let name = Self.nameFrom(description: desc) ?? (value.isEmpty ? title : value)
                    if !name.isEmpty { found = name; return false }
                }
            }
            return true   // keep walking
        }
        return found
    }

    /// Pull a name out of a Zoom accessibility description like "Alice Smith, active speaker".
    static func nameFrom(description: String) -> String? {
        let first = description
            .components(separatedBy: CharacterSet(charactersIn: ",("))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - Debug: dump the whole tree so we can find the real nodes live

    /// Walks Zoom's accessibility tree and returns an indented dump of roles + text, for
    /// identifying the exact active-speaker / participant nodes during a live call.
    func dumpTree(maxDepth: Int = 25, maxNodes: Int = 1500) -> String {
        guard let app = zoomAppElement() else { return "Zoom is not running (or no AX element)." }
        var out = "Zoom AX tree (accessibility=\(Permission.accessibilityStatus().rawValue)):\n"
        var nodes = 0
        walk(app, depth: 0, maxDepth: maxDepth) { el, depth in
            nodes += 1
            if nodes > maxNodes { return false }
            let role = self.string(el, Self.axRole) ?? "?"
            let sub = self.string(el, Self.axSubrole)
            let title = self.string(el, Self.axTitle)
            let value = self.string(el, Self.axValue)
            let desc = self.string(el, Self.axDescription)
            var line = String(repeating: "  ", count: max(0, depth)) + role
            if let sub, !sub.isEmpty { line += " [\(sub)]" }
            if let title, !title.isEmpty { line += " title=\"\(title)\"" }
            if let value, !value.isEmpty { line += " value=\"\(value)\"" }
            if let desc, !desc.isEmpty { line += " desc=\"\(desc)\"" }
            out += line + "\n"
            return true
        }
        out += "(\(nodes) nodes)\n"
        return out
    }

    // MARK: - AX plumbing

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

    /// Depth-first walk; `visit(element, depth)` returns false to stop the whole walk early.
    @discardableResult
    private func walk(_ el: AXUIElement, depth: Int, maxDepth: Int,
                      _ visit: (AXUIElement, Int) -> Bool) -> Bool {
        guard depth <= maxDepth else { return true }
        if !visit(el, depth) { return false }
        for child in children(el) {
            if !walk(child, depth: depth + 1, maxDepth: maxDepth, visit) { return false }
        }
        return true
    }
}
