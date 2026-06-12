import SwiftUI
import Charts

/// Full-screen stock detail pushed from a holding row: live quote, price chart
/// with the user's buy/sell markers, their position, and key fundamentals.
struct StockDetailView: View {
    let ticker: String
    let market: MarketCode

    @State private var detail: StockDetail?
    @State private var period: HistoryPeriod = .oneYear
    @State private var loading = true
    @State private var error: String?

    private var currency: String {
        detail?.fundamentals.currency ?? market.currencyCode
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading && detail == nil {
                    ProgressView().padding(.top, 60)
                } else if let error, detail == nil {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if let detail {
                    PriceHeader(detail: detail, currency: currency)
                    ChartCard(detail: detail, period: $period, currency: currency)
                    if let pos = detail.position {
                        PositionCard(position: pos, currency: currency,
                                     yieldOnCost: detail.yieldOnCost)
                    }
                    FundamentalsCard(f: detail.fundamentals, currency: currency)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(ticker)
        .navigationBarTitleDisplayMode(.inline)
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
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: Fmt.axisFormat(from: dateRange.lowerBound,
                                                              to: dateRange.upperBound))
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

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        if let v = f.marketCap { r.append(("Market cap", Fmt.compact(v))) }
        if let v = f.pe { r.append(("P/E", Fmt.number(v))) }
        if let v = f.forwardPe { r.append(("Fwd P/E", Fmt.number(v))) }
        if let v = f.eps { r.append(("EPS", Fmt.number(v))) }
        if let v = f.dividendYield { r.append(("Div yield", Fmt.pct(v * 100))) }
        if let v = f.beta { r.append(("Beta", Fmt.number(v))) }
        if let v = f.priceToBook { r.append(("P/B", Fmt.number(v))) }
        if let v = f.fiftyTwoWeekHigh { r.append(("52w high", Fmt.number(v))) }
        if let v = f.fiftyTwoWeekLow { r.append(("52w low", Fmt.number(v))) }
        if let v = f.averageVolume { r.append(("Avg vol", Fmt.compact(v))) }
        return r
    }

    var body: some View {
        if rows.isEmpty { EmptyView() } else {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Fundamentals")
                    if let sector = f.sector {
                        Text(sector + (f.industry.map { " · \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
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
