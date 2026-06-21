import Charts
import SwiftUI

/// Landing screen: combined net worth across both markets plus a tappable card
/// per market. The iOS-native equivalent of the web app's Overview page.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var overview: PortfolioOverview?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) {
                        Task { await reload() }
                    }
                }

                NetWorthCard(overview: overview)

                TotalEarnedCard(tw: store.earnings["TWD"] ?? [],
                                us: store.earnings["USD"] ?? [],
                                usdTwd: overview?.fx.usdTwd)

                ForEach(MarketCode.allCases) { market in
                    NavigationLink(value: market) {
                        MarketCard(
                            market: market,
                            summary: store.summary(for: market),
                            isOpen: store.isOpen(market)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if store.loading && store.summaries.isEmpty {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Portfolios")
        .navigationDestination(for: MarketCode.self) { market in
            PortfolioView(market: market)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .refreshable { await reload() }
        .task { await loadOverview() }
        .onAppear {
            if ProcessInfo.processInfo.environment["UITEST_SETTINGS"] == "1" { showSettings = true }
        }
    }

    private func reload() async {
        await store.loadAll()
        await loadOverview()
    }

    private func loadOverview() async {
        overview = try? await APIClient.shared.getOverview()
        if let overview { Self.writeWidgetSnapshot(overview) }
    }

    /// Mirror the latest overview into the shared App Group so the Home Screen
    /// widget can render it without doing its own networking/auth.
    private static func writeWidgetSnapshot(_ o: PortfolioOverview) {
        let fx = o.fx.usdTwd
        let twToday = o.tw?.todayPl
        let usToday = o.us?.todayPl
        // Combined today's P&L in TWD (US leg converted at the current FX rate).
        var todayTWD: Double? = nil
        if twToday != nil || usToday != nil {
            todayTWD = (twToday ?? 0) + (usToday ?? 0) * (fx ?? 0)
        }
        var todayPct: Double? = nil
        if let net = o.combined.twd, let t = todayTWD, net - t > 0 {
            todayPct = t / (net - t) * 100
        }
        WidgetSharedStore.write(PortfolioWidgetData(
            netWorthTWD: o.combined.twd,
            netWorthUSD: o.combined.usd,
            todayPLTWD: todayTWD,
            todayPLPct: todayPct,
            twValue: o.tw?.totalValue,
            twTodayPL: twToday,
            usValue: o.us?.totalValue,
            usTodayPL: usToday,
            updatedAt: Date()
        ))
    }
}

/// Hero: combined net worth — big bold number with a change line under it.
private struct NetWorthCard: View {
    let overview: PortfolioOverview?

    private let trAccent = Color(red: 0.655, green: 0.545, blue: 0.98)

    /// Combined Total Return (unrealized + realized + dividends) across both
    /// markets, in TWD (US leg converted at the current FX rate).
    private var combinedTotalReturn: Double? {
        guard let o = overview else { return nil }
        let tw = o.tw.map { ($0.totalPl ?? 0) + $0.totalEarned }
        let us = o.us.map { ($0.totalPl ?? 0) + $0.totalEarned }
        if tw == nil && us == nil { return nil }
        let fx = o.fx.usdTwd ?? 0
        return (tw ?? 0) + (us ?? 0) * fx
    }
    private var combinedTotalReturnUsd: Double? {
        guard let tr = combinedTotalReturn, let fx = overview?.fx.usdTwd, fx != 0 else { return nil }
        return tr / fx
    }
    /// The FX rate's as-of date, formatted (e.g. "Jun 21, 2026").
    private var fxDateText: String? {
        guard let asof = overview?.fx.asof else { return nil }
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone(identifier: "UTC")
        guard let d = iso.date(from: String(asof.prefix(10))) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Investing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Text(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(spacing: 10) {
                Text("≈ \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                if let fx = overview?.fx.usdTwd {
                    Text("USD/TWD \(Fmt.number(fx, digits: 2))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedText)
                }
            }

            if let tr = combinedTotalReturn {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("TOTAL RETURN")
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(trAccent)
                        Text(Fmt.signedMoney(tr, currency: "TWD"))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.pl(tr))
                        if let usd = combinedTotalReturnUsd {
                            Text("≈ \(Fmt.signedMoney(usd, currency: "USD"))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(trAccent.opacity(0.12))
                    .overlay(Capsule().stroke(trAccent.opacity(0.30), lineWidth: 1))
                    .clipShape(Capsule())

                    // Definition + the FX rate's as-of date.
                    Text("Unrealized + realized + dividends"
                         + (fxDateText.map { " · FX rate as of \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Investing net worth")
        .accessibilityValue(
            "\(Fmt.bigMoney(overview?.combined.twd, currency: "TWD")), "
            + "about \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))"
        )
    }
}

/// Combined "total earned" (realized P&L + dividends, cumulative) across both
/// markets over time, converted to TWD at the current FX rate. The TW and US
/// series have different date grids, so each is carried forward to the union
/// of dates before summing. Hidden until there's enough history to draw.
private struct TotalEarnedCard: View {
    let tw: [EarningsPoint]
    let us: [EarningsPoint]
    let usdTwd: Double?
    @State private var scrubDate: Date?

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
    // per data point; see the EarningsCard note in DashboardView).
    private func makeRows() -> [Row] {
        var twByDate: [Date: Double] = [:]
        var usByDate: [Date: Double] = [:]
        for p in tw {
            if let d = Self.dayFormat.date(from: String(p.date.prefix(10))) { twByDate[d] = p.total }
        }
        for p in us {
            if let d = Self.dayFormat.date(from: String(p.date.prefix(10))) { usByDate[d] = p.total }
        }
        var lastTW = 0.0
        var lastUS = 0.0
        return Set(twByDate.keys).union(usByDate.keys).sorted().map { d in
            if let t = twByDate[d] { lastTW = t }
            if let u = usByDate[d] { lastUS = u }
            return Row(date: d, total: lastTW + (usdTwd.map { lastUS * $0 } ?? 0))
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
        if rows.count >= 2 {
            let dateRange = (rows.first?.date ?? .now)...(rows.last?.date ?? .now)
            let lineColor: Color = (rows.last?.total ?? 0) >= (rows.first?.total ?? 0)
                ? Theme.positive : Theme.negative

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Total earned") {
                    if let last = rows.last {
                        Text(Fmt.signedMoney(last.total, currency: "TWD"))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.pl(last.total))
                    }
                }

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
                                              value: Fmt.signedMoney(sel.total, currency: "TWD"))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Total", sel.total))
                            .symbolSize(50)
                            .foregroundStyle(lineColor)
                    }
                }
                .chartXSelection(value: $scrubDate)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: Fmt.axisFormat(from: dateRange.lowerBound,
                                                              to: dateRange.upperBound))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Total earned over time")
                .accessibilityValue(
                    "Currently \(Fmt.signedMoney(rows.last?.total ?? 0, currency: "TWD")), "
                    + ((rows.last?.total ?? 0) >= (rows.first?.total ?? 0) ? "trending up" : "trending down")
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One market row, flat with a hairline separator and a solid change pill.
private struct MarketCard: View {
    let market: MarketCode
    let summary: CurrencySummary?
    let isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(market.flag).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 3) {
                    Text(market.displayName)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOpen ? Theme.positive : Theme.mutedText)
                            .frame(width: 6, height: 6)
                        Text(isOpen ? "Market open" : "Market closed")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text("· \(summary?.holdingsCount ?? 0) positions")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Fmt.money(summary?.totalValue, currency: market.currencyCode, digits: 0))
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    PLBadge(value: summary?.todayPl, pct: summary?.todayPlPct,
                            currency: market.currencyCode, compact: true)
                }
            }
            .padding(.vertical, 14)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
