import SwiftUI

/// A placeholder block with a soft moving shimmer, used instead of a spinner while content loads.
/// Reduce Motion gets a static fill (no sweep), so the shape still communicates "loading" without
/// animation.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6

    @State private var sweep = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.skeletonBase)
            .frame(width: width, height: height)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Theme.skeletonSheen, .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.55)
                            .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
    }
}

/// A few stacked text lines, for paragraph-shaped content (summary, transcript body).
struct SkeletonLines: View {
    var count = 3
    var spacing: CGFloat = 9
    /// Last line renders short, the way real paragraphs end.
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                SkeletonBlock(width: i == count - 1 ? 180 : nil, height: 11)
            }
        }
    }
}

/// Placeholder rows for a list that is still loading.
struct SkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBlock(width: 30, height: 30, radius: 9)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(height: 11)
                        SkeletonBlock(width: 120, height: 9)
                    }
                }
            }
        }
    }
}

/// The transcript's loading shape: alternating speaker bubbles.
struct SkeletonTranscript: View {
    var count = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBlock(width: 90, height: 10)
                    SkeletonBlock(width: i.isMultiple(of: 2) ? 340 : 260, height: 11)
                    if i.isMultiple(of: 3) { SkeletonBlock(width: 200, height: 11) }
                }
            }
        }
    }
}
