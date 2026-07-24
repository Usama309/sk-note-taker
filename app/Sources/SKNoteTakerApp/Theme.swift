import SwiftUI

/// SK Note Taker brand system — indigo→teal gradient over a deep slate base.
enum Theme {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)   // #4F46E5
    static let teal = Color(red: 0.08, green: 0.72, blue: 0.65)     // #14B8A6
    static let ink = Color(red: 0.043, green: 0.067, blue: 0.125)   // #0B1120

    static let accentGradient = LinearGradient(
        colors: [indigo, teal], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Distinct, stable hue per speaker key (S1 teal, S2 indigo, then rotating).
    /// Shades are picked for ≥4.5:1 contrast on the app's light surfaces — speaker names
    /// render as small bold text, so brighter brand tints don't hold up.
    static func speakerColor(_ key: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.05, green: 0.46, blue: 0.43),       // S1 deep teal — me
            indigo,                                          // S2 #4F46E5
            Color(red: 0.76, green: 0.25, blue: 0.05),       // S3 burnt orange
            Color(red: 0.64, green: 0.11, blue: 0.66),       // S4 magenta
            Color(red: 0.01, green: 0.41, blue: 0.63),       // S5 deep sky
            Color(red: 0.30, green: 0.49, blue: 0.06),       // S6 olive
        ]
        let number = Int(key.dropFirst()) ?? 1
        return palette[(number - 1) % palette.count]
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension Theme {
    /// One card corner radius across the whole app (was a mix of 12 / 14 / 16).
    static let cardRadius: CGFloat = 14
    static let hairline = Color.primary.opacity(0.06)
}

extension View {
    /// The standard card surface used across every screen: a fill appropriate to the context,
    /// continuous corners at the shared radius, a hairline border, and a subtle lift shadow.
    /// Pass a tinted fill for cards on plain backgrounds; the default suits the detail rail.
    func skCard<S: ShapeStyle>(_ fill: S, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.05), radius: 7, y: 2)
    }

    func skCard(padding: CGFloat = 14) -> some View { skCard(.background, padding: padding) }
}

extension Color {
    /// Parse a Google calendar colour like "#a4bdfc". Falls back to grey on a bad string.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        var value: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&value) else {
            self = .gray; return
        }
        self = Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
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
