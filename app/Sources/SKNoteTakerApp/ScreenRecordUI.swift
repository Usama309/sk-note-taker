import SwiftUI
import AppKit
import ScreenCaptureKit
import SKNoteCore

/// Carries a non-Sendable `SCContentFilter` across a `Task` boundary. Safe: constructed once from a
/// picked source and consumed once when the recording starts.
struct SendableSCFilter: @unchecked Sendable {
    let value: SCContentFilter
    init(_ value: SCContentFilter) { self.value = value }
}

/// A click-through accent outline drawn over a window/display on screen, so hovering a row in the
/// picker shows exactly what will be recorded.
@MainActor
final class WindowHighlightOverlay {
    private var panel: NSPanel?

    /// Show the outline at `cgRect` — ScreenCaptureKit's global frame (points, top-left origin).
    func show(cgRect: CGRect) {
        guard let rect = Self.toAppKit(cgRect), rect.width > 1, rect.height > 1 else { hide(); return }
        let panel = self.panel ?? makePanel()
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver           // above the picker sheet so the outline is actually visible
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true      // click-through: never steals the hover
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = 4
        view.layer?.borderColor = NSColor(Theme.accent).cgColor
        view.layer?.cornerRadius = 9     // border only; no fill, so it never tints the whole screen
        p.contentView = view
        return p
    }

    /// Convert a ScreenCaptureKit rect (top-left origin, relative to the primary display) to the
    /// AppKit global coordinate space (bottom-left origin).
    private static func toAppKit(_ cg: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        return NSRect(x: cg.origin.x,
                      y: primaryHeight - cg.origin.y - cg.height,
                      width: cg.width, height: cg.height)
    }
}

// MARK: - Top-right "record your screen?" popup (same style as the note-taking popup)

@Observable @MainActor
final class ScreenRecordPromptModel {
    var progress: Double = 0
    var paused = false
}

/// A floating top-right notification asking whether to record the screen. Modeled on
/// `MeetingDetectionPanel`: above all apps, hover pauses, auto-dismisses. Offers a one-click
/// "Whole screen" and a "Choose window" that opens the in-app source picker.
@MainActor
final class ScreenRecordPromptPanel {
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private let model = ScreenRecordPromptModel()
    private let duration: Double = 25

    func show(onWholeScreen: @escaping () -> Void,
              onChoose: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        close()
        model.progress = 0
        model.paused = false

        let width: CGFloat = 384, height: CGFloat = 150
        let hosting = NSHostingView(rootView: ScreenRecordPromptView(
            model: model,
            onWholeScreen: { [weak self] in self?.close(); onWholeScreen() },
            onChoose: { [weak self] in self?.close(); onChoose() },
            onDismiss: { [weak self] in self?.close(); onDismiss() }))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        if let vf = NSScreen.main?.visibleFrame {
            let margin: CGFloat = 12
            panel.setFrameOrigin(NSPoint(x: vf.maxX - width - margin, y: vf.maxY - height - margin))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        ticker = Task { [weak self] in
            var elapsed = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if self.model.paused { continue }
                elapsed += 0.05
                self.model.progress = min(1, elapsed / self.duration)
                if elapsed >= self.duration { self.close(); return }
            }
        }
    }

    func close() {
        ticker?.cancel(); ticker = nil
        panel?.orderOut(nil); panel = nil
    }
}

struct ScreenRecordPromptView: View {
    @Bindable var model: ScreenRecordPromptModel
    let onWholeScreen: () -> Void
    let onChoose: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var hoveredAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accentTextGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record your screen?")
                        .font(.skSubtitle).foregroundStyle(.primary)
                    Text("Capture a window or the whole screen with this meeting.")
                        .font(.skCallout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: onChoose) {
                    Text("Choose window")
                        .font(.skSubtitle)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Theme.accentGradient,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .scaleEffect(hoveredAction == "choose" ? 1.05 : 1)
                .onHover { hoveredAction = $0 ? "choose" : nil }
                Button(action: onWholeScreen) {
                    Text("Whole screen")
                        .font(.skSubtitle)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.quaternary,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .scaleEffect(hoveredAction == "whole" ? 1.05 : 1)
                .onHover { hoveredAction = $0 ? "whole" : nil }
                Spacer(minLength: 0)
            }
            .animation(Theme.Motion.snap, value: hoveredAction)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(0, geo.size.width * model.progress))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border))
        .overlay(alignment: .topLeading) {
            CloseChip(action: onDismiss)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .offset(x: -7, y: -7)
        }
        .shadow(color: Theme.cardShadow, radius: 14, y: 5)
        .padding(12)
        .onHover { h in hovering = h; model.paused = h }
        .animation(Theme.Motion.snap, value: hovering)
    }
}

// MARK: - In-app source picker (reliable, does not fight the meeting's audio capture)

/// A sheet listing the displays and open windows to record. Picking one builds an `SCContentFilter`
/// ourselves and hands it back — avoiding `SCContentSharingPicker`, which collides with the running
/// system-audio stream and shows the "Currently Sharing" control instead of a chooser.
struct ScreenSourceSheet: View {
    let onPick: (SCContentFilter) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var hovered: String?
    @State private var thumbs: [String: NSImage] = [:]
    @State private var overlay = WindowHighlightOverlay()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose what to record").font(.skTitle)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if let errorText {
                ContentUnavailableView("Can't list your screens", systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Entire screen") {
                        ForEach(displays, id: \.displayID) { d in
                            sourceRow(id: "disp-\(d.displayID)",
                                      title: "Whole screen  (\(d.width)×\(d.height))",
                                      subtitle: nil, icon: nil, systemIcon: "display", frame: d.frame,
                                      makeFilter: { SCContentFilter(display: d, excludingApplications: [], exceptingWindows: []) })
                        }
                    }
                    Section("A window") {
                        if windows.isEmpty {
                            Text("No shareable windows open").foregroundStyle(.secondary)
                        }
                        ForEach(windows, id: \.windowID) { w in
                            sourceRow(id: "win-\(w.windowID)",
                                      title: w.owningApplication?.applicationName ?? "Window",
                                      subtitle: (w.title?.isEmpty == false) ? w.title : nil,
                                      icon: appIcon(w), systemIcon: "macwindow", frame: w.frame,
                                      makeFilter: { SCContentFilter(desktopIndependentWindow: w) })
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 520)
        .task { await load() }
        .onDisappear { overlay.hide() }
    }

    /// One selectable source. Hovering highlights the real window/display on screen and loads a
    /// thumbnail so the user sees exactly what will be recorded before picking.
    @ViewBuilder
    private func sourceRow(id: String, title: String, subtitle: String?, icon: NSImage?,
                           systemIcon: String, frame: CGRect,
                           makeFilter: @escaping () -> SCContentFilter) -> some View {
        Button { pick(makeFilter()) } label: {
            HStack(spacing: 10) {
                thumbView(id: id, icon: icon, systemIcon: systemIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.skSubtitle)
                    if let subtitle { Text(subtitle).font(.skCaption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered == id ? 1.015 : 1, anchor: .leading)
        .listRowBackground(hovered == id ? Theme.selection : Color.clear)
        .animation(Theme.Motion.snap, value: hovered)
        .onHover { h in
            if h {
                hovered = id
                overlay.show(cgRect: frame)
                loadThumb(id: id, makeFilter: makeFilter)
            } else if hovered == id {
                hovered = nil
                overlay.hide()
            }
        }
    }

    @ViewBuilder
    private func thumbView(id: String, icon: NSImage?, systemIcon: String) -> some View {
        if let thumb = thumbs[id] {
            Image(nsImage: thumb)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
        } else if let icon {
            Image(nsImage: icon).resizable().frame(width: 26, height: 26).frame(width: 64, height: 40)
        } else {
            Image(systemName: systemIcon).font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(width: 64, height: 40)
        }
    }

    private func loadThumb(id: String, makeFilter: () -> SCContentFilter) {
        guard thumbs[id] == nil else { return }
        let box = SendableSCFilter(makeFilter())
        Task {
            let cfg = SCStreamConfiguration()
            cfg.width = 480; cfg.height = 300
            cfg.scalesToFit = true; cfg.showsCursor = false
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: box.value, configuration: cfg) {
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                thumbs[id] = img
            }
        }
    }

    private func pick(_ filter: SCContentFilter) {
        overlay.hide()
        onPick(filter)
        dismiss()
    }

    private func appIcon(_ w: SCWindow) -> NSImage? {
        guard let pid = w.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    private func load() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let mine = Bundle.main.bundleIdentifier
            displays = content.displays
            windows = content.windows
                .filter { w in
                    w.isOnScreen
                        && (w.frame.width * w.frame.height) >= 40_000
                        && (w.title?.isEmpty == false)
                        && w.owningApplication?.bundleIdentifier != mine
                }
                .sorted {
                    ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "")
                }
            loaded = true
        } catch {
            errorText = "Screen Recording permission is required. Turn it on in System Settings › Privacy & Security › Screen Recording, then reopen SK Note Taker."
            loaded = true
        }
    }
}
