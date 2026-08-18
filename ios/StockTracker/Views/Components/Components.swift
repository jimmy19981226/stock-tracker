import Charts
import SwiftUI

// MARK: - Brand & headings

/// The brand eyebrow every root screen opens with.
struct BrandLine: View {
    var body: some View {
        Text("✦ AI Stock Studio")
            .eyebrowStyle(Theme.accent, size: 12)
            .tracking(12 * 0.14)
    }
}

/// A screen's 32pt title, optionally with a trailing control on the same
/// baseline (a caption, an "+ Add" button).
struct ScreenTitle<Trailing: View>: View {
    let title: String
    var caption: String = ""
    @ViewBuilder var trailing: Trailing

    init(_ title: String, caption: String = "",
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.caption = caption
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typo.title)
                .foregroundStyle(Theme.text)
                .numeral(0.7)
            if !caption.isEmpty {
                Text(caption)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            trailing
        }
    }
}

/// A section label above a card or list — "Holdings · 4 · NT$3.8M".
struct SectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.textStrong)
                .numeral()
            Spacer(minLength: Theme.Space.s)
            trailing
        }
    }
}

/// A card's own heading: title left, a signed value right.
struct CardHeader: View {
    let title: String
    var value: String = ""
    var suffix: String = ""
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.xs)
            if !value.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(Theme.Typo.rowSm)
                    if !suffix.isEmpty {
                        Text(suffix).font(Theme.Typo.inlineNumSm)
                    }
                }
                .foregroundStyle(valueColor)
                .numeral()
            }
        }
    }
}

/// Back affordance: chevron + the parent screen's name, uppercase and tracked.
struct BackRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text(title).eyebrowStyle(Theme.accent, size: 12)
            }
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pills, chips, tags

/// A market's session state — accent-tinted with a gain dot while open, grey
/// while shut. The dot is the non-colour channel: even without hue you can see
/// whether a market is live.
struct SessionPill: View {
    let code: String
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOpen ? Theme.gain : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(code)
                .font(Theme.Typo.eyebrow)
                .tracking(11 * 0.06)
        }
        .foregroundStyle(isOpen ? Theme.accentChipText : Theme.textStrong)
        .chipFill(isOpen ? Theme.accentTint : Theme.track)
    }
}

/// A small labelling tag — the data source, the provider, BUY / SELL / DIV.
struct TagChip: View {
    enum Style { case accent, outline, neutral }
    let text: String
    var style: Style = .accent
    var width: CGFloat?

    var body: some View {
        Text(text)
            .font(Theme.Typo.label)
            .tracking(0.5)
            .foregroundStyle(fg)
            .lineLimit(1)
            .frame(width: width)
            .padding(.horizontal, width == nil ? Theme.Space.s : 0)
            .padding(.vertical, 3)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .stroke(style == .outline ? Theme.line : .clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
    }

    private var fg: Color {
        switch style {
        case .accent: return Theme.accentChipText
        case .outline: return Theme.textStrong
        case .neutral: return Theme.textStrong
        }
    }
    private var bg: Color {
        switch style {
        case .accent: return Theme.accentTint
        case .outline: return .clear
        case .neutral: return Theme.track
        }
    }
}

/// A ticker followed by its name, at two weights on one line. Never wraps —
/// the name truncates, the code never does.
///
/// The one component that builds a font from a number rather than the ladder:
/// the pair has to scale together (the name always sits 2pt under the code),
/// so a rung per size would be two rungs that must never drift apart. Callers
/// still pass a ladder value.
struct TickerLine: View {
    let ticker: String
    let name: String
    var size: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(ticker)
                .font(.custom("BarlowCondensed-SemiBold", size: size))
                .foregroundStyle(Theme.text)
                .fixedSize()
            if !name.isEmpty && name != ticker {
                Text(name)
                    .font(.custom("Barlow-Regular", size: size - 2))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Numbers

/// A signed money value in the P/L colour, with a direction triangle so the
/// meaning survives without hue.
struct PLValue: View {
    let value: Double?
    var pct: Double?
    var currency: String = ""
    var font: Font = Theme.Typo.row
    var pctDigits: Int = 1
    var compact: Bool = false
    var showTriangle: Bool = false

    var body: some View {
        let color = Theme.pl(value ?? pct)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if showTriangle, let v = value ?? pct, v != 0 {
                Image(systemName: v > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .black))
            }
            if let value {
                Text(compact ? Fmt.signedCompact(value, currency: currency)
                             : Fmt.signedAmount(value, currency: currency))
                    .font(font)
            }
            if let pct {
                Text(Fmt.pct(pct, digits: pctDigits))
                    .font(Theme.Typo.inlineNumSm)
            }
        }
        .foregroundStyle(color)
        .numeral()
    }
}

/// A percentage move rendered as "▲ 1.24%" — the arrow glyph carries direction
/// so the row still reads in greyscale.
struct MovePct: View {
    let pct: Double?
    var digits: Int = 2

    var body: some View {
        let v = pct ?? 0
        Text((v > 0 ? "▲ " : v < 0 ? "▼ " : "") + String(format: "%.\(digits)f", abs(v)) + "%")
            .font(Theme.Typo.micro)
            .foregroundStyle(Theme.pl(pct))
            .numeral()
    }
}

// MARK: - Stats

/// One cell of a stat grid: uppercase label, the value, an optional caption.
/// Cells are grouped by spacing, never by a rule under each one.
struct StatCell: View {
    let label: String
    let value: String
    var caption: String = ""
    var valueColor: Color = Theme.text
    var carded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).statLabelStyle()
            Text(value)
                .font(Theme.Typo.value)
                .foregroundStyle(valueColor)
                .numeral(0.65)
            if !caption.isEmpty {
                Text(caption)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StatCard(enabled: carded))
    }
}

private struct StatCard: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous))
                .shadow(color: Theme.shadow, radius: 3, x: 0, y: 1)
        } else {
            content
        }
    }
}

/// A column of the hero's stat strip — smaller, and on the dark field.
struct HeroStat: View {
    let label: String
    let value: String
    var sub: String = ""
    var valueColor: Color = Theme.heroText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.Typo.labelSm)
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.heroLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(Theme.Typo.heroStat)
                .foregroundStyle(valueColor)
                .numeral(0.6)
            Text(sub.isEmpty ? " " : sub)
                .font(Theme.Typo.nano)
                .foregroundStyle(Theme.heroLabel)
                .numeral(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label left, value right — the market card's rows and every settings row.
struct KeyValueRow<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value

    init(_ key: String, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(key)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.xs)
            value
        }
    }
}

extension KeyValueRow where Value == Text {
    init(_ key: String, _ text: String, color: Color = Theme.text) {
        self.init(key) {
            Text(text).font(Theme.Typo.detailMed).foregroundStyle(color)
        }
    }
}

// MARK: - Controls

/// The app's one segmented control: a `track` rail with an accent thumb.
/// Period pickers, filters and the sort control are all this — a second
/// control that differed by 2pt would be a regression, not a design.
struct SegmentedControl<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    /// `true` fills the width (period rows); `false` hugs its labels (filters).
    var fill: Bool = true
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.custom(on ? "Barlow-Medium" : "Barlow-Regular",
                                      size: compact ? 10 : 10.5))
                        .foregroundStyle(on ? Color.white : Theme.textStrong)
                        .lineLimit(1)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .padding(.horizontal, fill ? 2 : (compact ? 8 : 11))
                        .padding(.vertical, compact ? 3 : 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                                .fill(on ? Theme.accent : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Full-width filled action.
struct PrimaryButton: View {
    let title: String
    var disabled = false
    var busy = false
    var fullWidth = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text(title).font(Theme.Typo.buttonSm) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 14)
            .padding(.vertical, 11)
            .background(disabled ? Theme.textTertiary : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }
}

/// Outlined action — the quieter twin of `PrimaryButton`.
struct SecondaryButton: View {
    let title: String
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, fullWidth ? 0 : 12)
                .padding(.vertical, 8)
                .background(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A round icon affordance in the nav layer — close, new chat, history.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 30
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Theme.card)
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A labelled text field, matching the sheet forms.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).statLabelStyle()
            content
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
    }
}

// MARK: - Bars

/// The 3pt weight bar under a holdings row — how much of the market this
/// position is, without spending a column on the number.
struct WeightBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accentSoft)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
    }
}

/// A row of bars on a shared baseline — monthly P&L, monthly revenue.
///
/// The baseline sits where zero actually falls, not at the bottom of the box:
/// a month that lost money hangs below the line rather than being drawn as a
/// short positive bar, which is the whole point of showing P&L as bars.
struct BarRow: View {
    struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        var color: Color?
    }
    let bars: [Bar]
    var height: CGFloat = 74
    /// Bars that can only be positive (revenue) skip the split baseline.
    var signed = true
    var showLabels = true

    private var maxUp: Double { bars.map { max(0, $0.value) }.max() ?? 0 }
    private var maxDown: Double { signed ? (bars.map { max(0, -$0.value) }.max() ?? 0) : 0 }

    var body: some View {
        let span = max(maxUp + maxDown, .leastNonzeroMagnitude)
        let upHeight = height * maxUp / span
        let downHeight = height - upHeight

        VStack(spacing: 3) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(bars) { bar in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if bar.value >= 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(bar.color ?? Theme.pl(bar.value))
                                .frame(height: max(3, upHeight * (bar.value / max(maxUp, .leastNonzeroMagnitude))))
                        }
                    }
                    .frame(height: upHeight)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) {
                        if bar.value < 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(bar.color ?? Theme.pl(bar.value))
                                .frame(height: max(3, downHeight * (-bar.value / max(maxDown, .leastNonzeroMagnitude))))
                                .offset(y: upHeight)
                        }
                    }
                }
            }
            .frame(height: height, alignment: .top)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 1).offset(y: upHeight)
            }

            if showLabels {
                HStack(spacing: 3) {
                    ForEach(bars) { bar in
                        Text(bar.label)
                            .font(Theme.Typo.axisSm)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Charts

/// The app's line + area chart, in the one treatment every screen shares:
/// three hairline gridlines, compact value labels on one edge, an end-point
/// dot, and from/Today captions under the plot.
///
/// A chart always carries its own value scale — if the only way to read a
/// number were to scrub it, the curve would be decoration.
struct SeriesChart: View {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    let points: [Point]
    var currency: String = "TWD"
    var height: CGFloat = 120
    var axisEdge: Edge = .leading
    /// Force the scale to start at zero (the total-earned chart does).
    var zeroBased = false
    var fromLabel: String = ""
    var endDot = true

    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        let lo = zeroBased ? 0 : (values.min() ?? 0)
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.08, hi == lo ? max(abs(hi), 1) * 0.1 : 0)
        return (lo - (zeroBased ? 0 : pad))...(hi + pad)
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(
                            LinearGradient(colors: [Theme.accentSoft.opacity(0.55),
                                                    Theme.accentSoft.opacity(0.10)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.monotone)
                }
                ForEach(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if endDot, let last = points.last {
                    PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                        .foregroundStyle(Theme.accent)
                        .symbolSize(46)
                }
            }
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: axisEdge == .leading ? .leading : .trailing,
                          values: .automatic(desiredCount: 3)) { mark in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = mark.as(Double.self) {
                            Text(Fmt.compactMoney(v, currency: currency))
                                .font(Theme.Typo.axis)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: height)

            HStack {
                Text(fromLabel)
                Spacer()
                Text("Today")
            }
            .font(Theme.Typo.axis)
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// A two-line comparison chart: the portfolio at 2.2pt in accent, the
/// benchmark at 1.4pt in the quietest ink, both as percentages.
struct ComparisonChart: View {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        let pct: Double
    }
    let portfolio: [Point]
    let benchmark: [Point]
    var height: CGFloat = 120

    /// Scaled to the data, not to `.automatic`. Left automatic, a portfolio up
    /// 380% got an axis running to ±500% and the two curves collapsed into the
    /// bottom fifth of the plot.
    private var domain: ClosedRange<Double> {
        let values = (portfolio + benchmark).map(\.pct)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = Swift.max((hi - lo) * 0.1, 1)
        return (Swift.min(lo, 0) - pad)...(hi + pad)
    }

    var body: some View {
        Chart {
            ForEach(benchmark) { p in
                LineMark(x: .value("Date", p.date), y: .value("Pct", p.pct),
                         series: .value("Series", "bench"))
                    .foregroundStyle(Theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(portfolio) { p in
                LineMark(x: .value("Date", p.date), y: .value("Pct", p.pct),
                         series: .value("Series", "port"))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { mark in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = mark.as(Double.self) {
                        Text(Fmt.pct(v, digits: 0))
                            .font(Theme.Typo.axis)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .frame(height: height)
    }
}

/// A legend swatch — a 7pt dot and a name. Tappable when the name cycles
/// (the benchmark picker).
struct LegendDot: View {
    let color: Color
    let label: String
    var chevron = false
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label + (chevron ? " ▾" : ""))
                    .font(Theme.Typo.nano)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - Feedback

/// A transient confirmation above the tab bar. Deletes and saves are immediate
/// — the toast reports what happened rather than asking permission first.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typo.detail)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            .shadow(color: Theme.shadowStrong, radius: 20, x: 0, y: 6)
            .padding(.horizontal, Theme.Space.screenH)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// App-wide toast queue. One line, ~2.2 s, above the tab bar.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    private var task: Task<Void, Never>?

    func show(_ text: String) {
        withAnimation(.spring(duration: 0.28)) { message = text }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.message = nil }
        }
    }
}

/// Centered empty-state placeholder.
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(Theme.accentTint).frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.text)
                if !message.isEmpty {
                    Text(message)
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// Inline load failure with a retry.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.loss)
            Text(message)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.s)
            if let retry {
                Button("Retry", action: retry)
                    .font(Theme.Typo.detailMed)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .shadow(color: Theme.shadow, radius: 3, x: 0, y: 1)
    }
}

/// A hairline between rows of a long list, inset to the text column so it
/// leads the eye down rather than drawing a box around every row.
struct RowDivider: View {
    var inset: CGFloat = 14
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

extension View {
    /// Stocks-app-style rolling digits when a live value ticks.
    func rollingNumber(_ value: Double?) -> some View {
        contentTransition(.numericText(value: value ?? 0))
            .animation(.snappy(duration: 0.5), value: value)
    }
}

// MARK: - Sheets & layout

/// The app's bottom sheet: 22pt top corners, the ground colour (not `card`, so
/// the cards inside it still read as cards), a title row with a close disc.
struct SheetScaffold<Content: View>: View {
    let title: String
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(title)
                    .font(Theme.Typo.heading)
                    .foregroundStyle(Theme.text)
                Spacer()
                if let onClose {
                    IconButton(symbol: "xmark", size: 28, tint: Theme.textSecondary,
                               action: onClose)
                }
            }
            content
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.xxl)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Theme.ground)
    }
}

/// A full-screen modal — AI import, Privacy & disclosures. Same header as the
/// sheet, but the header sits on `card` and carries the hairline, because the
/// content below it scrolls under.
struct ModalScaffold<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Theme.Typo.heading)
                    .foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "xmark", size: 28, tint: Theme.textSecondary, action: onClose)
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.screenTop)
            .padding(.bottom, Theme.Space.m)
            .background(Theme.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ScrollView { content.padding(.horizontal, Theme.Space.xxl).padding(.vertical, Theme.Space.xl) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ground.ignoresSafeArea())
    }
}

/// Wrapping row of chips — suggestions, source pills. A `LazyVGrid` can't do
/// this because the items are intrinsically sized.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The tooltip shown while a finger scrubs a chart: the date under the touch
/// and the value there. It *adds* precision — the chart's own value scale is
/// what makes the curve readable without it.
struct ChartScrubTip: View {
    let date: Date
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date, format: .dateTime.year().month(.abbreviated).day())
                .font(Theme.Typo.axis)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.Typo.inlineNum)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 5)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
        .shadow(color: Theme.shadow, radius: 4, x: 0, y: 2)
    }
}

/// Swipe left on a row to reveal Delete — the iOS-native gesture, kept working
/// inside the card lists this design uses (a `List` would impose its own row
/// chrome and can't nest in a scrolling stack of cards).
///
/// The gesture is **simultaneous**, not exclusive. Attached the usual way it
/// won the drag from the enclosing `ScrollView` the moment a finger moved on a
/// row — which is most of the screen on a list page — so vertical drags that
/// started on a row simply didn't scroll. Running alongside the scroll view
/// costs nothing, because the list scrolls vertically and this only ever reacts
/// to a drag that is clearly horizontal.
struct SwipeToDelete<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    private static var actionWidth: CGFloat { 72 }
    /// How far a drag must lean horizontal before it counts as a swipe rather
    /// than a scroll that happens to wobble.
    private static var horizontalBias: CGFloat { 1.6 }

    @State private var offset: CGFloat = 0
    @State private var committed = false
    /// Locked in on the first meaningful movement of each drag, so a swipe
    /// that curves — or a scroll that starts with a sideways nudge — can't
    /// flip between the two mid-gesture.
    @State private var claimed: Bool?

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { offset = 0; committed = false }
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.loss)
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)

            content
                .background(Theme.card)
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            let dx = value.translation.width, dy = value.translation.height
                            if claimed == nil, abs(dx) + abs(dy) > 6 {
                                claimed = abs(dx) > abs(dy) * Self.horizontalBias
                            }
                            guard claimed == true else { return }
                            let base = committed ? -Self.actionWidth : 0
                            offset = min(0, max(-Self.actionWidth - 20, base + dx))
                        }
                        .onEnded { _ in
                            defer { claimed = nil }
                            guard claimed == true else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                committed = offset < -Self.actionWidth / 2
                                offset = committed ? -Self.actionWidth : 0
                            }
                        }
                )
        }
        .clipped()
    }
}
