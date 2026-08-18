import Charts
import SwiftUI
import UIKit

/// The app's design language, in one place.
///
/// Light technical ground, steel-blue accent, Barlow Condensed numerals over
/// Barlow body text, grouped white cards with soft elevation, and exactly one
/// dark accent field — the net-worth hero — so the eye always knows where the
/// headline number is.
///
/// Every colour is defined for **both** themes and resolved from the trait
/// collection, so a view never branches on `colorScheme` itself; it just asks
/// for `Theme.card` and gets the right one. The app follows `Appearance`
/// (Light / Dark / System), persisted in `AppSettings`.
enum Theme {

    // MARK: - Colour
    //
    // Two complete palettes. Light is the primary design; dark is the same
    // structure re-grounded on midnight blue rather than a desaturated
    // inversion — the accent field stays the darkest surface in both, which is
    // what keeps the hero reading as the hero.

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
    static let ground = dyn(light: 0xF4F4F6, dark: 0x16273A)
    /// Card / row background — the surface almost all content sits on.
    static let card = dyn(light: 0xFFFFFF, dark: 0x1F3349)
    /// Nav + tab bar fill, layered over `.ultraThinMaterial`.
    static let chrome = dyn(light: 0xFFFFFF, dark: 0x1F3349, lightAlpha: 0.94, darkAlpha: 0.94)
    /// A recessed row inside a card — the expanded index bar's cards.
    static let inset = dyn(light: 0xEDEEEF, dark: 0x26405A)
    /// Segmented-control track, progress track, unselected pill fill.
    static let track = dyn(light: 0xE1E2E4, dark: 0x2C4863)
    /// 1px hairline divider. Used *within* a card to separate a summary line
    /// from its detail, and between rows of a long list — never as a box.
    static let line = dyn(light: 0xE1E2E4, dark: 0x35526F)

    /// Primary text.
    static let text = dyn(light: 0x1D1F20, dark: 0xEAF1F8)
    /// Labels, captions, units — everything that annotates a number.
    static let textSecondary = dyn(light: 0x6E7A85, dark: 0x95AEC9)
    /// The inline company name beside a ticker: quieter than primary, louder
    /// than a caption. Extends the handoff table, which stops at two text
    /// tokens but shows three weights in the holdings and trade rows.
    static let textStrong = dyn(light: 0x4A555F, dark: 0xB5C9DE)
    /// Chevrons, the benchmark line, disabled glyphs — the quietest ink.
    static let textTertiary = dyn(light: 0x9AA4AD, dark: 0x6D89A8)

    /// Interactive / brand. Selected states, links, the chart line.
    static let accent = dyn(light: 0x5980A6, dark: 0x6F9BC8)
    /// The selected tab glyph, a half-step brighter so it holds up against
    /// chrome at 25pt.
    static let accentSelected = dyn(light: 0x5980A6, dark: 0x7BA5CD)
    /// Chip / badge fill. A wash, never a saturated block.
    static let accentTint = dyn(light: 0xE7EDF3, dark: 0x264057)
    /// Text on `accentTint`.
    static let accentChipText = dyn(light: 0x223649, dark: 0xA8C6E2)
    /// The muted accent used for area fills and weight bars.
    static let accentSoft = dyn(light: 0xC9DAEA, dark: 0x2F4F6A)

    /// The net-worth hero gradient — the one dark field in the light theme.
    static let heroTop = dyn(light: 0x1E3348, dark: 0x16283C)
    static let heroBottom = dyn(light: 0x16283C, dark: 0x0F1E2E)
    /// Ink on the hero. Fixed, not theme-resolved: the field is dark in both.
    static let heroText = Color.white
    static let heroLabel = dyn(light: 0x9DBCD9, dark: 0x9DBCD9)
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

    private static let greenInk = dyn(light: 0x3D7A62, dark: 0x5FA285)
    private static let redInk = dyn(light: 0xA3564E, dark: 0xC2726A)

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
    // A fixed ladder. Radii are chosen by *what the thing is*, not by eye:
    // a card is 16, the hero is 18, an inset row or badge is 12–14, the
    // segmented track is 10 with an 8 thumb, a button is 11, a sheet's top
    // corners are 22, a pill is 8. Five arbitrary radii on one screen is the
    // loudest tell that a layout was assembled rather than designed.
    enum Radius {
        static let card: CGFloat = 16
        static let hero: CGFloat = 18
        static let inset: CGFloat = 14
        static let badge: CGFloat = 12
        static let segment: CGFloat = 10
        static let thumb: CGFloat = 8
        static let button: CGFloat = 11
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
        static let screenH: CGFloat = 18
        /// Top inset for a screen that carries no nav bar.
        ///
        /// The design measures 60pt from the physical top of the display; on a
        /// notched phone the safe-area inset already supplies ~59 of those, so
        /// this is the remainder. Adding the full 60 on top of the inset left a
        /// finger's width of dead space above every screen's first line.
        static let screenTop: CGFloat = 8
        /// Bottom inset above the tab bar.
        static let screenBottom: CGFloat = 12
        /// Between cards in a stack.
        static let cardGap: CGFloat = 16
        /// Between cells of a stat grid.
        static let gridGap: CGFloat = 10
    }

    // MARK: - Type
    //
    // Two families with one job each. **Barlow Condensed SemiBold** carries
    // every number and heading — condensed because a portfolio screen is a
    // wall of figures and the narrower face fits a full NT$ total without
    // shrinking it. **Barlow** carries prose: labels, captions, row detail.
    // Mixing the two on one line (a condensed value beside a Barlow unit) is
    // deliberate and is what gives the screens their voice.
    enum Typo {
        // Numerals + headings — Barlow Condensed SemiBold.
        /// The sign-in wordmark. Larger than anything inside the app.
        static let signIn = num(40)
        /// The net-worth number. One per screen, at most.
        static let hero = num(42)
        /// A screen's own title, and the hero on a subordinate screen.
        static let title = num(32)
        static let display = num(38)
        /// A market card's value; also a stock's name.
        static let section = num(30)
        /// A modal or sheet's own title.
        static let heading = num(22)
        /// The Assistant's header.
        static let headingLg = num(24)
        /// A confirmation headline inside a flow.
        static let headingSm = num(20)
        /// A step's heading inside a modal.
        static let headingXs = num(18)
        /// A stat card's value.
        static let value = num(19)
        static let valueSm = num(17)
        /// A card's own title in a list header.
        static let rowLg = num(16)
        /// A list row's headline: ticker, index name, amount.
        static let row = num(15)
        static let rowSm = num(14)
        /// A number inline in a caption.
        static let inlineNum = num(13.5)
        static let inlineNumSm = num(11)
        /// The hero strip's values. Sized to be *read*, not merely present:
        /// at 13.5 they were a footnote under a 42pt headline, which is the
        /// wrong weight for the four figures that explain it.
        static let heroStat = num(17)

        // Prose — Barlow.
        static let body = Font.custom("Barlow-Regular", size: 14)
        static let bodyMed = Font.custom("Barlow-Medium", size: 14)
        static let detail = Font.custom("Barlow-Regular", size: 12.5)
        static let detailMed = Font.custom("Barlow-Medium", size: 12.5)
        static let caption = Font.custom("Barlow-Regular", size: 11.5)
        static let captionMed = Font.custom("Barlow-Medium", size: 11.5)
        /// Row secondary line — the smallest prose size in the app.
        static let micro = Font.custom("Barlow-Regular", size: 10.5)
        static let microMed = Font.custom("Barlow-Medium", size: 10.5)
        /// Tab-bar labels.
        static let tab = Font.custom("Barlow-Medium", size: 10)
        static let tabOn = Font.custom("Barlow-SemiBold", size: 10)
        /// Button text.
        static let button = Font.custom("Barlow-Medium", size: 15)
        static let buttonSm = Font.custom("Barlow-Medium", size: 14)
        /// Sub-micro prose: a chart's own axis labels and the captions that sit
        /// under them. Below `micro`, and used nowhere a sentence is read.
        static let nano = Font.custom("Barlow-Regular", size: 10)
        static let axis = Font.custom("Barlow-Regular", size: 9)
        static let axisSm = Font.custom("Barlow-Regular", size: 8.5)

        // Uppercase labels. Always paired with `.tracking(_:)` via the
        // `.eyebrow`/`.statLabel` modifiers below — tracking is what turns a
        // small bold word into a label rather than shouting.
        static let label = Font.custom("Barlow-SemiBold", size: 10.5)
        static let labelSm = Font.custom("Barlow-SemiBold", size: 9.5)
        /// The condensed uppercase eyebrow: "✦ AI STOCK STUDIO", "YOUR POSITION".
        static let eyebrow = num(11)
        static let eyebrowLg = num(12)

        private static func num(_ size: CGFloat) -> Font {
            Font.custom("BarlowCondensed-SemiBold", size: size)
        }
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

    /// A card: fill, soft shadow, 16pt corners. No border — a hairline box
    /// around every element is the single loudest dated tell, and the shadow
    /// already separates the surface from the ground.
    func appCard(padding: CGFloat = Theme.Space.l,
                 radius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow, radius: 3, x: 0, y: 1)
    }

    /// A list card — same surface, but rows draw their own padding, so the
    /// card itself has none and clips its rows' separators.
    func appListCard(radius: CGFloat = Theme.Radius.card) -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow, radius: 3, x: 0, y: 1)
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
            .shadow(color: Theme.heroShadow, radius: 18, x: 0, y: 6)
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
            .tracking(size * 0.12)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// The label above a stat's value.
    func statLabelStyle(_ color: Color = Theme.textSecondary, small: Bool = false) -> some View {
        font(small ? Theme.Typo.labelSm : Theme.Typo.label)
            .tracking(small ? 0.6 : 0.7)
            .textCase(.uppercase)
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
