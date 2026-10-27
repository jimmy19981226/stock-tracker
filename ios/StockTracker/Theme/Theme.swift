import Charts
import SwiftUI
import UIKit

/// Studio 2: warm neutral surfaces, crisp native type and a deep teal accent.
/// Semantic tokens keep every screen and both appearances consistent.
enum Theme {

    /// A colour that resolves per theme. The single place either palette is
    /// selected, so adding a token can never accidentally define only one half.
    private static func dyn(light: UInt32, dark: UInt32,
                            lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    /// Screen background.
    static let ground = dyn(light: 0xF5F6F3, dark: 0x101513)
    /// Card / row background — the surface almost all content sits on.
    static let card = dyn(light: 0xFFFFFF, dark: 0x1B2220)
    /// Nav + tab bar fill, layered over `.ultraThinMaterial`.
    static let chrome = dyn(light: 0xF5F6F3, dark: 0x101513, lightAlpha: 0.94, darkAlpha: 0.94)
    /// A recessed row inside a card — the expanded index bar's cards.
    static let inset = dyn(light: 0xF1F3F0, dark: 0x242D29)
    /// Segmented-control track, progress track, unselected pill fill.
    static let track = dyn(light: 0xE9EDE8, dark: 0x2C3631)
    /// 1px hairline divider. Used *within* a card to separate a summary line
    /// from its detail, and between rows of a long list — never as a box.
    static let line = dyn(light: 0xE4E9E3, dark: 0x344039)

    /// Primary text.
    static let text = dyn(light: 0x172820, dark: 0xF1F5F0)
    /// Labels, captions, units — everything that annotates a number.
    static let textSecondary = dyn(light: 0x65736B, dark: 0xA4B2A8)
    /// The inline company name beside a ticker: quieter than primary, louder
    /// than a caption. Extends the handoff table, which stops at two text
    /// tokens but shows three weights in the holdings and trade rows.
    static let textStrong = dyn(light: 0x46574C, dark: 0xC1CCC3)
    /// Chevrons, the benchmark line, disabled glyphs — the quietest ink.
    static let textTertiary = dyn(light: 0x829187, dark: 0x7E9285)

    /// Interactive / brand. Selected states, links, the chart line.
    static let accent = dyn(light: 0x126B55, dark: 0x62C5A1)
    /// The selected tab glyph, a half-step brighter so it holds up against
    /// chrome at 25pt.
    static let onAccent = dyn(light: 0xFFFFFF, dark: 0x102A1E)
    static let accentSelected = dyn(light: 0x126B55, dark: 0x8AD9B9)
    /// Chip / badge fill. A wash, never a saturated block.
    static let accentTint = dyn(light: 0xE3F1EA, dark: 0x233E32)
    /// Text on `accentTint`.
    static let accentChipText = dyn(light: 0x19553F, dark: 0xA4E3C6)
    /// The muted accent used for area fills and weight bars.
    static let accentSoft = dyn(light: 0xB4DCC9, dark: 0x365F4C)

    /// The portfolio hero field; deep green in both appearances.
    static let heroTop = dyn(light: 0x19392D, dark: 0x1D3B2E)
    static let heroBottom = dyn(light: 0x12291F, dark: 0x192F25)
    /// Ink on the hero. Fixed, not theme-resolved: the field is dark in both.
    static let heroText = Color.white
    static let heroLabel = dyn(light: 0xBAD6C4, dark: 0xBAD6C4)
    static let heroRule = Color.white.opacity(0.16)

    /// Card shadow. Depth comes from fill + this, not from a hairline box.
    static let shadow = dyn(light: 0x1D1F20, dark: 0x020812, lightAlpha: 0.08, darkAlpha: 0.55)
    static let shadowStrong = dyn(light: 0x1D1F20, dark: 0x020812, lightAlpha: 0.18, darkAlpha: 0.70)
    /// The hero's drop shadow — deeper and further than a card's, because the
    /// dark field has to read as sitting above the ground, not printed on it.
    static let heroShadow = dyn(light: 0x1D2D3D, dark: 0x020812, lightAlpha: 0.28, darkAlpha: 0.55)
    /// Behind a bottom sheet.
    static let scrim = dyn(light: 0x1D1F20, dark: 0x040C16, lightAlpha: 0.45, darkAlpha: 0.62)

    // MARK: - P/L semantics
    //
    // `gain` and `loss` are the two *directions*, not the two colours. Which
    // hue each one wears is the user's `plConvention` — TW charts paint a rise
    // red — so nothing outside this file may name green or red. Every P&L
    // value goes through `pl(_:)`, and every P&L value pairs the colour with a
    // direction triangle, so the meaning never rests on hue alone.

    private static let greenInk = dyn(light: 0x17744F, dark: 0x7DD4A8)
    private static let redInk = dyn(light: 0xB3443F, dark: 0xF29B91)

    /// The colour a *rise* wears under the current convention.
    static var gain: Color { plConvention == .tw ? redInk : greenInk }
    /// The colour a *fall* wears under the current convention.
    static var loss: Color { plConvention == .tw ? greenInk : redInk }

    /// Gain when up, loss when down, secondary when flat or unknown.
    static func pl(_ value: Double?) -> Color {
        guard let v = value, !v.isNaN else { return textSecondary }
        if v > 0 { return gain }
        if v < 0 { return loss }
        return textSecondary
    }

    // MARK: - Geometry
    //
    // Shared geometry keeps cards, controls and navigation consistent.
    enum Radius {
        static let card: CGFloat = 24
        static let hero: CGFloat = 28
        static let inset: CGFloat = 14
        static let badge: CGFloat = 12
        static let segment: CGFloat = 14
        static let thumb: CGFloat = 11
        static let button: CGFloat = 14
        static let sheet: CGFloat = 22
        static let pill: CGFloat = 8
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 18

        /// Horizontal screen gutter.
        static let screenH: CGFloat = 22
        /// Top inset for a screen that carries no nav bar.
        ///
        /// The design measures 60pt from the physical top of the display; on a
        /// notched phone the safe-area inset already supplies ~59 of those, so
        /// this is the remainder. Adding the full 60 on top of the inset left a
        /// finger's width of dead space above every screen's first line.
        static let screenTop: CGFloat = 14
        /// Bottom inset above the tab bar.
        static let screenBottom: CGFloat = 24
        /// Between cards in a stack.
        static let cardGap: CGFloat = 22
        /// Between cells of a stat grid.
        static let gridGap: CGFloat = 10
    }

    /// Assistant controls and message rhythm, shared by welcome and chat.
    enum Assistant {
        static let control: CGFloat = 44
        static let mark: CGFloat = 36
        static let messageInset: CGFloat = 32
        static let attachment: CGFloat = 56
        static let illustration: CGFloat = 52
    }

    // MARK: - Typography
    // Native San Francisco. Text styles scale with the user's accessibility setting.
    enum Typo {
        static let signIn = Font.system(size: 40, weight: .bold, design: .rounded)
        static let hero = Font.system(size: 42, weight: .semibold, design: .rounded)
        static let title = Font.system(.largeTitle, design: .default, weight: .bold)
        static let display = Font.system(size: 36, weight: .semibold, design: .rounded)
        static let section = Font.system(size: 26, weight: .semibold, design: .rounded)
        static let heading = Font.system(.title2, weight: .semibold)
        static let headingLg = Font.system(.title, weight: .bold)
        static let headingSm = Font.system(.title3, weight: .semibold)
        static let headingXs = Font.system(.headline)
        static let value = Font.system(size: 21, weight: .semibold, design: .rounded)
        static let valueSm = Font.system(size: 18, weight: .semibold, design: .rounded)
        static let rowLg = Font.system(.headline)
        static let row = Font.system(.subheadline, weight: .semibold)
        static let rowSm = Font.system(size: 14, weight: .semibold)
        static let inlineNum = Font.system(size: 14, weight: .medium)
        static let inlineNumSm = Font.system(size: 12, weight: .medium)
        static let heroStat = Font.system(size: 18, weight: .semibold, design: .rounded)
        static let body = Font.system(.body)
        static let bodyMed = Font.system(.body, weight: .medium)
        static let detail = Font.system(.subheadline)
        static let detailMed = Font.system(.subheadline, weight: .medium)
        static let caption = Font.system(.caption)
        static let captionMed = Font.system(.caption, weight: .medium)
        static let micro = Font.system(.caption2)
        static let microMed = Font.system(.caption2, weight: .medium)
        static let tab = Font.system(size: 10, weight: .medium)
        static let tabOn = Font.system(size: 10, weight: .semibold)
        static let button = Font.system(.subheadline, weight: .semibold)
        static let buttonSm = Font.system(.subheadline, weight: .semibold)
        static let nano = Font.system(size: 10)
        static let axis = Font.system(size: 10)
        static let axisSm = Font.system(size: 9)
        static let label = Font.system(size: 11, weight: .medium)
        static let labelSm = Font.system(size: 10, weight: .medium)
        static let eyebrow = Font.system(size: 11, weight: .semibold)
        static let eyebrowLg = Font.system(size: 12, weight: .semibold)
    }

    /// Registers the bundled Barlow faces. Called once at launch; a no-op if
    /// the fonts are already registered by `UIAppFonts`.
    static func registerFonts() {
        for name in ["Barlow-Regular", "Barlow-Medium", "Barlow-SemiBold",
                     "BarlowCondensed-Medium", "BarlowCondensed-SemiBold"] {
            guard UIFont(name: name, size: 12) == nil,
                  let url = Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Surfaces

extension View {
    /// The standard screen ground.
    func screenBackground() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }

    /// Elevated content surface, shared across the product.
    func appCard(padding: CGFloat = Theme.Space.l,
                 radius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    /// A list card — same surface, but rows draw their own padding, so the
    /// card itself has none and clips its rows' separators.
    func appListCard(radius: CGFloat = Theme.Radius.card) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    /// The one dark accent field per screen — the net-worth / total-earned
    /// hero. Deliberately scarce: a second one on the same screen would leave
    /// the eye with no place to land first.
    func heroCard(padding: CGFloat = Theme.Space.xxl) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Theme.heroTop, Theme.heroBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            .shadow(color: Theme.heroShadow.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    /// Chrome for a pinned bar — nav header, tab bar, index strip. Glass
    /// belongs to the navigation layer only: never on a card, a row or the
    /// ground, and never stacked on itself.
    func navChrome(edge: Edge.Set = .top) -> some View {
        background(.ultraThinMaterial)
            .background(Theme.chrome)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
    }

    /// A soft tinted chip. The colour lives in the text over a wash of itself,
    /// so a small stat can never shout louder than the number it annotates.
    func chipFill(_ fill: Color = Theme.accentTint,
                  radius: CGFloat = Theme.Radius.pill) -> some View {
        self.padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 2)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Screen gutters. Every scrolling screen uses exactly this.
    func screenPadding(top: CGFloat = Theme.Space.screenTop,
                       bottom: CGFloat = Theme.Space.screenBottom) -> some View {
        self.padding(.horizontal, Theme.Space.screenH)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }

    /// Uppercase eyebrow above a card or section — condensed, tracked wide.
    func eyebrowStyle(_ color: Color = Theme.textSecondary, size: CGFloat = 11) -> some View {
        font(size == 12 ? Theme.Typo.eyebrowLg : Theme.Typo.eyebrow)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// The label above a stat's value.
    func statLabelStyle(_ color: Color = Theme.textSecondary, small: Bool = false) -> some View {
        font(small ? Theme.Typo.labelSm : Theme.Typo.label)
            .tracking(0)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// A number never wraps, never reflows, never shrinks below legibility.
    func numeral(_ scale: CGFloat = 0.8) -> some View {
        lineLimit(1).minimumScaleFactor(scale).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Hex

extension UIColor {
    fileprivate convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
