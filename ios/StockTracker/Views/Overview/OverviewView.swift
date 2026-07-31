import Charts
import SwiftUI

/// Landing screen: combined net worth across both markets plus a tappable card
/// per market. The iOS-native equivalent of the web app's Overview page.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    // Seeded from the disk cache so the hero number shows instantly on launch.
    @State private var overview: PortfolioOverview? =
        DiskCache.load(PortfolioOverview.self, name: "overview")
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
                    .cardStyle()

                ForEach(MarketCode.allCases) { market in
                    NavigationLink(value: market) {
                        MarketCard(
                            market: market,
                            summary: store.summary(for: market),
                            session: store.session(for: market)
                        )
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                }

                if store.loading && store.summaries.isEmpty {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(16)
            // The tab bar floats over the content on iOS 26, so the last card
            // needs room to come to rest clear of it. Scrolling *under* glass
            // is the effect; being permanently hidden by it is a bug.
            .padding(.bottom, 72)
        }
        .screenBackground()
        // No large title: the hero figure IS the title of this screen, and a
        // "Portfolios" headline stacked above it just competed with the number
        // for the same job. The bar keeps only the settings control.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MarketCode.self) { market in
            PortfolioView(market: market)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    // A glass disc floating over the content, not a tinted ring
                    // stuck to the corner. On iOS 26 it refracts what scrolls
                    // beneath it; older systems get the material fallback.
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 36, height: 36)
                        .navGlass(in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .refreshable { await reload() }
        // Live updates: poll fast while either market is open, slow otherwise,
        // so the hero number ticks like the Stocks app. `.task` cancels the
        // loop automatically when the screen goes away.
        .task {
            await loadOverview()
            // Warm both dashboards' value charts in the background: the server
            // computes + caches the series, and saving to disk here means the
            // chart paints instantly when a market is opened.
            Task {
                for market in MarketCode.allCases {
                    if let pts = try? await APIClient.shared.getValueHistory(
                        market: market, period: .threeMonth) {
                        DiskCache.save(pts, as: "value-history-\(market.rawValue)-\(ValuePeriod.threeMonth.rawValue)")
                    }
                }
            }
            while !Task.isCancelled {
                let open = store.isOpen(.TW) || store.isOpen(.US)
                try? await Task.sleep(nanoseconds: (open ? 5 : 60) * 1_000_000_000)
                if Task.isCancelled { break }
                await store.refreshQuietly()
                await loadOverview()
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["UITEST_SETTINGS"] == "1" { showSettings = true }
        }
    }

    private func reload() async {
        await store.loadAll()
        await loadOverview()
    }

    private func loadOverview() async {
        // Keep showing the last good numbers if the fetch fails (or the
        // backend is still cold-starting) instead of blanking them out.
        guard let o = try? await APIClient.shared.getOverview() else { return }
        overview = o
        DiskCache.save(o, as: "overview")
    }
}

/// Hero: combined net worth — big bold number with a change line under it.
private struct NetWorthCard: View {
    let overview: PortfolioOverview?

    /// Today's combined move across both markets, in TWD. The hero showed
    /// lifetime figures but never "what happened today" — the one number a
    /// portfolio screen is opened for most often.
    private var combinedTodayPl: Double? {
        guard let o = overview else { return nil }
        let tw = o.tw?.todayPl
        let us = o.us?.todayPl
        if tw == nil && us == nil { return nil }
        let fx = o.fx.usdTwd ?? 0
        return (tw ?? 0) + (us ?? 0) * fx
    }
    /// Today's move as a percentage of the prior day's combined value.
    private var combinedTodayPct: Double? {
        guard let today = combinedTodayPl, let total = overview?.combined.twd else { return nil }
        let prior = total - today
        guard prior > 0 else { return nil }
        return today / prior * 100
    }

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

    /// Combined unrealized P&L only (open positions' gain/loss), across both
    /// markets, in TWD (US leg converted at the current FX rate).
    private var combinedUnrealizedPl: Double? {
        guard let o = overview else { return nil }
        let tw = o.tw?.totalPl
        let us = o.us?.totalPl
        if tw == nil && us == nil { return nil }
        let fx = o.fx.usdTwd ?? 0
        return (tw ?? 0) + (us ?? 0) * fx
    }
    private var combinedUnrealizedPlUsd: Double? {
        guard let up = combinedUnrealizedPl, let fx = overview?.fx.usdTwd, fx != 0 else { return nil }
        return up / fx
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
            // Eyebrow → hero figure → today's move. The figure carries the
            // screen, so it gets the size and the tight tracking a display
            // numeral needs, and it sits directly on the lit background rather
            // than inside a card — a box around the headline number is what
            // made it read as one panel among several.
            Text("TOTAL NET WORTH")
                .font(Theme.Typo.label)
                .tracking(1.2)
                .foregroundStyle(Theme.mutedText)

            Text(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .tracking(-1.2)
                .foregroundStyle(Theme.primaryText)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .rollingNumber(overview?.combined.twd)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)

            if let today = combinedTodayPl {
                HStack(spacing: 6) {
                    Image(systemName: today >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 9, weight: .black))
                    Text(Fmt.signedAmount(today, currency: "TWD"))
                        .rollingNumber(today)
                    if let p = combinedTodayPct {
                        Text(Fmt.pct(p)).rollingNumber(p)
                    }
                    Text("today").foregroundStyle(Theme.mutedText)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.pl(today))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Text("≈ \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .rollingNumber(overview?.combined.usd)
                if let fx = overview?.fx.usdTwd {
                    Text("USD/TWD \(Fmt.number(fx, digits: 2))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedText)
                        .rollingNumber(fx)
                }
            }

            // Two headline figures, side by side. Previously these were stacked
            // capsules whose labels wore a cyan and a violet — two more accents
            // on a screen that already had blue chrome, green/red values and an
            // orange stat label. Labels are text tokens now; the coloured number
            // under each one is what carries the meaning.
            if combinedUnrealizedPl != nil || combinedTotalReturn != nil {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    if let up = combinedUnrealizedPl {
                        returnStat(label: "Unrealized", value: up,
                                   usdValue: combinedUnrealizedPlUsd)
                    }
                    if let tr = combinedTotalReturn {
                        returnStat(label: "Total return", value: tr,
                                   usdValue: combinedTotalReturnUsd)
                    }
                }
                .padding(.top, Theme.Space.m)

                if combinedTotalReturn != nil {
                    Text("Total return = unrealized + realized + dividends"
                         + (fxDateText.map { " · FX \($0)" } ?? ""))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Space.xs)
                }
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

    /// One headline figure: a quiet label over the TWD amount, with its USD
    /// equivalent beneath. Sits on the elevated surface so the pair reads as
    /// two tiles without either one needing its own accent colour.
    private func returnStat(label: String, value: Double, usdValue: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.Typo.label)
                .tracking(0.6)
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
            Text(Fmt.signedAmount(value, currency: "TWD"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.pl(value))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .rollingNumber(value)
            if let usd = usdValue {
                Text("≈ \(Fmt.signedAmount(usd, currency: "USD"))")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.mutedText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .rollingNumber(usd)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background(Theme.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                ? Theme.positiveMark : Theme.negativeMark

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Total earned") {
                    if let last = rows.last {
                        Text(Fmt.signedAmount(last.total, currency: "TWD"))
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
                                LinearGradient(colors: [lineColor.opacity(0.14), .clear],
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
                                              value: Fmt.signedAmount(sel.total, currency: "TWD"))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Total", sel.total))
                            .symbolSize(50)
                            .foregroundStyle(lineColor)
                    }
                }
                .chartXSelection(value: $scrubDate)
                // Tick as the scrub dot snaps from point to point.
                .sensoryFeedback(.selection, trigger: nearestRow(to: scrubDate, in: rows)?.date)
                .moneyValueScale(currency: "TWD")
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
                .accessibilityLabel("Total earned over time")
                .accessibilityValue(
                    "Currently \(Fmt.signedAmount(rows.last?.total ?? 0, currency: "TWD")), "
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
    let session: MarketSession

    // Amber for the extended-hours sessions (US pre-market/after-hours) so
    // they read as distinct from a fully "open" green — same tone as the
    // Dividends accent elsewhere on this screen.
    private static let extendedHoursColor = Color(red: 1.0, green: 0.72, blue: 0.25)

    private var dotColor: Color {
        switch session {
        case .open: return Theme.positive
        case .preMarket, .afterHours: return Self.extendedHoursColor
        case .closed: return Theme.mutedText
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                // A drawn monogram rather than the flag emoji: emoji render at
                // the system's whim, sit oddly on the baseline, and read as
                // clip-art dropped into an otherwise designed surface.
                Text(market.rawValue)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(Theme.cardElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(market.displayName)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    // One line, never wrapped: this used to break as
                    // "Market / closed  · 5 / positions" once the value on the
                    // right grew wide enough to squeeze it.
                    HStack(spacing: 5) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                        Text("\(session.label) · \(summary?.holdingsCount ?? 0) positions")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.mutedText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                VStack(alignment: .trailing, spacing: 4) {
                    // Bigger, and with a chevron: this card is a door into the
                    // market, and it never signalled that it was tappable.
                    Text(Fmt.money(summary?.totalValue, currency: market.currencyCode, digits: 0))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.primaryText)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .rollingNumber(summary?.totalValue)
                    PLBadge(value: summary?.todayPl, pct: summary?.todayPlPct,
                            currency: market.currencyCode, compact: true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.mutedText)
            }
            .padding(.vertical, 14)

            // Return breakdown. These three used to be cyan, violet and gold —
            // three hues assigned to categories that have no colour meaning,
            // which is the single loudest "assembled, not designed" signal on
            // the screen. Labels are muted text; the P&L values keep their
            // green/red because there the colour genuinely means something,
            // and Dividends (never negative) stays plain.
            if let s = summary {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    breakdownStat("Unrealized", s.totalPl, signed: true,
                                  color: Theme.pl(s.totalPl))
                    breakdownStat("Realized", s.realizedPl, signed: true,
                                  color: Theme.pl(s.realizedPl))
                    breakdownStat("Dividends", s.dividends, signed: false,
                                  color: Theme.primaryText)
                }
                .padding(.bottom, Theme.Space.xs)
            }
        }
        .contentShape(Rectangle())
    }

    private func breakdownStat(_ label: String, _ value: Double?, signed: Bool,
                               color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.Typo.micro)
                .tracking(0.5)
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
            Text(signed
                 ? Fmt.signedAmount(value, currency: market.currencyCode)
                 : Fmt.amount(value, currency: market.currencyCode))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .rollingNumber(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
