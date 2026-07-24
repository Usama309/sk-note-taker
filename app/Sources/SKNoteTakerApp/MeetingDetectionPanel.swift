import SwiftUI
import AppKit
import SKNoteCore

@Observable @MainActor
final class DetectionPanelModel {
    var appName = ""
    var progress: Double = 0      // 0 → 1 as the bar fills left→right over the 40s window
    var paused = false
}

/// Custom floating "you're in a meeting" popup: top-right of the screen, above all apps (even a
/// fullscreen call), stays ~40s with a bar that fills left→right, and a Start CTA that launches
/// straight into compact mode. A system notification can't control its lifetime, draw the bar, or
/// choose the launch target — this can.
@MainActor
final class MeetingDetectionPanel {
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private let model = DetectionPanelModel()
    private var onStart: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private let duration: Double = 40

    func show(appName: String,
              onStartNotes: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        close()
        self.onStart = onStartNotes
        self.onDismiss = onDismiss
        model.appName = appName
        model.progress = 0
        model.paused = false

        let width: CGFloat = 384, height: CGFloat = 118
        let hosting = NSHostingView(rootView: DetectionPanelView(
            model: model,
            onStart: { [weak self] in self?.fire(start: true) },
            onDismiss: { [weak self] in self?.fire(start: false) }))
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
                if self.model.paused { continue }        // hover freezes the countdown
                elapsed += 0.05
                self.model.progress = min(1, elapsed / self.duration)
                if elapsed >= self.duration { self.fire(start: false); return }
            }
        }
    }

    private func fire(start: Bool) {
        let s = onStart, d = onDismiss
        close()
        if start { s?() } else { d?() }
    }

    func close() {
        ticker?.cancel(); ticker = nil
        panel?.orderOut(nil); panel = nil
        onStart = nil; onDismiss = nil
    }
}

struct DetectionPanelView: View {
    @Bindable var model: DetectionPanelModel
    let onStart: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.appName) meeting started")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Take notes with SK Note Taker")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onStart) {
                    Text("Start")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Theme.accentGradient,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            // Countdown bar: fills from the left edge to the right over the full 40s window.
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
                .strokeBorder(Color.primary.opacity(0.08)))
        // macOS-style close chip, top-left corner, revealed on hover.
        .overlay(alignment: .topLeading) {
            CloseChip(action: onDismiss)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .offset(x: -7, y: -7)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .padding(12)
        .onHover { h in
            hovering = h
            model.paused = h
        }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

/// The small grey circle-with-x that macOS shows at the top-left of a notification.
private struct CloseChip: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12))))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Dismiss")
    }
}
