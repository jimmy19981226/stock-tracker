import Charts
import SwiftUI

/// Premium dark design language: midnight-blue gradient background, signature
/// green accent (#00C805), orange-red for losses (#FF5000), big bold numbers,
/// and flat surfaces with hairline separators instead of bordered cards.
enum Theme {
    /// Brand accent — ocean blue (#0A84FF), crisp against the midnight-blue gradient.
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.00)

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

    static let cornerRadius: CGFloat = 18

    // MARK: - Colour discipline
    //
    // Three jobs, three sources of colour — and nothing else gets a hue:
    //   * `accent`   — interactive/brand. Controls, links, selection.
    //   * `positive` / `negative` — semantic, and ONLY ever on a P&L *value*.
    //   * text tokens — every label, caption, unit and heading.
    // A label tinted blue here, violet there and orange somewhere else is what
    // makes a screen read as assembled rather than designed, so labels never
    // carry a hue: the coloured number beside them already says what they mean.

    /// A faint wash of a colour for a chip/badge background. Saturated blocks
    /// shout; a 14% wash with the colour kept on the text reads as considered
    /// and stays legible on the dark surface.
    static func wash(_ color: Color) -> Color { color.opacity(0.14) }

    /// Green when up, red when down, muted when flat/unknown.
    static func pl(_ value: Double?) -> Color {
        guard let v = value, !v.isNaN else { return mutedText }
        if v > 0 { return positive }
        if v < 0 { return negative }
        return secondaryText
    }

    // MARK: - Type scale
    //
    // A fixed ladder, so sizes are chosen from a system rather than invented
    // per view (the surest way to look generated). Rounded design throughout —
    // it's the app's voice and matches the numeric-heavy content.

    enum Typo {
        /// The one number a screen leads with.
        static let hero = Font.system(size: 40, weight: .bold, design: .rounded)
        static let title = Font.system(size: 26, weight: .bold, design: .rounded)
        static let section = Font.system(size: 17, weight: .bold, design: .rounded)
        static let value = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 15, weight: .regular, design: .rounded)
        static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
        /// Uppercase eyebrow labels. Pair with `.tracking(0.5)`.
        static let label = Font.system(size: 11, weight: .semibold, design: .rounded)
        static let micro = Font.system(size: 10, weight: .semibold, design: .rounded)
    }

    // MARK: - Spacing
    //
    // A 4pt ladder. Gaps come from here so rhythm is consistent across screens.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
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
            // Bright ocean-blue bloom at the top-right corner.
            RadialGradient(
                colors: [
                    Color(red: 0.04, green: 0.40, blue: 0.90).opacity(0.22),
                    .clear,
                ],
                center: UnitPoint(x: 0.88, y: 0.04),
                startRadius: 0,
                endRadius: 380
            )
            // Softer cyan counter-glow at the bottom-left for depth.
            RadialGradient(
                colors: [
                    Color(red: 0.04, green: 0.55, blue: 0.75).opacity(0.12),
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
        content.cardStyle(padding: padding)
    }
}

extension View {
    /// Standard screen background — midnight-blue gradient with aurora blooms.
    func screenBackground() -> some View {
        self.background(
            Theme.backgroundGradient.ignoresSafeArea()
        )
    }

    /// The card chrome, shared by `Card` and call-site wrapping. Depth comes
    /// from three subtle layers — fill, a 1px light edge on the top-facing
    /// rim, and a soft drop shadow — rather than flat panels or hairline
    /// boxes, which is what makes surfaces read as designed, not generated.
    func cardStyle(padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        return self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    /// Chrome for a floating **navigation-layer** element — a pinned bar, a
    /// toolbar affordance, a floating control.
    ///
    /// On iOS 26 this is real Liquid Glass; below it, the material + rim-light
    /// approximation. Deliberately NOT applied to cards, rows or backgrounds:
    /// Apple's guidance is that glass belongs to the navigation layer floating
    /// above the content, and glass-on-content (or glass stacked on glass) is
    /// what turns the effect from depth into noise.
    @ViewBuilder
    func navGlass(in shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                )
                .clipShape(shape)
        }
    }

    /// A soft tinted chip — the quiet alternative to a saturated block. The
    /// colour lives in the text and a 14% wash, so a small stat can't shout
    /// louder than the number it annotates.
    func chip(_ color: Color, radius: CGFloat = 8) -> some View {
        self.padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.wash(color))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A value scale for a money chart: three hairline gridlines with compact
    /// labels on the trailing edge.
    ///
    /// These charts previously hid the y-axis entirely, which made the curve
    /// decorative — the only way to read any value was to scrub it. A tooltip
    /// should enhance, never gate, so the rail carries the magnitudes and the
    /// scrub tip carries the precision.
    func moneyValueScale(currency: String) -> some View {
        self.chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { mark in
                AxisGridLine().foregroundStyle(Theme.stroke.opacity(0.55))
                AxisValueLabel {
                    if let v = mark.as(Double.self) {
                        Text(Fmt.compactMoney(v, currency: currency))
                            .font(Theme.Typo.micro)
                            .foregroundStyle(Theme.mutedText)
                    }
                }
            }
        }
    }

    /// Groups rows inside a card by *spacing and weight* rather than by drawing
    /// a hairline under each one. Rules between every row read as a dated table;
    /// the eye separates rows perfectly well on rhythm alone.
    func statRow() -> some View {
        self.padding(.vertical, Theme.Space.s)
    }
}
