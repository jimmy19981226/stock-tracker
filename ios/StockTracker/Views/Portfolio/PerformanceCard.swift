import SwiftUI
import Charts

/// Performance card — the "am I beating the market?" view.
///
/// TWR (time-weighted, comparable to an index) and XIRR (money-weighted, what
/// your cash actually earned) with a period picker, the portfolio's % curve
/// overlaid on the market's benchmark index (加權指數 / S&P 500), and monthly
/// P&L bars (期間績效). Data comes from /api/portfolio/performance; the card
/// hides itself entirely if the endpoint isn't available.
struct PerformanceCard: View {
    let market: MarketCode

    @State private var reports: [String: PerformanceReport] = [:]
    @State private var period = "max"
    @State private var loading = false
    @State private var unavailable = false
    @State private var benchmarks: BenchmarkSettings?
    @State private var switchingBenchmark = false

    private static let periods: [(String, String)] =
        [("3mo", "3M"), ("6mo", "6M"), ("ytd", "YTD"), ("1y", "1Y"), ("max", "MAX")]

    private var report: PerformanceReport? { reports[period] }

    var body: some View {
        if unavailable {
            EmptyView()
        } else {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Performance")
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                    }

                    // Period tabs
                    HStack(spacing: 4) {
                        ForEach(Self.periods, id: \.0) { p in
                            Button {
                                period = p.0
                            } label: {
                                Text(p.1)
                                    .font(.system(.caption, design: .rounded).weight(.bold))
                                    .foregroundStyle(period == p.0 ? Theme.primaryText : Theme.mutedText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(period == p.0 ? Theme.cardElevated : .clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let r = report {
                        statsRow(r)
                        comparisonChart(r)
                        monthlyBars(r)
                    } else if !loading {
                        Text("Not enough history yet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedText)
                    }
                }
            }
            .task(id: period) { await load() }
            .task { await loadBenchmarks() }
        }
    }

    // MARK: - Stats

    private func statsRow(_ r: PerformanceReport) -> some View {
        let beat: Double? = {
            guard let twr = r.twrPct, let b = r.benchmark.returnPct else { return nil }
            return twr - b
        }()
        return HStack(spacing: 0) {
            stat("Return (TWR)", pct: r.twrPct)
            stat(r.twrAnnualizedPct != nil ? "Annualized" : "XIRR (yr)",
                 pct: r.twrAnnualizedPct ?? r.xirrPct)
            stat("vs \(r.benchmark.name)", pct: beat, signedColor: true)
        }
    }

    private func stat(_ label: String, pct: Double?, signedColor: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(pct != nil ? Fmt.pct(pct) : "—")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(signedColor ? Theme.pl(pct) : Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Portfolio vs benchmark chart

    private struct SeriesPoint: Identifiable {
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
        let series: String
        let date: Date
        let pct: Double
    }

    private func chartPoints(_ r: PerformanceReport) -> [SeriesPoint] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        var out: [SeriesPoint] = []
        for p in r.portfolioSeries {
            if let d = f.date(from: p.date) {
                out.append(SeriesPoint(series: "Portfolio", date: d, pct: p.pct))
            }
        }
        for p in r.benchmark.series {
            if let d = f.date(from: p.date) {
                out.append(SeriesPoint(series: r.benchmark.name, date: d, pct: p.pct))
            }
        }
        return out
    }

    @ViewBuilder
    private func comparisonChart(_ r: PerformanceReport) -> some View {
        let pts = chartPoints(r)
        if pts.count >= 4 {
            let first = pts.map(\.date).min() ?? Date()
            let last = pts.map(\.date).max() ?? Date()
            Chart(pts) { p in
                LineMark(x: .value("Date", p.date), y: .value("%", p.pct))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series == "Portfolio" ? 2.2 : 1.4))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale([
                "Portfolio": Theme.accent,
                r.benchmark.name: Color.white.opacity(0.45),
            ])
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text("\(Int(d))%")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: Fmt.axisDates(from: first, to: last)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            Text(d, format: Fmt.axisFormat(from: first, to: last))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading) {
                HStack(spacing: 12) {
                    legendDot(color: Theme.accent, label: "Portfolio")
                    benchmarkPicker(current: r.benchmark.name)
                }
            }
            .frame(height: 170)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// The benchmark legend doubles as its picker — tap the name you're being
    /// compared against to compare against something else. Kept in the legend
    /// rather than Settings so it sits right next to the line it controls.
    @ViewBuilder
    private func benchmarkPicker(current: String) -> some View {
        let presets = benchmarks?.presets(for: market) ?? []
        let selected = benchmarks?.symbol(for: market)
        Menu {
            ForEach(presets) { p in
                Button {
                    Task { await switchBenchmark(to: p.symbol) }
                } label: {
                    // Checkmark on the active one so the menu reads as a radio
                    // group. An empty systemImage still reserves space, so the
                    // inactive rows use a bare Text instead.
                    if p.symbol == selected {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.45)).frame(width: 6, height: 6)
                Text(current).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                if switchingBenchmark {
                    ProgressView().controlSize(.mini)
                } else if !presets.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.mutedText)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(presets.isEmpty || switchingBenchmark)
    }

    // MARK: - Monthly P&L bars (期間績效)

    @ViewBuilder
    private func monthlyBars(_ r: PerformanceReport) -> some View {
        let months = Array(r.monthly.suffix(12))
        if months.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Monthly P&L")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.mutedText)
                Chart(months) { m in
                    BarMark(x: .value("Month", String(m.month.suffix(2))),
                            y: .value("P&L", m.pl))
                        .foregroundStyle(m.pl >= 0 ? Theme.positive : Theme.negative)
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine().foregroundStyle(Theme.stroke)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Fmt.compact(d))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.mutedText)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { v in
                        AxisValueLabel {
                            if let s = v.as(String.self) {
                                Text(s)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.mutedText)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    // MARK: - Loading

    @State private var fetchedPeriods: Set<String> = []

    private func cacheKey(_ p: String) -> String {
        "performance-\(market.rawValue)-\(p)"
    }

    /// Tolerant: an older backend without /api/portfolio/benchmark just leaves
    /// the legend as a plain (unpickable) label.
    private func loadBenchmarks() async {
        benchmarks = try? await APIClient.shared.getBenchmarks()
    }

    /// Switch this market's comparison symbol and re-pull every period. The
    /// benchmark is part of each report, so all cached tabs are stale — drop
    /// them (memory AND disk) rather than let a tab switch show a mismatched
    /// legend and curve.
    private func switchBenchmark(to symbol: String) async {
        guard symbol != benchmarks?.symbol(for: market), !switchingBenchmark else { return }
        switchingBenchmark = true
        defer { switchingBenchmark = false }
        do {
            benchmarks = try await APIClient.shared.setBenchmark(market: market, symbol: symbol)
        } catch {
            return  // leave the current benchmark in place
        }
        for p in Self.periods.map(\.0) {
            DiskCache.remove(name: cacheKey(p))
        }
        reports.removeAll()
        fetchedPeriods.removeAll()
        await load()
    }

    /// Stale-while-refresh: paint the last saved report instantly, then fetch
    /// a fresh one (the first server-side build can take minutes on a cold
    /// backend — a spinner that long reads as broken).
    private func load() async {
        if reports[period] == nil,
           let cached = DiskCache.load(PerformanceReport.self, name: cacheKey(period)) {
            reports[period] = cached
        }
        guard fetchedPeriods.insert(period).inserted else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await APIClient.shared.getPerformance(
                market: market, period: period)
            reports[period] = fresh
            DiskCache.save(fresh, as: cacheKey(period))
        } catch let APIError.http(code, _) where code == 404 {
            unavailable = true  // older backend — hide the card
        } catch {
            // Transient (timeout on a first heavy build) — keep whatever is
            // shown; allow a retry on the next appearance of this period.
            fetchedPeriods.remove(period)
        }
    }
}
