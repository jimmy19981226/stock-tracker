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
    @State private var section = "Holdings"
    @State private var search = ""

    private var currency: String { market.currencyCode }
    private var summary: CurrencySummary? { store.summary(for: market) }
    private var holdings: [Holding] { store.holdings(for: market) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                header
                hero
                HStack(spacing: Theme.Space.m) {
                    StatCell(label: "Today's change",
                             value: Fmt.signedAmount(summary?.todayPl, currency: currency),
                             caption: Fmt.pct(summary?.todayPlPct), valueColor: Theme.pl(summary?.todayPl))
                    StatCell(label: "Unrealized P/L",
                             value: Fmt.signedAmount(summary?.totalPl, currency: currency),
                             caption: Fmt.pct(summary?.totalPlPct), valueColor: Theme.pl(summary?.totalPl))
                }
                SegmentedControl(options: [("Holdings", "Holdings"), ("Performance", "Performance")], selection: $section)
                if section == "Holdings" {
                    holdingsSection
                    footnote
                } else {
                    statGrid
                    PerformanceCard(market: market)
                    earnedCard
                }
            }
            .screenPadding()
        }
        .screenBackground()
        .refreshable { await store.loadAll() }
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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Market value").font(Theme.Typo.detailMed)
                Spacer()
                Text("\(holdings.count) positions").font(Theme.Typo.caption)
            }
            .foregroundStyle(Theme.heroLabel)
            Text(Fmt.amount(summary?.totalValue, currency: currency))
                .font(Theme.Typo.display).tracking(-1)
                .foregroundStyle(Theme.heroText).numeral(0.5)
                .rollingNumber(summary?.totalValue)
            HStack {
                Text("Realized + dividends").font(Theme.Typo.caption)
                Spacer()
                Text(Fmt.signedAmount(totalEarned, currency: currency)).font(Theme.Typo.row)
            }
            .foregroundStyle(Theme.heroLabel)
        }
        .heroCard(padding: 22)
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
                     caption: market == .TW ? "Moving average" : "FIFO",
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
        let sorted = holdings.filter {
            search.isEmpty || $0.ticker.localizedCaseInsensitiveContains(search)
                || store.name(for: $0.ticker).localizedCaseInsensitiveContains(search)
        }.sorted(by: sort.areInOrder)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Search your holdings", text: $search)
                    .font(Theme.Typo.detail).foregroundStyle(Theme.text)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("holdings.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Theme.textSecondary).accessibilityLabel("Clear search")
                }
            }
            .padding(Theme.Space.l)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            SectionLabel("Holdings · \(sorted.count)") {
                SegmentedControl(options: HoldingSort.allCases.map { ($0, $0.rawValue) },
                                 selection: $sort, fill: false, compact: true)
            }
            Text("Market value \(Fmt.amount(marketValue, currency: currency))")
                .font(Theme.Typo.detailMed)
                .foregroundStyle(Theme.textSecondary)
                .numeral()

            if sorted.isEmpty {
                EmptyState(icon: "tray", title: search.isEmpty ? "No positions" : "No matching holdings",
                           message: search.isEmpty ? "Add a trade to start tracking." : "Try a ticker or company name.")
                    .appCard()
            } else {
                VStack(spacing: 0) {
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
             ? "Taiwan uses moving-average cost. Unrealized is net of estimated exit costs (0.1425% commission + transaction tax) — matches 損益試算."
             : "Unrealized is net of estimated exit costs. Realized P/L is FIFO and matches 1099 reporting.")
            .font(Theme.Typo.micro)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One position with its quote above two full-width financial figures.
/// Each amount gets half the row rather than a narrow fixed-width column.
private struct HoldingRow: View {
    let holding: Holding
    let name: String
    let weight: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(String(holding.ticker.prefix(2)))
                            .font(Theme.Typo.captionMed)
                            .foregroundStyle(Theme.accentChipText)
                            .frame(width: 36, height: 36)
                            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(holding.ticker).font(Theme.Typo.row).foregroundStyle(Theme.text)
                            Text(name).font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    Text(subtitle)
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.textSecondary)
                        .numeral(0.85)
                    WeightBar(fraction: weight).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.price(holding.currentPrice, currency: holding.currency))
                        .font(Theme.Typo.rowSm)
                        .foregroundStyle(Theme.text)
                        .numeral()
                        .rollingNumber(holding.currentPrice)
                    MovePct(pct: holding.todayChangePct)
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Market value").statLabelStyle(small: true)
                    Text(Fmt.amount(holding.marketValue, currency: holding.currency))
                        .font(Theme.Typo.rowSm)
                        .foregroundStyle(Theme.text)
                        .numeral()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Unrealized P/L").statLabelStyle(small: true)
                    Text(Fmt.signedAmount(holding.unrealizedPl, currency: holding.currency))
                        .font(Theme.Typo.rowSm)
                        .foregroundStyle(Theme.pl(holding.unrealizedPl))
                        .numeral()
                        .rollingNumber(holding.unrealizedPl)
                    Text(Fmt.pct(holding.unrealizedPlPct, digits: 1))
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.pl(holding.unrealizedPl))
                        .numeral()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = ["\(Fmt.shares(holding.shares)) sh"]
        parts.append("avg \(Fmt.number(holding.avgCost, digits: 2))")
        if weight > 0 { parts.append(String(format: "%.1f%%", weight * 100)) }
        return parts.joined(separator: " · ")
    }
}
