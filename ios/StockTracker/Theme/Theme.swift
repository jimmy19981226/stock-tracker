import SwiftUI

/// Centralized colors, spacing and reusable view styling so every screen shares
/// one iOS-native dark "studio" look (deep navy surfaces, teal accent, the
/// green/red P&L semantics carried over from the web app).
enum Theme {
    static let accent = Color(red: 0.18, green: 0.62, blue: 0.95)

    // Backgrounds
    static let bg = Color(red: 0.05, green: 0.06, blue: 0.09)
    static let card = Color(red: 0.09, green: 0.10, blue: 0.14)
    static let cardElevated = Color(red: 0.12, green: 0.14, blue: 0.19)
    static let stroke = Color.white.opacity(0.07)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let mutedText = Color.white.opacity(0.40)

    // P&L semantics
    static let positive = Color(red: 0.20, green: 0.80, blue: 0.52)
    static let negative = Color(red: 0.98, green: 0.36, blue: 0.42)

    static let cornerRadius: CGFloat = 18

    /// Green when up, red when down, muted when flat/unknown.
    static func pl(_ value: Double?) -> Color {
        guard let v = value, !v.isNaN else { return mutedText }
        if v > 0 { return positive }
        if v < 0 { return negative }
        return secondaryText
    }
}

/// A rounded "card" container used across the app for an iOS grouped-list feel.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    /// Standard screen background for every tab.
    func screenBackground() -> some View {
        self.background(Theme.bg.ignoresSafeArea())
    }
}
