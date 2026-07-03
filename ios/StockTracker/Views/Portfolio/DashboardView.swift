import SwiftUI
import Charts

struct DashboardView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore

    private var currency: String { market.currencyCode }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SummaryCard(summary: store.summary(for: market), currency: currency)
                PortfolioValueCard(market: market,
                                   liveTotal: store.summary(for: market)?.totalValue)
                EarningsCard(points: store.earnings(for: market), currency: currency)
                HoldingsSection(holdings: store.holdings(for: market), store: store)
            }
            .padding(16)
        }
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
                    Text(Fmt.signedMoney(tr, currency: currency))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.pl(tr))
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
    @State private var period: ValuePeriod = .threeMonth
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
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
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

// MARK: - Holdings

private struct HoldingsSection: View {
    let holdings: [Holding]
    let store: PortfolioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Holdings") {
                Text("\(holdings.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.bottom, 4)
            if holdings.isEmpty {
                EmptyState(icon: "tray", title: "No positions",
                           message: "Add a trade to start tracking.")
            } else {
                VStack(spacing: 0) {
                    ForEach(holdings) { h in
                        NavigationLink(value: h) {
                            HoldingRow(holding: h, name: store.name(for: h.ticker))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HoldingRow: View {
    let holding: Holding
    let name: String

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
                VStack(alignment: .trailing, spacing: 5) {
                    // Solid pill = current price, colored by today's move.
                    Text(Fmt.money(holding.currentPrice, currency: holding.currency))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .rollingNumber(holding.currentPrice)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.pl(holding.todayChange) == Theme.mutedText
                                    ? Theme.cardElevated : Theme.pl(holding.todayChange))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .animation(.snappy(duration: 0.5), value: Theme.pl(holding.todayChange))
                    Text(Fmt.pct(holding.unrealizedPlPct))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.pl(holding.unrealizedPlPct))
                        .rollingNumber(holding.unrealizedPlPct)
                }
            }
            .padding(.vertical, 12)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
