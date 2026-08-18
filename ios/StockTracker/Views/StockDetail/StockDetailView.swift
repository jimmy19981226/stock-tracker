import Charts
import SwiftUI

/// One stock, in full: the quote, the price line with your own trades marked
/// on it, what your position is worth, and the fundamentals that explain the
/// price — plus, for Taiwan names, the monthly-revenue and quarterly series
/// that Taiwanese investors actually trade on.
struct StockDetailView: View {
    let ticker: String
    let market: MarketCode
    let onBack: () -> Void

    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter
    @State private var detail: StockDetail?
    @State private var period: HistoryPeriod = .oneYear
    @State private var loading = true
    @State private var error: String?

    @State private var showAddTrade = false
    @State private var showAddDividend = false
    @State private var editingTrade: Trade?
    @State private var editingDividend: Dividend?

    private var currency: String { detail?.fundamentals.currency ?? market.currencyCode }
    private var myTrades: [Trade] { store.trades(for: market).filter { $0.ticker == ticker } }
    private var myDividends: [Dividend] { store.dividends(for: market).filter { $0.ticker == ticker } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header

                if loading && detail == nil {
                    LoadingSkeleton()
                } else if let error, detail == nil {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if let detail {
                    priceBlock(detail)

                    SegmentedControl(options: HistoryPeriod.allCases.map { ($0, $0.label) },
                                     selection: $period)

                    PriceChartCard(detail: detail, currency: currency)

                    if let position = detail.position, position.shares > 0 {
                        PositionCard(position: position, currency: currency)
                    }

                    FiftyTwoWeekBar(low: detail.fundamentals.fiftyTwoWeekLow,
                                    high: detail.fundamentals.fiftyTwoWeekHigh,
                                    price: detail.live.price)

                    StatsGrid(fundamentals: detail.fundamentals,
                              live: detail.live,
                              yieldOnCost: detail.yieldOnCost)

                    if !detail.monthlyRevenue.isEmpty {
                        RevenueCard(months: detail.monthlyRevenue, currency: currency)
                    }
                    if !detail.quarterlyFinancials.isEmpty {
                        FinancialsCard(quarters: detail.quarterlyFinancials)
                    }

                    RecordsCard(trades: myTrades, dividends: myDividends, currency: currency,
                                onEditTrade: { editingTrade = $0 },
                                onEditDividend: { editingDividend = $0 })
                }
            }
            .screenPadding(bottom: 24)
        }
        .screenBackground()
        .sheet(isPresented: $showAddTrade, onDismiss: reload) {
            TradeFormView(market: market, existing: nil, prefillTicker: ticker)
        }
        .sheet(isPresented: $showAddDividend, onDismiss: reload) {
            DividendFormView(market: market, existing: nil, prefillTicker: ticker)
        }
        .sheet(item: $editingTrade, onDismiss: reload) { TradeFormView(market: market, existing: $0) }
        .sheet(item: $editingDividend, onDismiss: reload) { DividendFormView(market: market, existing: $0) }
        .task(id: period) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            BackRow(title: market.displayName, action: onBack)
            Spacer(minLength: Theme.Space.s)
            TagChip(text: sourceLabel, style: .accent)
            Menu {
                Button("Add trade") { showAddTrade = true }
                Button("Add dividend") { showAddDividend = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
            }
        }
    }

    /// Where this quote comes from and how fresh it is. TW quotes are pulled
    /// straight off TWSE MIS by the device; US quotes come through Yahoo.
    private var sourceLabel: String {
        market == .TW ? "TWSE MIS · live" : "Yahoo · 15 m delayed"
    }

    private func priceBlock(_ d: StockDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(d.name)
                    .font(Theme.Typo.section)
                    .foregroundStyle(Theme.text)
                    .numeral(0.7)
                Text(d.symbol)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(Fmt.number(d.live.price, digits: 2))
                    .font(Theme.Typo.display)
                    .foregroundStyle(Theme.text)
                    .numeral(0.6)
                    .rollingNumber(d.live.price)
                Text(changeText(d))
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.pl(d.live.todayChange))
                    .numeral()
            }
        }
    }

    private func changeText(_ d: StockDetail) -> String {
        guard let change = d.live.todayChange else { return "—" }
        let arrow = change >= 0 ? "▲ " : "▼ "
        let pct = d.live.todayChangePct.map { " (\(Fmt.pct($0)))" } ?? ""
        return arrow + Fmt.number(abs(change), digits: 2) + pct
    }

    // MARK: Loading

    private func load() async {
        loading = true
        do {
            detail = try await APIClient.shared.getStockDetail(ticker, period: period)
            error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func reload() { Task { await load() } }
}

// MARK: - Chart

/// The price line with the user's own history drawn on it: a triangle up where
/// they bought, down where they sold, a hollow circle where a dividend landed.
/// The legend is not optional — three unlabelled glyph shapes on a chart is a
/// puzzle, not information.
private struct PriceChartCard: View {
    let detail: StockDetail
    let currency: String
    @State private var scrubDate: Date?

    private struct Bar: Identifiable {
        let id: Int
        let date: Date
        let close: Double
    }
    private struct Marker: Identifiable {
        let id: String
        let date: Date
        let y: Double
        let kind: MarkerKind
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Parsed once per body evaluation — never inside a Chart closure, which
    // Charts calls per data point (that made this O(n²) date parsing on the
    // main thread and froze the app).
    private func makeBars() -> [Bar] {
        detail.history.enumerated().compactMap { index, b in
            guard let d = Self.dayFormat.date(from: String(b.date.prefix(10))),
                  let c = b.close else { return nil }
            return Bar(id: index, date: d, close: c)
        }
    }

    private func makeMarkers(bars: [Bar], range: ClosedRange<Date>) -> [Marker] {
        func closest(_ d: Date) -> Double? {
            bars.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }?.close
        }
        var out: [Marker] = []
        for (i, t) in detail.trades.enumerated() {
            guard let d = Self.dayFormat.date(from: String(t.date.prefix(10))),
                  range.contains(d), let y = closest(d) ?? Optional(t.price) else { continue }
            out.append(Marker(id: "t\(i)", date: d, y: y, kind: t.type == .buy ? .buy : .sell))
        }
        for (i, dv) in detail.dividends.enumerated() {
            guard let d = Self.dayFormat.date(from: String(dv.date.prefix(10))),
                  range.contains(d), let y = closest(d) else { continue }
            out.append(Marker(id: "d\(i)", date: d, y: y, kind: .dividend))
        }
        return out
    }

    private func nearestBar(to date: Date?, in bars: [Bar]) -> Bar? {
        guard let date else { return nil }
        return bars.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The price scale, computed rather than left automatic: `AreaMark`
    /// anchors its fill at zero, so an automatic domain stretches from 0 to the
    /// high and squashes a year of price action into the top third.
    private func domain(_ bars: [Bar]) -> ClosedRange<Double> {
        let closes = bars.map(\.close)
        guard let lo = closes.min(), let hi = closes.max(), hi > lo else {
            return 0...(closes.first.map { $0 * 1.1 } ?? 1)
        }
        let pad = (hi - lo) * 0.12
        return Swift.max(0, lo - pad)...(hi + pad)
    }

    var body: some View {
        let bars = makeBars()
        let range = (bars.first?.date ?? .now)...(bars.last?.date ?? .now)
        let markers = makeMarkers(bars: bars, range: range)
        let scale = domain(bars)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if bars.count < 2 {
                EmptyState(icon: "chart.xyaxis.line", title: "No price history")
            } else {
                Chart {
                    ForEach(bars) { bar in
                        AreaMark(x: .value("Date", bar.date),
                                 yStart: .value("Floor", scale.lowerBound),
                                 yEnd: .value("Close", bar.close))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.accentSoft.opacity(0.5),
                                                        Theme.accentSoft.opacity(0.08)],
                                               startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(bars) { bar in
                        LineMark(x: .value("Date", bar.date), y: .value("Close", bar.close))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(markers) { m in
                        PointMark(x: .value("Date", m.date), y: .value("Close", m.y))
                            .symbol { MarkerGlyph(kind: m.kind) }
                    }
                    if let raw = scrubDate, let sel = nearestBar(to: raw, in: bars) {
                        RuleMark(x: .value("Date", min(max(raw, range.lowerBound), range.upperBound)))
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartScrubTip(date: sel.date,
                                              value: Fmt.number(sel.close, digits: 2))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Close", sel.close))
                            .symbolSize(46)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .chartXSelection(value: $scrubDate)
                .sensoryFeedback(.selection, trigger: nearestBar(to: scrubDate, in: bars)?.date)
                .chartYScale(domain: scale)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { mark in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel {
                            if let v = mark.as(Double.self) {
                                Text(Fmt.number(v, digits: v < 100 ? 2 : 0))
                                    .font(Theme.Typo.axis)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 132)
                .appCard(padding: Theme.Space.m + 2)

                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.l) {
            legendItem(.buy, "Buy")
            legendItem(.sell, "Sell")
            legendItem(.dividend, "Dividend")
        }
        .font(Theme.Typo.nano)
        .foregroundStyle(Theme.textSecondary)
    }

    private func legendItem(_ kind: MarkerKind, _ label: String) -> some View {
        HStack(spacing: 4) {
            MarkerGlyph(kind: kind)
            Text(label)
        }
    }
}

/// The three chart marks, drawn once so the plot and its legend can never
/// disagree about what a shape means.
private enum MarkerKind { case buy, sell, dividend }

private struct MarkerGlyph: View {
    let kind: MarkerKind

    var body: some View {
        switch kind {
        case .buy:
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8)).foregroundStyle(Theme.gain)
        case .sell:
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8)).foregroundStyle(Theme.loss)
        case .dividend:
            Circle().stroke(Theme.accent, lineWidth: 1.5)
                .background(Circle().fill(Theme.card))
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Position

private struct PositionCard: View {
    let position: StockDetailPosition
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Your position").eyebrowStyle(Theme.accent)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.l),
                                GridItem(.flexible(), spacing: Theme.Space.l)],
                      spacing: Theme.Space.m) {
                cell("Shares · avg cost",
                     "\(Fmt.shares(position.shares)) @ \(Fmt.number(position.avgCost, digits: 2))")
                cell("Market value", Fmt.amount(position.marketValue, currency: currency))
                cell("Unrealized (net)",
                     Fmt.signedAmount(position.unrealizedPl, currency: currency)
                        + " · " + Fmt.pct(position.unrealizedPlPct, digits: 1),
                     color: Theme.pl(position.unrealizedPl))
                cell("Dividends", Fmt.amount(position.dividendsReceived, currency: currency))
                cell("Realized",
                     position.realizedPl == 0 ? "—"
                        : Fmt.signedAmount(position.realizedPl, currency: currency),
                     color: position.realizedPl == 0 ? Theme.text : Theme.pl(position.realizedPl))
                cell("Total return",
                     Fmt.signedAmount(position.totalReturn, currency: currency)
                        + " · " + Fmt.pct(position.totalReturnPct, digits: 1),
                     color: Theme.pl(position.totalReturn))
            }
        }
        .appCard()
    }

    private func cell(_ label: String, _ value: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).statLabelStyle()
            Text(value)
                .font(Theme.Typo.valueSm)
                .foregroundStyle(color)
                .numeral(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 52-week range

/// Where the price sits in its year. A tick on a track says this in one glance;
/// two "52w high / 52w low" rows in a table never did.
private struct FiftyTwoWeekBar: View {
    let low: Double?
    let high: Double?
    let price: Double?

    var body: some View {
        if let low, let high, let price, high > low {
            let t = CGFloat(min(max((price - low) / (high - low), 0), 1))
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("52-week range")
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textStrong)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track).frame(height: 6)
                        Capsule().fill(Theme.accentSoft)
                            .frame(width: max(4, t * geo.size.width), height: 6)
                        Rectangle().fill(Theme.text)
                            .frame(width: 2, height: 14)
                            .offset(x: min(max(t * geo.size.width - 1, 0), geo.size.width - 2))
                    }
                    .frame(height: 14)
                }
                .frame(height: 14)

                HStack {
                    Text("Low \(Fmt.number(low, digits: 2))")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Fmt.number(price, digits: 2))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("High \(Fmt.number(high, digits: 2))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.Typo.caption)
                .numeral()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("52-week range")
            .accessibilityValue("Current \(Fmt.number(price)), between \(Fmt.number(low)) and \(Fmt.number(high))")
        }
    }
}

// MARK: - Stats grid

/// Nine cells, three across. An ETF's nine are not a company's nine — a P/E on
/// a broad-market fund is noise, and its AUM and expense ratio are what a
/// holder actually checks.
private struct StatsGrid: View {
    let fundamentals: StockDetailFundamentals
    let live: StockDetailLive
    let yieldOnCost: Double?

    private var cells: [(String, String)] {
        let f = fundamentals
        var out: [(String, String)] = [
            ("Prev close", Fmt.number(live.previousClose, digits: 2)),
            ("Day range", dayRange),
        ]
        if let cap = f.marketCap {
            out.append(("Mkt cap", Fmt.symbol(f.currency ?? "") + Fmt.compact(cap)))
        }
        if let pe = f.pe { out.append(("P/E", Fmt.number(pe))) }
        if let eps = f.eps { out.append(("EPS ttm", Fmt.number(eps))) }
        if let y = f.dividendYield { out.append(("Yield", Fmt.pct(y * 100).replacingOccurrences(of: "+", with: ""))) }
        if let beta = f.beta { out.append(("Beta", Fmt.number(beta))) }
        if let t = f.targetMeanPrice { out.append(("1-yr target", Fmt.number(t, digits: 2))) }
        if let t = f.targetMeanPrice, let p = live.price, p > 0 {
            out.append(("vs now", Fmt.pct((t - p) / p * 100, digits: 1)))
        }
        if let pb = f.priceToBook, out.count < 9 { out.append(("P/B", Fmt.number(pb))) }
        if let v = f.averageVolume, out.count < 9 { out.append(("Avg vol", Fmt.compact(v))) }
        if let ex = f.exDividendDate, out.count < 9 { out.append(("Next ex-div", Fmt.prettyDate(ex))) }
        if let yoc = yieldOnCost, out.count < 9 {
            out.append(("Yield on cost", Fmt.pct(yoc, digits: 1).replacingOccurrences(of: "+", with: "")))
        }
        return Array(out.prefix(9))
    }

    private var dayRange: String {
        guard let lo = live.dayLow, let hi = live.dayHigh else { return "—" }
        return "\(Fmt.number(lo, digits: 2))–\(Fmt.number(hi, digits: 2))"
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3),
                  spacing: Theme.Space.s) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(alignment: .leading, spacing: 0) {
                    Text(cell.0).statLabelStyle(small: true)
                    Text(cell.1)
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.text)
                        .numeral(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous))
                .shadow(color: Theme.shadow, radius: 3, x: 0, y: 1)
            }
        }
    }
}

// MARK: - 月營收

/// Taiwan-listed companies publish revenue monthly, and the YoY on that print
/// moves the stock more than any quarterly number. Bars are accent-tinted when
/// YoY is positive and grey when not — this is a level, not a P&L, so it does
/// not take the gain/loss colours.
private struct RevenueCard: View {
    let months: [MonthlyRevenue]
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CardHeaderRow(title: "Monthly revenue 月營收", caption: "FinMind · 12 m")
            BarRow(bars: Array(months.suffix(12)).map { m in
                BarRow.Bar(id: m.month, label: String(m.month.suffix(2)), value: m.revenue,
                           color: (m.yoyPct ?? 0) >= 0 ? Theme.accent : Theme.textTertiary)
            }, height: 80, signed: false)

            if let latest = months.last {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    Text("Latest \(latest.month)")
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Text(Fmt.compactMoney(latest.revenue, currency: currency))
                            .foregroundStyle(Theme.text)
                        if let yoy = latest.yoyPct {
                            Text("YoY \(Fmt.pct(yoy, digits: 1))")
                                .foregroundStyle(Theme.pl(yoy))
                        }
                    }
                    .font(Theme.Typo.inlineNum)
                    .numeral()
                }
            }
        }
        .appCard()
    }
}

// MARK: - Quarterly financials

/// Eight quarters, four columns. Gross margin is tinted when it improved on
/// the previous quarter — the one comparison in this table a reader makes
/// every time, so the table makes it for them.
private struct FinancialsCard: View {
    let quarters: [QuarterlyFinancials]

    /// "2026-03-31" is a database key; a reader wants "2026 Q1". Rows with no
    /// revenue *and* no EPS are dropped — four em-dashes in a row is noise, not
    /// data.
    private static func quarterLabel(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
            return raw
        }
        return "\(String(year)) Q\((month - 1) / 3 + 1)"
    }

    var body: some View {
        let rows = Array(quarters.filter { $0.revenue != nil || $0.epsDiluted != nil }.suffix(8))
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Quarterly financials")
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)

            HStack(spacing: Theme.Space.xs) {
                Text("Quarter").frame(maxWidth: .infinity, alignment: .leading)
                Text("Revenue").frame(maxWidth: .infinity, alignment: .trailing)
                Text("EPS").frame(width: 46, alignment: .trailing)
                Text("Gross").frame(width: 52, alignment: .trailing)
                Text("Op.").frame(width: 46, alignment: .trailing)
            }
            .statLabelStyle(small: true)
            .padding(.bottom, 2)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, q in
                let improving = index > 0 && (q.grossMargin ?? 0) > (rows[index - 1].grossMargin ?? 0)
                HStack(spacing: Theme.Space.xs) {
                    Text(Self.quarterLabel(q.quarter))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Theme.textStrong)
                    Text(Fmt.compact(q.revenue))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(Fmt.number(q.epsDiluted))
                        .frame(width: 46, alignment: .trailing)
                    Text(pct(q.grossMargin) + (improving ? " ▲" : ""))
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(improving ? Theme.gain : Theme.text)
                    Text(pct(q.operatingMargin))
                        .frame(width: 46, alignment: .trailing)
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.text)
                .numeral()
                .padding(.vertical, 5)
                if index < rows.count - 1 { RowDivider(inset: 0) }
            }
        }
        .appCard()
    }

    private func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v * (abs(v) <= 1 ? 100 : 1))
    }
}

// MARK: - Records

/// This ticker's own trades and dividends. Tap to edit; the delete lives in
/// the Trades and Dividends screens, where a swipe is the native gesture.
private struct RecordsCard: View {
    let trades: [Trade]
    let dividends: [Dividend]
    let currency: String
    let onEditTrade: (Trade) -> Void
    let onEditDividend: (Dividend) -> Void

    private enum Row: Identifiable {
        case trade(Trade), dividend(Dividend)
        var id: String {
            switch self {
            case .trade(let t): return "t\(t.id)"
            case .dividend(let d): return "d\(d.id)"
            }
        }
        var date: String {
            switch self {
            case .trade(let t): return t.tradeDate
            case .dividend(let d): return d.payDate
            }
        }
    }

    private var rows: [Row] {
        (trades.map(Row.trade) + dividends.map(Row.dividend)).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Your records")
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)

            if rows.isEmpty {
                Text("No trades or dividends recorded for this ticker.")
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Theme.Space.xs)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    line(row)
                    if index < rows.count - 1 { RowDivider(inset: 0) }
                }
            }
        }
        .appCard()
    }

    @ViewBuilder
    private func line(_ row: Row) -> some View {
        switch row {
        case .trade(let t):
            record(tag: t.type == .buy ? "BUY" : "SELL",
                   style: t.type == .buy ? .accent : .outline,
                   detail: "\(Fmt.shares(t.shares)) × \(Fmt.number(t.price, digits: 2)) · fee \(Fmt.number(t.fee, digits: 0))",
                   date: t.tradeDate) { onEditTrade(t) }
        case .dividend(let d):
            record(tag: "DIV", style: .neutral,
                   detail: Fmt.amount(d.amount, currency: d.currency)
                        + (d.notes.map { " · \($0)" } ?? ""),
                   date: d.payDate) { onEditDividend(d) }
        }
    }

    private func record(tag: String, style: TagChip.Style, detail: String, date: String,
                        onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Space.m) {
                TagChip(text: tag, style: style, width: 46)
                Text(detail)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                Text(date)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skeleton

/// A placeholder shaped like the loaded screen. A lone spinner in a full-width
/// column rendered as a skinny bar and told the reader nothing about what was
/// coming.
private struct LoadingSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            bar(width: 180, height: 26)
            bar(width: 140, height: 34)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.card).frame(height: 156)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.card).frame(height: 120)
        }
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.card).frame(width: width, height: height)
    }
}

/// A card heading with a quiet caption on the right (source + span).
struct CardHeaderRow: View {
    let title: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Typo.row).foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.s)
            Text(caption).font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
