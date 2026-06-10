import SwiftUI

/// Robinhood-style design language: true-black background, signature green
/// accent (#00C805), orange-red for losses (#FF5000), big bold numbers, and
/// flat surfaces with hairline separators instead of bordered cards.
enum Theme {
    /// Robinhood green.
    static let accent = Color(red: 0.0, green: 0.78, blue: 0.02)

    // Backgrounds — pure black with subtle dark surfaces.
    static let bg = Color.black
    static let card = Color(red: 0.07, green: 0.075, blue: 0.08)
    static let cardElevated = Color(red: 0.11, green: 0.115, blue: 0.12)
    static let stroke = Color.white.opacity(0.08)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.65)
    static let mutedText = Color.white.opacity(0.42)

    // P&L semantics (Robinhood green / orange-red)
    static let positive = Color(red: 0.0, green: 0.78, blue: 0.02)
    static let negative = Color(red: 1.0, green: 0.31, blue: 0.0)

    static let cornerRadius: CGFloat = 14

    /// Green when up, red when down, muted when flat/unknown.
    static func pl(_ value: Double?) -> Color {
        guard let v = value, !v.isNaN else { return mutedText }
        if v > 0 { return positive }
        if v < 0 { return negative }
        return secondaryText
    }
}

/// A flat dark surface (no border) — Robinhood-style section container.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    /// Standard screen background for every tab.
    func screenBackground() -> some View {
        self.background(Theme.bg.ignoresSafeArea())
    }
}
