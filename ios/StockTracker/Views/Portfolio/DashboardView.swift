import SwiftUI

/// One market's portfolio: what it has earned, the six figures that explain
/// it, how it has performed against its benchmark, and the positions.
///
/// The hero here answers "what has this market actually made me" — realized
/// plus dividends, money that is already banked — with the unrealized figure
/// underneath rather than folded in, because the two are not the same kind of
/// claim.
struct DashboardView: View {
    let market: MarketCode
    let onBack: () -> Void
    let onOpen: (String) -> Void

    @EnvironmentObject private var store: PortfolioStore
    @State private var earnedPeriod: EarnedPeriod = .year
    @State private var sort: HoldingSort = .value

    private var currency: String { market.currencyCode }
    private var summary: CurrencySummary? { store.summary(for: market) }
    private var holdings: [Holding] { store.holdings(for: market) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                header
                hero
                statGrid
                earnedCard
                PerformanceCard(market: market)
                holdingsSection
                footnote
            }
            .screenPadding()
        }
        .screenBackground()
        .refreshable { await store.loadAll() }
        .onAppear { store.startPolling(market: market) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                BackRow(title: "Overview", action: onBack)
                Spacer(minLength: Theme.Space.s)
                SessionPill(code: sessionLabel, isOpen: store.isOpen(market))
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(market.displayName)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.text)
                    .numeral(0.7)
                if let hours = store.config(for: market)?.hoursCaption {
                    Text(hours)
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
    }

    private var sessionLabel: String {
        switch store.session(for: market) {
        case .open: return "Open"
        case .preMarket: return "Pre"
        case .afterHours: return "After"
        case .closed: return "Closed"
        }
    }

    // MARK: Hero

    private var totalEarned: Double? { summary?.totalEarned }
    private var totalReturn: Double? {
        guard let s = summary else { return nil }
        return (s.totalPl ?? 0) + s.totalEarned
    }
    private var totalReturnPct: Double? {
        guard let s = summary, s.totalCost > 0, let tr = totalReturn else { return nil }
        return tr / s.totalCost * 100
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Total earned — realized + dividends")
                .eyebrowStyle(Theme.heroLabel)
            Text(Fmt.amount(totalEarned, currency: currency))
                .font(Theme.Typo.display)
                .foregroundStyle(Theme.heroText)
                .numeral(0.5)
                .rollingNumber(totalEarned)

            Rectangle().fill(Theme.heroRule).frame(height: 1)
                .padding(.top, Theme.Space.m)

            HStack(alignment: .firstTextBaseline) {
                Text("Total return incl. unrealized")
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.heroLabel)
                Spacer(minLength: Theme.Space.s)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Fmt.signedAmount(totalReturn, currency: currency))
                        .font(Theme.Typo.row)
                    if let pct = totalReturnPct {
                        Text(Fmt.pct(pct, digits: 1))
                            .font(Theme.Typo.inlineNumSm)
                    }
                }
                .foregroundStyle(Theme.heroText)
                .numeral()
            }
            .padding(.top, Theme.Space.m)
        }
        .heroCard()
    }

    // MARK: Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.gridGap),
                            GridItem(.flexible(), spacing: Theme.Space.gridGap)],
                  spacing: Theme.Space.gridGap) {
            StatCell(label: "Market value",
                     value: Fmt.amount(summary?.totalValue, currency: currency),
                     caption: "\(summary?.holdingsCount ?? holdings.count) positions")
            StatCell(label: "Today",
                     value: Fmt.signedAmount(summary?.todayPl, currency: currency),
                     caption: Fmt.pct(summary?.todayPlPct),
                     valueColor: Theme.pl(summary?.todayPl))
            StatCell(label: "Unrealized P/L",
                     value: Fmt.signedAmount(summary?.totalPl, currency: currency),
                     caption: "net of exit costs · " + Fmt.pct(summary?.totalPlPct, digits: 1),
                     valueColor: Theme.pl(summary?.totalPl))
            StatCell(label: "Realized P/L",
                     value: Fmt.signedAmount(summary?.realizedPl, currency: currency),
                     caption: "FIFO",
                     valueColor: Theme.pl(summary?.realizedPl))
            StatCell(label: "Dividends",
                     value: Fmt.amount(summary?.dividends, currency: currency),
                     caption: "received to date")
            StatCell(label: "Cost basis",
                     value: Fmt.amount(summary?.totalCost, currency: currency),
                     caption: "open lots")
        }
    }

    // MARK: Total-earned chart

    /// The total-earned chart's own periods — a shorter ladder than the
    /// net-worth chart's, because banked earnings move in steps, not daily.
    enum EarnedPeriod: String, CaseIterable, Identifiable {
        case month = "1M", threeMonth = "3M", year = "1Y", max = "MAX"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .month: return 31
            case .threeMonth: return 92
            case .year: return 366
            case .max: return nil
            }
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var earnedPoints: [SeriesChart.Point] {
        let cutoff = earnedPeriod.days.map {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? .distantPast
        }
        return store.earnings(for: market).enumerated().compactMap { index, p in
            guard let d = Self.dayFormat.date(from: String(p.date.prefix(10))) else { return nil }
            if let cutoff, d < cutoff { return nil }
            return SeriesChart.Point(id: index, date: d, value: p.total)
        }
    }

    private var earnedCard: some View {
        let points = earnedPoints
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardHeader(title: "Total earned",
                       value: Fmt.signedAmount(points.last?.value, currency: currency),
                       valueColor: Theme.pl(points.last?.value))
            SegmentedControl(options: EarnedPeriod.allCases.map { ($0, $0.rawValue) },
                             selection: $earnedPeriod)
                .padding(.bottom, 2)
            if points.count >= 2 {
                // Zero-based: earnings are measured from nothing, so a scale
                // that starts at the first point would exaggerate a flat year.
                SeriesChart(points: points, currency: currency, height: 110,
                            zeroBased: true,
                            fromLabel: points.first?.date.formatted(
                                .dateTime.month(.abbreviated).year(.twoDigits)) ?? "",
                            endDot: false)
            } else {
                EmptyState(icon: "chart.line.uptrend.xyaxis",
                           title: "Not enough history yet")
            }
        }
        .appCard()
    }

    // MARK: Holdings

    /// How the list is ordered. Three keys, matching the design's control.
    enum HoldingSort: String, CaseIterable, Identifiable {
        case value = "Value", today = "Today", gain = "Gain %"
        var id: String { rawValue }

        func areInOrder(_ a: Holding, _ b: Holding) -> Bool {
            func key(_ h: Holding) -> Double {
                switch self {
                case .value: return h.marketValue ?? -.infinity
                case .today: return h.todayChangePct ?? -.infinity
                case .gain: return h.unrealizedPlPct ?? -.infinity
                }
            }
            let ka = key(a), kb = key(b)
            if ka == kb { return (a.marketValue ?? 0) > (b.marketValue ?? 0) }
            return ka > kb
        }
    }

    private var marketValue: Double {
        holdings.reduce(0) { $0 + ($1.marketValue ?? 0) }
    }

    private var holdingsSection: some View {
        let sorted = holdings.sorted(by: sort.areInOrder)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel("Holdings · \(holdings.count) · \(Fmt.amount(marketValue, currency: currency))") {
                SegmentedControl(options: HoldingSort.allCases.map { ($0, $0.rawValue) },
                                 selection: $sort, fill: false, compact: true)
            }

            if sorted.isEmpty {
                EmptyState(icon: "tray", title: "No positions",
                           message: "Add a trade to start tracking.")
                    .appCard()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.Space.s) {
                        Text("Ticker").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Price").frame(width: 74, alignment: .trailing)
                        Text("Unrealized").frame(width: 82, alignment: .trailing)
                    }
                    .statLabelStyle(small: true)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                    RowDivider(inset: 0)

                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, h in
                        Button { onOpen(h.ticker) } label: {
                            HoldingRow(holding: h,
                                       name: store.name(for: h.ticker),
                                       weight: marketValue > 0 ? (h.marketValue ?? 0) / marketValue : 0)
                        }
                        .buttonStyle(.plain)
                        if index < sorted.count - 1 { RowDivider() }
                    }
                }
                .appListCard()
                .sensoryFeedback(.selection, trigger: sort)
            }
        }
    }

    private var footnote: some View {
        Text(market == .TW
             ? "Unrealized is net of estimated exit costs (0.1425% commission + transaction tax) — matches 損益試算."
             : "Unrealized is net of estimated exit costs. Realized P/L is FIFO and matches 1099 reporting.")
            .font(Theme.Typo.micro)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One position. Three columns: what it is, what it costs now, what it has
/// made — plus a 3pt weight bar that says how much of the market it is
/// without spending a fourth column on the number.
private struct HoldingRow: View {
    let holding: Holding
    let name: String
    let weight: Double

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                TickerLine(ticker: holding.ticker, name: name)
                Text(subtitle)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .numeral(0.85)
                WeightBar(fraction: weight).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.number(holding.currentPrice, digits: 2))
                    .font(Theme.Typo.rowSm)
                    .foregroundStyle(Theme.text)
                    .numeral()
                    .rollingNumber(holding.currentPrice)
                MovePct(pct: holding.todayChangePct)
                Text(Fmt.compactMoney(holding.marketValue, currency: holding.currency))
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .numeral()
            }
            .frame(width: 74, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.signedCompact(holding.unrealizedPl, currency: holding.currency))
                    .font(Theme.Typo.rowSm)
                    .numeral()
                    .rollingNumber(holding.unrealizedPl)
                Text(Fmt.pct(holding.unrealizedPlPct, digits: 1))
                    .font(Theme.Typo.micro)
                    .numeral()
            }
            .foregroundStyle(Theme.pl(holding.unrealizedPl))
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = ["\(Fmt.shares(holding.shares)) sh"]
        parts.append("avg \(Fmt.number(holding.avgCost, digits: 2))")
        if weight > 0 { parts.append(String(format: "%.1f%%", weight * 100)) }
        return parts.joined(separator: " · ")
    }
}
