import SwiftUI
import Charts

/// Full-screen stock detail pushed from a holding row: live quote, price chart
/// with the user's buy/sell markers, their position, and key fundamentals.
struct StockDetailView: View {
    let ticker: String
    let market: MarketCode

    @EnvironmentObject private var store: PortfolioStore
    @State private var detail: StockDetail?
    @State private var period: HistoryPeriod = .oneYear
    @State private var loading = true
    @State private var error: String?

    // Manage this stock's records right from the detail page.
    @State private var showAddTrade = false
    @State private var showAddDividend = false
    @State private var editingTrade: Trade?
    @State private var editingDividend: Dividend?
    @State private var pendingDelete: RecordDelete?
    @State private var actionError: String?

    private var currency: String {
        detail?.fundamentals.currency ?? market.currencyCode
    }

    private var myTrades: [Trade] {
        store.trades(for: market).filter { $0.ticker == ticker }
    }

    private var myDividends: [Dividend] {
        store.dividends(for: market).filter { $0.ticker == ticker }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading && detail == nil {
                    LoadingSkeleton()
                } else if let error, detail == nil {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if let detail {
                    PriceHeader(detail: detail, currency: currency)
                    ChartCard(detail: detail, period: $period, currency: currency)
                    if let pos = detail.position {
                        PositionCard(position: pos, currency: currency,
                                     yieldOnCost: detail.yieldOnCost)
                    }
                    RecordsCard(trades: myTrades, dividends: myDividends,
                                currency: currency,
                                onEditTrade: { editingTrade = $0 },
                                onEditDividend: { editingDividend = $0 },
                                onDeleteTrade: { pendingDelete = .trade($0) },
                                onDeleteDividend: { pendingDelete = .dividend($0) })
                    FundamentalsCard(f: detail.fundamentals, currency: currency,
                                     currentPrice: detail.live.price)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(ticker)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAddTrade = true } label: {
                        Label("Add trade", systemImage: "arrow.left.arrow.right")
                    }
                    Button { showAddDividend = true } label: {
                        Label("Add dividend", systemImage: "dollarsign.circle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddTrade, onDismiss: reload) {
            TradeFormView(market: market, existing: nil, prefillTicker: ticker)
        }
        .sheet(isPresented: $showAddDividend, onDismiss: reload) {
            DividendFormView(market: market, existing: nil, prefillTicker: ticker)
        }
        .sheet(item: $editingTrade, onDismiss: reload) { trade in
            TradeFormView(market: market, existing: trade)
        }
        .sheet(item: $editingDividend, onDismiss: reload) { div in
            DividendFormView(market: market, existing: div)
        }
        .confirmationDialog(
            "Delete this record?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { record in
            Button("Delete", role: .destructive) {
                Task { await performDelete(record) }
            }
        } message: { record in
            Text(record.summary)
        }
        .alert("Couldn't delete record", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task(id: period) { await load() }
    }

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

    /// After a form sheet closes: the form already refreshed the store; re-fetch
    /// the detail so the position card and chart markers reflect the change.
    private func reload() {
        Task { await load() }
    }

    private func performDelete(_ record: RecordDelete) async {
        do {
            switch record {
            case .trade(let t): try await APIClient.shared.deleteTrade(t.id)
            case .dividend(let d): try await APIClient.shared.deleteDividend(d.id)
            }
            await store.loadAll()
            await load()
        } catch {
            actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A trade or dividend queued for delete confirmation.
private enum RecordDelete: Identifiable {
    case trade(Trade)
    case dividend(Dividend)

    var id: String {
        switch self {
        case .trade(let t): return "trade-\(t.id)"
        case .dividend(let d): return "dividend-\(d.id)"
        }
    }

    var summary: String {
        switch self {
        case .trade(let t):
            return "\(t.type == .buy ? "Buy" : "Sell") \(Fmt.shares(t.shares)) \(t.ticker) on \(Fmt.prettyDate(t.tradeDate))"
        case .dividend(let d):
            return "\(d.ticker) dividend of \(Fmt.money(d.amount, currency: d.currency)) on \(Fmt.prettyDate(d.payDate))"
        }
    }
}

// MARK: - Records (trades & dividends for this stock)

/// This stock's trade and dividend log, newest first, with add/edit/delete —
/// so records can be managed without leaving the detail page.
private struct RecordsCard: View {
    let trades: [Trade]
    let dividends: [Dividend]
    let currency: String
    let onEditTrade: (Trade) -> Void
    let onEditDividend: (Dividend) -> Void
    let onDeleteTrade: (Trade) -> Void
    let onDeleteDividend: (Dividend) -> Void

    private enum Row: Identifiable {
        case trade(Trade)
        case dividend(Dividend)

        var id: String {
            switch self {
            case .trade(let t): return "trade-\(t.id)"
            case .dividend(let d): return "dividend-\(d.id)"
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
        (trades.map(Row.trade) + dividends.map(Row.dividend))
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Trades & dividends")
                if rows.isEmpty {
                    Text("No records for this stock yet — use + to add a trade or dividend.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in recordRow(row) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ row: Row) -> some View {
        switch row {
        case .trade(let t):
            recordLine(
                tag: t.type == .buy ? "Buy" : "Sell",
                tagColor: t.type == .buy ? Theme.positive : Theme.negative,
                detail: "\(Fmt.shares(t.shares)) @ \(Fmt.money(t.price, currency: currency))",
                date: t.tradeDate,
                value: Fmt.money(t.shares * t.price, currency: currency, digits: 0),
                valueColor: Theme.primaryText,
                onEdit: { onEditTrade(t) },
                onDelete: { onDeleteTrade(t) }
            )
        case .dividend(let d):
            recordLine(
                tag: "Dividend",
                tagColor: Theme.accent,
                detail: nil,
                date: d.payDate,
                value: "+" + Fmt.money(d.amount, currency: d.currency),
                valueColor: Theme.positive,
                onEdit: { onEditDividend(d) },
                onDelete: { onDeleteDividend(d) }
            )
        }
    }

    private func recordLine(tag: String, tagColor: Color, detail: String?,
                            date: String, value: String, valueColor: Color,
                            onEdit: @escaping () -> Void,
                            onDelete: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tag)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tagColor)
                        if let detail {
                            Text(detail)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                        }
                    }
                    Text(Fmt.prettyDate(date))
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(valueColor)
                // Explicit affordance — edit/delete shouldn't hide behind a
                // long-press only.
                Menu {
                    Button("Edit") { onEdit() }
                    Button("Delete", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            .contextMenu {
                Button("Edit") { onEdit() }
                Button("Delete", role: .destructive) { onDelete() }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

// MARK: - Loading skeleton

/// Full-width pulsing placeholder mirroring the loaded layout (header, chart,
/// stat cards). Replaces the lone spinner, whose content-hugging column
/// rendered as a weird skinny bar while the detail loaded.
private struct LoadingSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 130, height: 14)
                bar(width: 210, height: 34)
                bar(width: 160, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.cardElevated)
                .frame(height: 220)

            cardBlock
            cardBlock
        }
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    private var cardBlock: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                bar(width: 110, height: 13)
                ForEach(0..<3, id: \.self) { _ in
                    HStack {
                        bar(width: 90, height: 12)
                        Spacer()
                        bar(width: 70, height: 12)
                    }
                }
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Theme.cardElevated)
            .frame(width: width, height: height)
    }
}

// MARK: - Header

private struct PriceHeader: View {
    let detail: StockDetail
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.name)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(Fmt.money(detail.live.price, currency: currency))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .rollingNumber(detail.live.price)
            ChangeLine(value: detail.live.todayChange, pct: detail.live.todayChangePct,
                       currency: currency)

            HStack(spacing: 18) {
                miniStat("Open", detail.live.dayOpen)
                miniStat("High", detail.live.dayHigh)
                miniStat("Low", detail.live.dayLow)
                miniStat("Prev", detail.live.previousClose)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniStat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.mutedText)
            Text(Fmt.number(value)).font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Chart

private struct ChartCard: View {
    let detail: StockDetail
    @Binding var period: HistoryPeriod
    let currency: String
    @State private var scrubDate: Date?

    private struct Bar: Identifiable {
        let id = UUID()
        let date: Date
        let close: Double
    }
    private struct Marker: Identifiable {
        let id = UUID()
        let date: Date
        let buy: Bool
        let price: Double   // y-position, resolved against bars up front
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Parse once per body evaluation — never recompute inside Chart closures
    // (Charts calls those per data point; recomputing here is O(n²) parsing).
    private func makeBars() -> [Bar] {
        detail.history.compactMap { b in
            guard let d = Self.dayFormat.date(from: String(b.date.prefix(10))),
                  let c = b.close else { return nil }
            return Bar(date: d, close: c)
        }
    }

    private func nearestBar(to date: Date?, in bars: [Bar]) -> Bar? {
        guard let date else { return nil }
        return bars.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    private func makeMarkers(bars: [Bar], range: ClosedRange<Date>) -> [Marker] {
        detail.trades.compactMap { t in
            // The backend sends every trade for the ticker; drop the ones
            // outside the charted period or they stretch the time axis.
            guard let d = Self.dayFormat.date(from: String(t.date.prefix(10))),
                  range.contains(d) else { return nil }
            // Nearest close so the marker sits on the line.
            let y = bars.min(by: {
                abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d))
            })?.close ?? t.price
            return Marker(date: d, buy: t.type == .buy, price: y)
        }
    }

    var body: some View {
        let bars = makeBars()
        let dateRange = (bars.first?.date ?? .now)...(bars.last?.date ?? .now)
        let markers = makeMarkers(bars: bars, range: dateRange)
        let up = (bars.last?.close ?? 0) >= (bars.first?.close ?? 0)
        let color = up ? Theme.positive : Theme.negative

        VStack(spacing: 12) {
            UnderlineTabs(
                tabs: HistoryPeriod.allCases.map { ($0, $0.label) },
                selection: $period,
                font: .system(.caption, design: .rounded).weight(.bold)
            )

            if bars.count < 2 {
                EmptyState(icon: "chart.xyaxis.line", title: "No price history")
            } else {
                Chart {
                    ForEach(bars) { bar in
                        LineMark(x: .value("Date", bar.date), y: .value("Close", bar.close))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(color)
                        AreaMark(x: .value("Date", bar.date), y: .value("Close", bar.close))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [color.opacity(0.18), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                    }
                    ForEach(markers) { m in
                        PointMark(x: .value("Date", m.date), y: .value("Close", m.price))
                            .symbol {
                                Image(systemName: m.buy ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(m.buy ? Theme.positive : Theme.negative)
                            }
                    }
                    // Finger scrubbing: the rule + tip track the finger
                    // continuously; only the dot snaps to the nearest bar so
                    // it sits on the line.
                    if let raw = scrubDate, let sel = nearestBar(to: raw, in: bars) {
                        let x = min(max(raw, dateRange.lowerBound), dateRange.upperBound)
                        RuleMark(x: .value("Date", x))
                            .foregroundStyle(Theme.mutedText.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartScrubTip(date: sel.date,
                                              value: Fmt.money(sel.close, currency: currency))
                            }
                        PointMark(x: .value("Date", sel.date), y: .value("Close", sel.close))
                            .symbolSize(50)
                            .foregroundStyle(color)
                    }
                }
                .chartXSelection(value: $scrubDate)
                // Tick as the scrub dot snaps from bar to bar.
                .sensoryFeedback(.selection, trigger: nearestBar(to: scrubDate, in: bars)?.date)
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Fmt.compact(v)).font(.caption2)
                                    .foregroundStyle(Theme.mutedText)
                            }
                        }
                    }
                }
                .chartXScale(domain: dateRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(format: Fmt.axisFormat(from: dateRange.lowerBound,
                                                              to: dateRange.upperBound),
                                       anchor: Fmt.axisAnchor(value.index, of: value.count))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                .frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Position

private struct PositionCard: View {
    let position: StockDetailPosition
    let currency: String
    let yieldOnCost: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Your position")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    StatBlock(label: "Shares", value: Fmt.shares(position.shares))
                    StatBlock(label: "Avg cost",
                              value: Fmt.money(position.avgCost, currency: currency),
                              alignment: .trailing)
                    StatBlock(label: "Market value",
                              value: Fmt.money(position.marketValue, currency: currency, digits: 0))
                    StatBlock(label: "Unrealized",
                              value: Fmt.signedMoney(position.unrealizedPl, currency: currency),
                              valueColor: Theme.pl(position.unrealizedPl),
                              alignment: .trailing)
                    StatBlock(label: "Realized",
                              value: Fmt.signedMoney(position.realizedPl, currency: currency),
                              valueColor: Theme.pl(position.realizedPl))
                    StatBlock(label: "Dividends",
                              value: Fmt.money(position.dividendsReceived, currency: currency),
                              alignment: .trailing)
                    StatBlock(label: "Total return",
                              value: Fmt.signedMoney(position.totalReturn, currency: currency),
                              valueColor: Theme.pl(position.totalReturn))
                    StatBlock(label: "Return %",
                              value: Fmt.pct(position.totalReturnPct),
                              valueColor: Theme.pl(position.totalReturnPct),
                              alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Fundamentals

private struct FundamentalsCard: View {
    let f: StockDetailFundamentals
    let currency: String
    /// Live price, so the 52-week bar can mark where the stock trades now.
    var currentPrice: Double?

    /// The bar replaces the plain 52w high/low text rows; they return to the
    /// grid only when the bar can't render (missing price or a flat range).
    private var showRangeBar: Bool {
        guard let lo = f.fiftyTwoWeekLow, let hi = f.fiftyTwoWeekHigh,
              let p = currentPrice else { return false }
        return hi > lo && p > 0
    }

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        if let v = f.marketCap { r.append(("Market cap", Fmt.compact(v))) }
        if let v = f.pe { r.append(("P/E", Fmt.number(v))) }
        if let v = f.forwardPe { r.append(("Fwd P/E", Fmt.number(v))) }
        if let v = f.eps { r.append(("EPS", Fmt.number(v))) }
        if let v = f.dividendYield { r.append(("Div yield", Fmt.pct(v * 100))) }
        if let v = f.beta { r.append(("Beta", Fmt.number(v))) }
        if let v = f.priceToBook { r.append(("P/B", Fmt.number(v))) }
        if !showRangeBar {
            if let v = f.fiftyTwoWeekHigh { r.append(("52w high", Fmt.number(v))) }
            if let v = f.fiftyTwoWeekLow { r.append(("52w low", Fmt.number(v))) }
        }
        if let v = f.averageVolume { r.append(("Avg vol", Fmt.compact(v))) }
        return r
    }

    var body: some View {
        if rows.isEmpty && !showRangeBar { EmptyView() } else {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Fundamentals")
                    if let sector = f.sector {
                        Text(sector + (f.industry.map { " · \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if showRangeBar, let lo = f.fiftyTwoWeekLow,
                       let hi = f.fiftyTwoWeekHigh, let price = currentPrice {
                        FiftyTwoWeekBar(low: lo, high: hi, price: price)
                            .padding(.vertical, 2)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                            StatBlock(label: row.0, value: row.1,
                                      alignment: idx.isMultiple(of: 2) ? .leading : .trailing)
                        }
                    }
                }
            }
        }
    }
}

/// Where today's price sits inside the 52-week range: a thin track with a
/// marker dot, low/high values at the ends, and the current price above the
/// marker. Reads at a glance what the "52w high / 52w low" rows only implied.
private struct FiftyTwoWeekBar: View {
    let low: Double
    let high: Double
    let price: Double

    /// 0…1 position of the current price along the range (clamped — the live
    /// quote can momentarily poke past a stale 52w bound).
    private var t: CGFloat {
        CGFloat(min(max((price - low) / (high - low), 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("52-WEEK RANGE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mutedText)
                .tracking(0.4)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.cardElevated)
                        .frame(height: 5)
                    // Filled portion up to the current price.
                    Capsule()
                        .fill(
                            LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(t * w, 5), height: 5)
                    // Current-price marker with a surface ring so it reads on
                    // top of the filled track.
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                        .offset(x: t * w - 5.5)
                }
                .frame(height: 11)
            }
            .frame(height: 11)

            HStack {
                Text(Fmt.number(low))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(Fmt.number(price))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text(Fmt.number(high))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("52-week range")
        .accessibilityValue(
            "Current \(Fmt.number(price)), between \(Fmt.number(low)) and \(Fmt.number(high))"
        )
    }
}
