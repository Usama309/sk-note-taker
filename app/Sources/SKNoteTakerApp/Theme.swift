import SwiftUI

/// SK Note Taker brand system — indigo→teal gradient over a deep slate base.
enum Theme {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    static let teal = Color(red: 0.08, green: 0.72, blue: 0.65)     // #14B8A6
    static let ink = Color(red: 0.043, green: 0.067, blue: 0.125)   // #0B1120

    static let accentGradient = LinearGradient(
        colors: [indigo, teal], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Distinct, stable hue per speaker key (S1 teal, S2 indigo, then rotating).
    static func speakerColor(_ key: String) -> Color {
        let palette: [Color] = [
            teal,                                            // S1 — me
            indigo,                                          // S2
            Color(red: 0.91, green: 0.45, blue: 0.25),       // S3 orange
            Color(red: 0.78, green: 0.31, blue: 0.75),       // S4 magenta
            Color(red: 0.28, green: 0.62, blue: 0.92),       // S5 sky
            Color(red: 0.65, green: 0.75, blue: 0.20),       // S6 lime
        ]
        let number = Int(key.dropFirst()) ?? 1
        return palette[(number - 1) % palette.count]
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The logo mark: rounded gradient square with soundwave bars (mirrors assets/logo.svg).
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Theme.accentGradient)
            HStack(spacing: size * 0.09) {
                bar(0.32); bar(0.55); bar(0.80); bar(0.45); bar(0.62)
            }
        }
        .frame(width: size, height: size)
    }

    private func bar(_ scale: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.075, height: size * scale * 0.72)
    }
}

struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("SK Note Taker")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("AI meeting notes")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
