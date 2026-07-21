import SwiftUI
import Charts

struct DashboardView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var search = ""

    private var currency: String { market.currencyCode }

    private var query: String {
        search.trimmingCharacters(in: .whitespaces)
    }

    private var visibleHoldings: [Holding] {
        let all = store.holdings(for: market)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.ticker.localizedCaseInsensitiveContains(query)
                || store.name(for: $0.ticker).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SummaryCard(summary: store.summary(for: market), currency: currency)
                    .cardStyle()
                PortfolioValueCard(market: market,
                                   liveTotal: store.summary(for: market)?.totalValue)
                    .cardStyle()
                PerformanceCard(market: market)
                EarningsCard(points: store.earnings(for: market), currency: currency)
                    .cardStyle()
                AllocationCard(holdings: store.holdings(for: market), store: store)
                    .cardStyle()
                HoldingsSection(holdings: visibleHoldings, store: store,
                                searching: !query.isEmpty)
                    .cardStyle()
            }
            .padding(16)
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search holdings")
        .refreshable { await store.loadAll() }
    }
}

// MARK: - Summary

private struct SummaryCard: View {
    let summary: CurrencySummary?
    let currency: String

    // Violet accent so Total Return reads as a distinct category from the
    // green/red P&L rows (mirrors the web dashboard).
    private let trAccent = Color(red: 0.655, green: 0.545, blue: 0.98)

    // Total Return = unrealized (totalPl) + realized + dividends.
    // totalEarned already = realized + dividends (computed by the backend).
    private var totalReturn: Double? {
        guard let s = summary else { return nil }
        return (s.totalPl ?? 0) + s.totalEarned
    }
    private var totalReturnPct: Double? {
        guard let s = summary, let tr = totalReturn, s.totalCost > 0 else { return nil }
        return tr / s.totalCost * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Big bold value with a colored change line under it.
            VStack(alignment: .leading, spacing: 5) {
                Text(Fmt.money(summary?.totalValue, currency: currency, digits: 0))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .rollingNumber(summary?.totalValue)
                ChangeLine(value: summary?.todayPl, pct: summary?.todayPlPct,
                           currency: currency)
                ChangeLine(value: summary?.totalPl, pct: summary?.totalPlPct,
                           currency: currency, suffix: "All time")
            }

            // Flat stat rows with hairline separators.
            VStack(spacing: 0) {
                statRow("Realized P&L",
                        Fmt.signedMoney(summary?.realizedPl, currency: currency),
                        Theme.pl(summary?.realizedPl), raw: summary?.realizedPl)
                statRow("Dividends",
                        Fmt.money(summary?.dividends, currency: currency),
                        Theme.primaryText, raw: summary?.dividends)
                statRow("Cost basis",
                        Fmt.money(summary?.totalCost, currency: currency),
                        Theme.primaryText, raw: summary?.totalCost)
                statRow("Earned this year",
                        Fmt.signedMoney(summary?.yearEarned, currency: currency),
                        Theme.pl(summary?.yearEarned), raw: summary?.yearEarned,
                        last: true)
            }

            // Distinct Total Return band.
            if let tr = totalReturn {
                HStack(spacing: 5) {
                    Text("TOTAL RETURN")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(trAccent)
                    Text(currency)  // unit: TWD / USD
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.mutedText)
                    Spacer()
                    // Whole dollars + scale-to-fit: a 7-figure return used to
                    // wrap its trailing cents onto a second line.
                    Text(Fmt.signedMoney(tr, currency: currency, digits: 0))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.pl(tr))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .rollingNumber(tr)
                    if let p = totalReturnPct {
                        Text(Fmt.pct(p))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.mutedText)
                            .rollingNumber(p)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(trAccent.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(trAccent.opacity(0.30), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statRow(_ label: String, _ value: String, _ color: Color,
                         raw: Double? = nil, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .rollingNumber(raw)
            }
            .padding(.vertical, 11)
            if !last { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }
}

// MARK: - Portfolio value chart

/// Total market value of this market's holdings over time, with period tabs —
/// the Stocks-app-style "net worth curve". Data comes from /value-history
/// (trade log replayed against daily closes); the shown period re-fetches on
/// tab change and is disk-cached so it paints instantly next time.
private struct PortfolioValueCard: View {
    let market: MarketCode
    /// Live holdings total from the summary (5s MIS-overlaid quotes). The
    /// curve ends at this value so it always matches the big number above —
    /// the backend's last point is a delayed daily close.
    var liveTotal: Double?
    @State private var period: ValuePeriod = .max
    @State private var points: [ValuePoint] = []
    @State private var loading = true
    @State private var scrubDate: Date?

    private var currency: String { market.currencyCode }
    private var cacheKey: String { "value-history-\(market.rawValue)-\(period.rawValue)" }

    private struct Row: Identifiable {
        let id = UUID()
        let date: Date
        let total: Double
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Parse once per body evaluation — never inside Chart closures (those run
    // per data point; see the EarningsCard note below).
    private func makeRows() -> [Row] {
        var rows: [Row] = points.compactMap { p in
            guard let d = Self.dayFormat.date(from: String(p.date.prefix(10))) else { return nil }
            return Row(date: d, total: p.total)
        }
        // Stitch the live total onto the curve's most recent point so its
        // endpoint ticks with the summary number above instead of lagging at
        // the backend's (possibly delayed, 10-min-cached) daily close.
        if let live = liveTotal, live > 0, let last = rows.last {
            rows[rows.count - 1] = Row(date: last.date, total: live)
        }
        return rows
    }

    private func nearestRow(to date: Date?, in rows: [Row]) -> Row? {
        guard let date else { return nil }
        return rows.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    var body: some View {
        let rows = makeRows()
        let dateRange = (rows.first?.date ?? .now)...(rows.last?.date ?? .now)
        let up = (rows.last?.total ?? 0) >= (rows.first?.total ?? 0)
        let lineColor = up ? Theme.positive : Theme.negative

        VStack(alignment: .leading, spacing: 12) {
            // No total in the header — the summary's big number right above
            // is the same value. The range change is this card's own story.
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Portfolio value")
                if let first = rows.first?.total, let last = rows.last?.total,
                   rows.count >= 2, first != 0 {
                    ChangeLine(value: last - first,
                               pct: (last - first) / first * 100,
                               currency: currency,
                               suffix: period.changeSuffix)
                }
            }

            if rows.count < 2 {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                } else {
                    EmptyState(icon: "chart.xyaxis.line",
                               title: "Not enough history for this period")
                }
            } else {
                Chart {
                    ForEach(rows) { row in
                        LineMark(x: .value("Date", row.date), y: .value("Value", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(lineColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        AreaMark(x: .value("Date", row.date), y: .value("Value", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [lineColor.opacity(0.18), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                    }
                    // Finger scrubbing: the rule + tip track the finger
                    // continuously; only the dot snaps to the nearest point.
                    if let raw = scrubDate, let sel = nearestRow(to: raw, in: rows) {
                        let x = min(max(raw, dateRange.lowerBound), dateRange.upperBound)
                        RuleMark(x: .value("Date", x))
                            .foregroundStyle(Theme.mutedText.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartScrubTip(date: sel.date,
                                              value: Fmt.money(sel.total, currency: currency, digits: 0))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Value", sel.total))
                            .symbolSize(50)
                            .foregroundStyle(lineColor)
                    }
                }
                .chartXSelection(value: $scrubDate)
                // Tick as the scrub dot snaps from point to point.
                .sensoryFeedback(.selection, trigger: nearestRow(to: scrubDate, in: rows)?.date)
                // Value, not P&L: start the y-axis at the data, not zero, so
                // the curve fills the card like the Stocks app.
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis(.hidden)
                // No date labels — the period tabs say what's shown and the
                // scrub tip gives exact dates (matches the Stocks-app look).
                .chartXAxis(.hidden)
                .frame(height: 170)
                .accessibilityLabel("Portfolio value over time")
                .accessibilityValue(
                    "Currently \(Fmt.money(rows.last?.total ?? 0, currency: currency, digits: 0)), "
                    + (up ? "trending up" : "trending down")
                )
            }

            UnderlineTabs(
                tabs: ValuePeriod.allCases.map { ($0, $0.label) },
                selection: $period,
                font: .system(.caption, design: .rounded).weight(.bold)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: period) {
            // Cached series first (instant paint), then the fresh fetch.
            if let cached = DiskCache.load([ValuePoint].self, name: cacheKey) {
                points = cached
                loading = false
            } else {
                // No cache for this period yet: show the spinner rather than
                // leaving the previous period's curve up as if it were this
                // one (tab flips used to look like "every period is the same").
                points = []
                loading = true
            }
            if let fresh = try? await APIClient.shared.getValueHistory(market: market,
                                                                       period: period) {
                withAnimation(.snappy(duration: 0.5)) { points = fresh }
                DiskCache.save(fresh, as: cacheKey)
            }
            loading = false
        }
    }
}

// MARK: - Earnings chart

private struct EarningsCard: View {
    let points: [EarningsPoint]
    let currency: String
    @State private var scrubDate: Date?

    private struct Row: Identifiable {
        let id = UUID()
        let date: Date
        let total: Double
    }

    // DateFormatter is expensive to build and to use — keep one shared instance.
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse once per body evaluation. NEVER reference this (or anything derived
    /// from it) inside the Chart's per-point closure — Charts evaluates that
    /// closure per data point, and a recompute here is O(points²) date parsing
    /// on the main thread (it froze the whole app).
    private func makeRows() -> [Row] {
        points.compactMap { p in
            guard let d = Self.dayFormat.date(from: String(p.date.prefix(10))) else { return nil }
            return Row(date: d, total: p.total)
        }
    }

    private func nearestRow(to date: Date?, in rows: [Row]) -> Row? {
        guard let date else { return nil }
        return rows.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    var body: some View {
        let rows = makeRows()
        let dateRange = (rows.first?.date ?? .now)...(rows.last?.date ?? .now)
        let lineColor: Color = (rows.last?.total ?? 0) >= (rows.first?.total ?? 0)
            ? Theme.positive : Theme.negative

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Earnings") {
                if let last = rows.last {
                    Text(Fmt.signedMoney(last.total, currency: currency))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.pl(last.total))
                }
            }

            if rows.count < 2 {
                EmptyState(icon: "chart.line.uptrend.xyaxis",
                           title: "Not enough history yet")
            } else {
                Chart {
                    ForEach(rows) { row in
                        LineMark(x: .value("Date", row.date), y: .value("Total", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(lineColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        AreaMark(x: .value("Date", row.date), y: .value("Total", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [lineColor.opacity(0.18), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                    }
                    // Finger scrubbing: the rule + tip track the finger
                    // continuously; only the dot snaps to the nearest point.
                    if let raw = scrubDate, let sel = nearestRow(to: raw, in: rows) {
                        let x = min(max(raw, dateRange.lowerBound), dateRange.upperBound)
                        RuleMark(x: .value("Date", x))
                            .foregroundStyle(Theme.mutedText.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartScrubTip(date: sel.date,
                                              value: Fmt.signedMoney(sel.total, currency: currency))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Total", sel.total))
                            .symbolSize(50)
                            .foregroundStyle(lineColor)
                    }
                }
                .chartXSelection(value: $scrubDate)
                // Tick as the scrub dot snaps from point to point.
                .sensoryFeedback(.selection, trigger: nearestRow(to: scrubDate, in: rows)?.date)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: Fmt.axisDates(from: dateRange.lowerBound,
                                                    to: dateRange.upperBound)) { value in
                        AxisValueLabel(format: Fmt.axisFormat(from: dateRange.lowerBound,
                                                              to: dateRange.upperBound),
                                       anchor: Fmt.axisAnchor(value.index, of: value.count))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                .frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Allocation

/// What each position is worth as a share of this market's total — a donut
/// plus a legend list. Colors are assigned by a stable hash of the ticker
/// (not by sort rank), so a position keeps its color across refreshes even
/// as today's moves reshuffle the order — see the categorical-palette rule
/// in the dataviz skill ("color follows the entity, never its rank").
private struct AllocationCard: View {
    let holdings: [Holding]
    let store: PortfolioStore

    // Fixed-order categorical palette (validated for CVD-safety at 8 slots,
    // dark-surface steps — this app is dark-mode only). Beyond the top 7
    // positions, the remainder folds into a neutral "Other" slice rather than
    // generating a 9th hue.
    private static let palette: [Color] = [
        Color(red: 0.2235, green: 0.5294, blue: 0.8980),  // blue
        Color(red: 0.8510, green: 0.3490, blue: 0.1490),  // orange
        Color(red: 0.0980, green: 0.6196, blue: 0.4392),  // aqua
        Color(red: 0.7882, green: 0.5216, blue: 0.0000),  // yellow
        Color(red: 0.8353, green: 0.3176, blue: 0.5059),  // magenta
        Color(red: 0.0000, green: 0.5137, blue: 0.0000),  // green
        Color(red: 0.5647, green: 0.5216, blue: 0.9137),  // violet
    ]
    private static let otherColor = Theme.mutedText
    private static let maxSlices = 7

    private struct Slice: Identifiable {
        let id: String
        let ticker: String
        let name: String
        let value: Double
        let pct: Double
        let color: Color
    }

    /// A stable (non-randomized) hash so a ticker always lands on the same
    /// palette slot across app launches — `String.hashValue` is salted per
    /// process and would make colors flicker between sessions.
    private static func slot(for ticker: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in ticker.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private var totalValue: Double {
        holdings.reduce(0) { $0 + ($1.marketValue ?? 0) }
    }

    private var slices: [Slice] {
        let total = totalValue
        guard total > 0 else { return [] }
        let sorted = holdings.sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        let head = sorted.prefix(Self.maxSlices)
        let tail = sorted.dropFirst(Self.maxSlices)

        var out = head.map { h -> Slice in
            let v = h.marketValue ?? 0
            return Slice(id: h.ticker, ticker: h.ticker, name: store.name(for: h.ticker),
                        value: v, pct: v / total * 100, color: Self.slot(for: h.ticker))
        }
        if !tail.isEmpty {
            let otherValue = tail.reduce(0.0) { $0 + ($1.marketValue ?? 0) }
            out.append(Slice(id: "__other__", ticker: "Other", name: "\(tail.count) more",
                             value: otherValue, pct: otherValue / total * 100,
                             color: Self.otherColor))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Allocation")
            if slices.isEmpty {
                EmptyState(icon: "chart.pie", title: "No positions",
                          message: "Add a trade to see your allocation.")
            } else {
                HStack(alignment: .center, spacing: 20) {
                    Chart(slices) { s in
                        SectorMark(angle: .value("Value", s.value),
                                  innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(s.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 130, height: 130)

                    // Direct labels beside each swatch — text stays neutral
                    // ink; only the swatch carries the categorical color.
                    // Ticker and % never truncate; the name gives way first
                    // (a TW short name is a few CJK characters, but a US
                    // holding's name can run long) — capped at 7 + "Other"
                    // rows regardless of how many positions exist, so this
                    // column's height never grows past ~8 rows.
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(slices) { s in
                            HStack(spacing: 6) {
                                Circle().fill(s.color).frame(width: 8, height: 8)
                                Text(s.ticker)
                                    .font(.system(.caption, design: .rounded).weight(.bold))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                                    .layoutPriority(2)
                                if !s.name.isEmpty {
                                    Text(s.name)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .layoutPriority(0)
                                }
                                Spacer(minLength: 6)
                                // Plain share of portfolio — not a signed
                                // change, so no Fmt.pct (which prefixes "+").
                                Text(String(format: "%.1f%%", s.pct))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                    .layoutPriority(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Holdings

/// How the holdings list is ordered. "Value" mirrors the backend's default;
/// the others surface today's movers / the biggest winners without scrolling.
private enum HoldingSort: String, CaseIterable, Identifiable {
    case value = "Market value"
    case today = "Today's move"
    case gain = "Gain %"
    var id: String { rawValue }

    private func key(_ h: Holding) -> Double? {
        switch self {
        case .value: return h.marketValue
        case .today: return h.todayChangePct
        case .gain: return h.unrealizedPlPct
        }
    }

    func areInOrder(_ a: Holding, _ b: Holding) -> Bool {
        let ka = key(a) ?? -.infinity
        let kb = key(b) ?? -.infinity
        // Ties fall back to market value so the order is still meaningful
        // when the key is missing across the board (e.g. "Today's move"
        // outside market hours, when there is no today change to sort by).
        if ka == kb { return (a.marketValue ?? -.infinity) > (b.marketValue ?? -.infinity) }
        return ka > kb
    }
}

private struct HoldingsSection: View {
    let holdings: [Holding]
    let store: PortfolioStore
    var searching = false
    @State private var sort: HoldingSort = .value
    @State private var ascending = false

    private var sorted: [Holding] {
        let base = holdings.sorted(by: sort.areInOrder)
        return ascending ? base.reversed() : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // SectionHeader layout, but with the position count sitting right
            // next to the "Holdings" title instead of by the sort pill.
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Holdings")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text("\(holdings.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                HStack(spacing: 10) {
                    Menu {
                        Picker("Sort by", selection: $sort.animation(.snappy(duration: 0.4))) {
                            ForEach(HoldingSort.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        Divider()
                        Button {
                            withAnimation(.snappy(duration: 0.4)) { ascending.toggle() }
                        } label: {
                            Label("Low to high",
                                  systemImage: ascending ? "checkmark" : "arrow.up")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text(sort.rawValue)
                                .font(.caption.weight(.semibold))
                        }
                        .fixedSize()
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.cardElevated)
                        .clipShape(Capsule())
                    }
                    // Menu freezes its label's size at first layout on some iOS
                    // versions, clipping the text when the title changes
                    // (e.g. "Gain %" → "Market valu…"). Rebuild it per state so
                    // the capsule always fits the current title.
                    .id("\(sort.rawValue)-\(ascending)")
                }
            }
            .padding(.bottom, 4)
            if holdings.isEmpty {
                if searching {
                    EmptyState(icon: "magnifyingglass", title: "No matches",
                               message: "No holdings match your search.")
                } else {
                    EmptyState(icon: "tray", title: "No positions",
                               message: "Add a trade to start tracking.")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(sorted) { h in
                        NavigationLink(value: h) {
                            HoldingRow(holding: h, name: store.name(for: h.ticker),
                                       showsSeparator: h.id != sorted.last?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sensoryFeedback(.selection, trigger: sort)
            }
        }
    }
}

private struct HoldingRow: View {
    let holding: Holding
    let name: String
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(holding.ticker)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text("\(Fmt.shares(holding.shares)) shares")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if !name.isEmpty {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(Theme.mutedText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    // Solid pill = current price, colored by today's move.
                    Text(Fmt.money(holding.currentPrice, currency: holding.currency))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .rollingNumber(holding.currentPrice)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.pl(holding.todayChange) == Theme.mutedText
                                    ? Theme.cardElevated : Theme.pl(holding.todayChange))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .animation(.snappy(duration: 0.5), value: Theme.pl(holding.todayChange))
                    // Today's move in $ and % — its own line so it has room
                    // to read clearly instead of squeezing into the pill.
                    // Hidden when flat/no data (a wall of 0.00 / 0.00% after
                    // hours says nothing).
                    if let c = holding.todayChange, let p = holding.todayChangePct, p != 0 {
                        Text("\(Fmt.signedMoney(c, currency: holding.currency)) (\(Fmt.pct(p)))")
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.pl(c))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .rollingNumber(c)
                    }
                    // What the position is worth — the number checked most.
                    Text(Fmt.money(holding.marketValue, currency: holding.currency, digits: 0))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .rollingNumber(holding.marketValue)
                    Text(Fmt.pct(holding.unrealizedPlPct))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.pl(holding.unrealizedPlPct))
                        .lineLimit(1)
                        .rollingNumber(holding.unrealizedPlPct)
                }
            }
            .padding(.vertical, 12)
            if showsSeparator {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
    }
}
