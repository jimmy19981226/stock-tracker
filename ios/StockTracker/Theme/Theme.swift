import SwiftUI

/// Premium dark design language: midnight-blue gradient background, signature
/// green accent (#00C805), orange-red for losses (#FF5000), big bold numbers,
/// and flat surfaces with hairline separators instead of bordered cards.
enum Theme {
    /// Brand accent — violet (#BF5AF2), chosen to complement the midnight-blue
    /// gradient and aurora blooms that define the app's visual identity.
    static let accent = Color(red: 0.75, green: 0.35, blue: 0.95)

    // Backgrounds — deep midnight-blue with subtle tinted dark surfaces.
    static let bg = Color(red: 0.01, green: 0.01, blue: 0.05)
    static let card = Color(red: 0.08, green: 0.09, blue: 0.17)
    static let cardElevated = Color(red: 0.12, green: 0.13, blue: 0.23)
    static let stroke = Color.white.opacity(0.10)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.65)
    static let mutedText = Color.white.opacity(0.42)

    // P&L semantics (green / orange-red)
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

    /// The base gradient used by screenBackground() — exposed so overlays
    /// (e.g. sheet presentations) can match the app background.
    static var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.16),
                    Color(red: 0.02, green: 0.02, blue: 0.09),
                    Color(red: 0.01, green: 0.00, blue: 0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle indigo aurora bloom at the top-right corner.
            RadialGradient(
                colors: [
                    Color(red: 0.38, green: 0.18, blue: 0.68).opacity(0.22),
                    .clear,
                ],
                center: UnitPoint(x: 0.88, y: 0.04),
                startRadius: 0,
                endRadius: 380
            )
            // Softer teal counter-glow at the bottom-left for depth.
            RadialGradient(
                colors: [
                    Color(red: 0.04, green: 0.38, blue: 0.52).opacity(0.12),
                    .clear,
                ],
                center: UnitPoint(x: 0.08, y: 0.90),
                startRadius: 0,
                endRadius: 300
            )
        }
    }
}

/// A flat dark surface (no border) — section container.
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
    /// Standard screen background — midnight-blue gradient with aurora blooms.
    func screenBackground() -> some View {
        self.background(
            Theme.backgroundGradient.ignoresSafeArea()
        )
    }
}
