import SwiftUI

/// The landing screen: one net worth across both markets, the curve that got
/// there, and a door into each market.
///
/// The hero is the only dark field on the screen, and it is the only thing
/// above the fold — everything below annotates it.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    let onOpenMarket: (MarketCode) -> Void

    // Seeded from the disk cache so the hero number shows instantly on launch.
    @State private var overview: PortfolioOverview? =
        DiskCache.load(PortfolioOverview.self, name: "overview")
    @State private var period: ValuePeriod = .year
    @State private var series: [SeriesChart.Point] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.cardGap) {
                header

                if let error = store.errorMessage {
                    ErrorBanner(message: error) { Task { await reload() } }
                }

                NetWorthHero(overview: overview, clock: clock)

                netWorthChart

                ForEach(MarketCode.allCases) { market in
                    Button { onOpenMarket(market) } label: {
                        MarketCard(market: market,
                                   summary: store.summary(for: market),
                                   session: store.session(for: market),
                                   share: share(of: market))
                    }
                    .buttonStyle(.plain)
                }

                Text("Updated \(clock) · \(cadenceNote)")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xxs)

                if store.loading && store.summaries.isEmpty {
                    ProgressView().padding(.top, 40)
                }
            }
            .screenPadding()
        }
        .screenBackground()
        .refreshable { await reload() }
        .task(id: period) { await loadSeries() }
        .task {
            await loadOverview()
            while !Task.isCancelled {
                let open = store.isOpen(.TW) || store.isOpen(.US)
                try? await Task.sleep(nanoseconds: (open ? 5 : 60) * 1_000_000_000)
                if Task.isCancelled { break }
                await store.refreshQuietly()
                await loadOverview()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            BrandLine()
            Spacer(minLength: Theme.Space.s)
            ForEach(MarketCode.allCases) { market in
                SessionPill(code: market.rawValue, isOpen: store.isOpen(market))
            }
        }
    }

    // MARK: Net-worth chart

    private var netWorthChart: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardHeader(title: "Net worth",
                       value: Fmt.signedAmount(rangeChange, currency: "TWD"),
                       suffix: Fmt.pct(rangeChangePct, digits: 1),
                       valueColor: Theme.pl(rangeChange))

            SegmentedControl(options: ValuePeriod.allCases.map { ($0, $0.label) },
                             selection: $period)
                .padding(.bottom, 2)

            if series.count >= 2 {
                SeriesChart(points: series, currency: "TWD",
                            fromLabel: period.fromLabel(first: series.first?.date))
            } else {
                Rectangle().fill(.clear).frame(height: 124)
                    .overlay(ProgressView().tint(Theme.textTertiary))
            }
        }
        .appCard()
    }

    private var rangeChange: Double? {
        guard let first = series.first?.value, let last = series.last?.value else { return nil }
        return last - first
    }
    private var rangeChangePct: Double? {
        guard let first = series.first?.value, first != 0, let change = rangeChange else { return nil }
        return change / first * 100
    }

    // MARK: Derived

    private func share(of market: MarketCode) -> Double? {
        guard let total = overview?.combined.twd, total > 0 else { return nil }
        let fx = overview?.fx.usdTwd ?? 0
        let value = store.summary(for: market)?.totalValue ?? 0
        return (market == .TW ? value : value * fx) / total * 100
    }

    private var clock: String {
        (store.lastUpdated ?? Date()).formatted(.dateTime.hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits).second(.twoDigits))
    }

    private var cadenceNote: String {
        let open = MarketCode.allCases.filter { store.isOpen($0) }
        guard !open.isEmpty else { return "markets closed · frozen at last close" }
        return open.map(\.rawValue).joined(separator: " + ") + " open · auto-refresh 5 s"
    }

    // MARK: Loading

    private func reload() async {
        await store.loadAll()
        await loadOverview()
        await loadSeries()
    }

    private func loadOverview() async {
        guard let o = try? await APIClient.shared.getOverview() else { return }
        overview = o
        DiskCache.save(o, as: "overview")
    }

    /// The combined curve: each market's daily value, the US leg converted at
    /// the current rate, carried forward across the union of both date grids
    /// (the two markets don't trade on the same days).
    private func loadSeries() async {
        let cacheKey = "networth-\(period.rawValue)"
        if series.isEmpty, let cached = DiskCache.load([ValuePoint].self, name: cacheKey) {
            series = Self.points(from: cached)
        }
        async let twRaw = try? APIClient.shared.getValueHistory(market: .TW, period: period)
        async let usRaw = try? APIClient.shared.getValueHistory(market: .US, period: period)
        let (tw, us) = await (twRaw, usRaw)
        guard tw != nil || us != nil else { return }
        let fx = overview?.fx.usdTwd ?? 0

        var byDate: [String: (tw: Double?, us: Double?)] = [:]
        for p in tw ?? [] { byDate[p.date, default: (nil, nil)].tw = p.total }
        for p in us ?? [] { byDate[p.date, default: (nil, nil)].us = p.total }

        var lastTW = 0.0, lastUS = 0.0
        let combined: [ValuePoint] = byDate.keys.sorted().map { date in
            if let v = byDate[date]?.tw { lastTW = v }
            if let v = byDate[date]?.us { lastUS = v }
            return ValuePoint(date: date, total: lastTW + lastUS * fx)
        }
        DiskCache.save(combined, as: cacheKey)
        series = Self.points(from: combined)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func points(from raw: [ValuePoint]) -> [SeriesChart.Point] {
        raw.enumerated().compactMap { index, p in
            guard let d = dayFormat.date(from: String(p.date.prefix(10))) else { return nil }
            return SeriesChart.Point(id: index, date: d, value: p.total)
        }
    }
}

// MARK: - Hero

/// The one dark field: the combined net worth, what it's worth in USD, and a
/// four-column strip of the figures that explain it.
private struct NetWorthHero: View {
    let overview: PortfolioOverview?
    let clock: String

    private var fx: Double { overview?.fx.usdTwd ?? 0 }

    private func combined(_ pick: (CurrencySummary) -> Double?) -> Double? {
        guard let o = overview else { return nil }
        let tw = o.tw.flatMap(pick)
        let us = o.us.flatMap(pick)
        if tw == nil && us == nil { return nil }
        return (tw ?? 0) + (us ?? 0) * fx
    }

    private var today: Double? { combined { $0.todayPl } }
    private var unrealized: Double? { combined { $0.totalPl } }
    private var earned: Double? { combined { $0.totalEarned } }
    private var totalReturn: Double? {
        guard let u = unrealized, let e = earned else { return unrealized ?? earned }
        return u + e
    }
    private var todayPct: Double? {
        guard let today, let total = overview?.combined.twd, total - today > 0 else { return nil }
        return today / (total - today) * 100
    }

    /// The stat strip is quoted in USD while the headline stays in NT$: the
    /// figures are small enough that a single hard currency reads faster than
    /// four seven-digit TWD numbers, and the two markets are already summed.
    /// Every combined figure is computed in TWD, so this is the one conversion.
    /// Without a rate there is nothing honest to show, so it returns nil and
    /// the cell renders an em-dash.
    private func usd(_ twd: Double?) -> Double? {
        guard let twd, fx > 0 else { return nil }
        return twd / fx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Investing net worth")
                .eyebrowStyle(Theme.heroLabel)
                .padding(.bottom, 4)

            Text(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
                .font(Theme.Typo.hero)
                .tracking(-0.4)
                .foregroundStyle(Theme.heroText)
                .numeral(0.5)
                .rollingNumber(overview?.combined.twd)

            HStack(spacing: Theme.Space.xs) {
                Text("≈ \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))")
                Text("·")
                Text("USD/TWD \(Fmt.number(fx, digits: 2))")
                Text("·")
                Text(clock)
            }
            .font(Theme.Typo.detail)
            .foregroundStyle(Theme.heroLabel)
            .numeral(0.7)
            .padding(.top, Theme.Space.s)

            Rectangle().fill(Theme.heroRule).frame(height: 1)
                .padding(.top, Theme.Space.xl)

            HStack(alignment: .top, spacing: Theme.Space.s) {
                HeroStat(label: "Today",
                         value: Fmt.signedCompact(usd(today), currency: "USD"),
                         sub: Fmt.pct(todayPct),
                         valueColor: Theme.pl(today))
                HeroStat(label: "Unrealized",
                         value: Fmt.signedCompact(usd(unrealized), currency: "USD"),
                         valueColor: Theme.pl(unrealized))
                HeroStat(label: "Realized + div",
                         value: Fmt.signedCompact(usd(earned), currency: "USD"),
                         valueColor: Theme.pl(earned))
                HeroStat(label: "Total return",
                         value: Fmt.signedCompact(usd(totalReturn), currency: "USD"),
                         sub: totalReturn != nil
                             ? "≈ " + Fmt.signedCompact(totalReturn, currency: "TWD") : "")
            }
            .padding(.top, Theme.Space.l)
        }
        .heroCard(padding: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Investing net worth")
        .accessibilityValue(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
    }
}

// MARK: - Market card

/// A door into one market, carrying enough of its figures that opening it is a
/// choice rather than a necessity.
private struct MarketCard: View {
    let market: MarketCode
    let summary: CurrencySummary?
    let session: MarketSession
    let share: Double?

    private var currency: String { market.currencyCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(market.rawValue)
                    .font(Theme.Typo.eyebrowLg)
                    .foregroundStyle(Theme.accentChipText)
                    .chipFill(Theme.accentTint, radius: 7)
                Text(market == .TW ? "Taiwan" : "US")
                    .font(Theme.Typo.rowLg)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Theme.Space.xs)
                if let share {
                    Text("\(Int(share.rounded()))% of total")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .numeral()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, Theme.Space.s)

            HStack(alignment: .lastTextBaseline, spacing: Theme.Space.s) {
                Text(Fmt.money(summary?.totalValue, currency: currency, digits: 0))
                    .font(Theme.Typo.section)
                    .foregroundStyle(Theme.text)
                    .numeral(0.6)
                    .rollingNumber(summary?.totalValue)
                Text(sessionNote)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.bottom, Theme.Space.m)

            VStack(spacing: 5) {
                row("Today", summary?.todayPl, pct: summary?.todayPlPct, signed: true)
                row("Unrealized", summary?.totalPl, pct: summary?.totalPlPct, signed: true)
                row("Realized", summary?.realizedPl, pct: nil, signed: true)
                row("Dividends", summary?.dividends, pct: nil, signed: false)
            }

            Rectangle().fill(Theme.line).frame(height: 1)
                .padding(.top, Theme.Space.m)

            HStack(alignment: .firstTextBaseline) {
                Text("Total return · \(currency)")
                    .eyebrowStyle(Theme.textSecondary)
                    .tracking(11 * 0.10)
                Spacer(minLength: Theme.Space.s)
                PLValue(value: totalReturn, pct: totalReturnPct, currency: currency,
                        font: Theme.Typo.row)
            }
            .padding(.top, 9)
        }
        .appCard(padding: Theme.Space.xl)
        .contentShape(Rectangle())
    }

    private var totalReturn: Double? {
        guard let s = summary else { return nil }
        return (s.totalPl ?? 0) + s.totalEarned
    }
    private var totalReturnPct: Double? {
        guard let s = summary, s.totalCost > 0, let tr = totalReturn else { return nil }
        return tr / s.totalCost * 100
    }

    private var sessionNote: String {
        switch session {
        case .open: return "Open"
        case .preMarket: return "Pre-market"
        case .afterHours: return "After hours"
        case .closed: return "Closed"
        }
    }

    private func row(_ key: String, _ value: Double?, pct: Double?, signed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(key)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.xs)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(signed ? Fmt.signedAmount(value, currency: currency)
                            : Fmt.amount(value, currency: currency))
                    .font(Theme.Typo.inlineNum)
                    .foregroundStyle(signed ? Theme.pl(value) : Theme.text)
                if let pct {
                    Text(Fmt.pct(pct))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .numeral()
        }
    }
}
