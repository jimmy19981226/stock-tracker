import SwiftUI

/// The landing screen: one net worth across both markets, the curve that got
/// there, and a door into each market.
///
/// A value-led overview with quick actions and direct market entry points.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let onOpenMarket: (MarketCode) -> Void
    var onAskAssistant: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @State private var showAddTrade = false

    // Hero and market cards read the same published quote snapshot.
    private var overview: PortfolioOverview? { store.overview }
    @State private var period: ValuePeriod = .year
    @State private var series: [SeriesChart.Point] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.cardGap) {
                header

                if let error = store.errorMessage {
                    ErrorBanner(message: error) { Task { await reload() } }
                }

                NetWorthHero(overview: overview)

                quickActions

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    SectionLabel("Your markets") {
                        Text("2 currencies").font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
                    }
                    adaptiveLayout {
                        ForEach(MarketCode.allCases) { market in
                            Button { onOpenMarket(market) } label: {
                                MarketCard(market: market,
                                           summary: store.summary(for: market),
                                           session: store.session(for: market),
                                           share: share(of: market))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("market.\(market.rawValue)")
                        }
                    }
                }

                netWorthChart

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
        .sheet(isPresented: $showAddTrade) { TradeFormView(market: .TW, existing: nil) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                BrandLine()
                Text("Your portfolio").font(Theme.Typo.title).foregroundStyle(Theme.text)
            }
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Theme.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account settings")
        }
    }

    private var adaptiveLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.m))
    }

    private var quickActions: some View {
        adaptiveLayout {
            quickAction("Add trade", icon: "plus", action: { showAddTrade = true })
            quickAction("Ask assistant", icon: "sparkles", action: onAskAssistant)
        }
    }

    private func quickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(Theme.Typo.buttonSm)
            }
            .foregroundStyle(Theme.accentChipText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
        }
        .buttonStyle(.plain)
    }

    // MARK: Net-worth chart

    private var netWorthChart: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardHeader(title: "Portfolio history",
                       value: Fmt.signedAmount(rangeChange, currency: "TWD"),
                       suffix: Fmt.pct(rangeChangePct, digits: 1),
                       valueColor: Theme.pl(rangeChange))

            SegmentedControl(options: ValuePeriod.allCases.map { ($0, $0.label) },
                             selection: $period)
                .padding(.bottom, 2)

            if series.count >= 2 {
                SeriesChart(points: series, currency: "TWD", height: 165,
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
        await loadSeries()
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
/// two-column grid of the figures that explain it.
private struct NetWorthHero: View {
    let overview: PortfolioOverview?

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
    private var todayPct: Double? {
        guard let today, let total = overview?.combined.twd, total - today > 0 else { return nil }
        return today / (total - today) * 100
    }

    /// The stat grid is quoted in USD while the headline stays in NT$.
    /// Every combined figure is computed in TWD, so this is the one conversion.
    /// Without a rate there is nothing honest to show, so it returns nil and
    /// the cell renders an em-dash.
    private func usd(_ twd: Double?) -> Double? {
        guard let twd, fx > 0 else { return nil }
        return twd / fx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Total portfolio value").font(Theme.Typo.detailMed)
                Spacer()
                Image(systemName: "globe.asia.australia").font(.system(size: 18))
            }
            .foregroundStyle(Theme.heroLabel)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(Fmt.amount(overview?.combined.twd, currency: "TWD"))
                    .font(Theme.Typo.hero).tracking(-1.5)
                    .foregroundStyle(Theme.heroText).numeral(0.5)
                    .rollingNumber(overview?.combined.twd)
                Text("≈ \(Fmt.amount(overview?.combined.usd, currency: "USD"))")
                    .font(Theme.Typo.detail).foregroundStyle(Theme.heroLabel)
            }

            HStack(spacing: Theme.Space.xs) {
                Image(systemName: (today ?? 0) < 0 ? "arrow.down.right" : "arrow.up.right")
                Text(Fmt.signedAmount(today, currency: "TWD"))
                    .numeral(0.6).layoutPriority(1)
                Text("today").foregroundStyle(Theme.heroLabel).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(Fmt.pct(todayPct)).numeral()
            }
            .font(Theme.Typo.captionMed).foregroundStyle(Theme.heroText)
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.button))

            HStack(alignment: .top, spacing: Theme.Space.xl) {
                HeroStat(label: "Unrealized", value: Fmt.signedAmount(usd(unrealized), currency: "USD"))
                HeroStat(label: "Realized + dividends", value: Fmt.signedAmount(usd(earned), currency: "USD"))
            }
        }
        .heroCard(padding: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Investing net worth")
        .accessibilityValue(Fmt.amount(overview?.combined.twd, currency: "TWD"))
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(market.rawValue)
                    .font(Theme.Typo.eyebrow)
                    .foregroundStyle(Theme.accentChipText)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentTint, in: Circle())
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(market == .TW ? "Taiwan" : "United States")
                .font(Theme.Typo.row).foregroundStyle(Theme.text)
            Text(Fmt.amount(summary?.totalValue, currency: currency))
                .font(Theme.Typo.value).foregroundStyle(Theme.text)
                .numeral(0.65).rollingNumber(summary?.totalValue)
            HStack(spacing: 4) {
                Image(systemName: (summary?.totalPlPct ?? 0) < 0 ? "arrow.down.right" : "arrow.up.right")
                Text(Fmt.pct(summary?.totalPlPct, digits: 1))
                Text("unrealized").foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.Typo.caption).foregroundStyle(Theme.pl(summary?.totalPlPct))
            WeightBar(fraction: (share ?? 0) / 100)
            Text("\(Int((share ?? 0).rounded()))% of portfolio · \(sessionNote)")
                .font(Theme.Typo.micro).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .appCard(padding: Theme.Space.xl)
        .contentShape(Rectangle())
    }

    private var sessionNote: String {
        switch session {
        case .open: return "Open"
        case .preMarket: return "Pre-market"
        case .afterHours: return "After hours"
        case .closed: return "Closed"
        }
    }

}
