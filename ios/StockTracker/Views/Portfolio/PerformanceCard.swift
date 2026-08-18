import SwiftUI

/// "Am I beating the market?" — TWR against the market's benchmark index, the
/// two curves overlaid, and twelve months of P&L underneath.
///
/// The benchmark name in the legend *is* its picker: tapping it cycles to the
/// next preset. That keeps the control beside the line it governs instead of
/// exiling it to Settings, and it costs no chrome.
struct PerformanceCard: View {
    let market: MarketCode

    @State private var reports: [String: PerformanceReport] = [:]
    @State private var period = "max"
    @State private var loading = false
    @State private var unavailable = false
    @State private var benchmarks: BenchmarkSettings?
    @State private var switching = false
    @State private var fetchedPeriods: Set<String> = []

    private static let periods: [(String, String)] =
        [("3mo", "3M"), ("6mo", "6M"), ("ytd", "YTD"), ("1y", "1Y"), ("max", "MAX")]

    private var report: PerformanceReport? { reports[period] }

    var body: some View {
        if unavailable {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Performance")
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if loading { ProgressView().controlSize(.small).tint(Theme.textTertiary) }
                }

                SegmentedControl(options: Self.periods.map { ($0.0, $0.1) },
                                 selection: $period)
                    .padding(.bottom, 2)

                if let r = report {
                    stats(r).padding(.bottom, 2)
                    legend(r)
                    ComparisonChart(portfolio: series(r.portfolioSeries),
                                    benchmark: series(r.benchmark.series))
                    monthly(r)
                } else if !loading {
                    Text("Not enough history yet.")
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .appCard()
            .task(id: period) { await load() }
            .task { benchmarks = try? await APIClient.shared.getBenchmarks() }
        }
    }

    // MARK: Stats

    private func stats(_ r: PerformanceReport) -> some View {
        let beat: Double? = {
            guard let twr = r.twrPct, let b = r.benchmark.returnPct else { return nil }
            return twr - b
        }()
        return HStack(alignment: .top, spacing: Theme.Space.xs) {
            stat("Return (TWR)", r.twrPct)
            stat(r.twrAnnualizedPct != nil ? "Annualized" : "XIRR (yr)",
                 r.twrAnnualizedPct ?? r.xirrPct)
            stat("vs \(r.benchmark.name)", beat)
        }
    }

    private func stat(_ label: String, _ pct: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).statLabelStyle(small: true)
            Text(pct != nil ? Fmt.pct(pct, digits: 1) : "—")
                .font(Theme.Typo.valueSm)
                .foregroundStyle(Theme.pl(pct))
                .numeral(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Legend / benchmark picker

    private func legend(_ r: PerformanceReport) -> some View {
        HStack(spacing: Theme.Space.l) {
            LegendDot(color: Theme.accent, label: "Portfolio")
            LegendDot(color: Theme.textTertiary, label: r.benchmark.name,
                      chevron: !presets.isEmpty) {
                Task { await cycleBenchmark(from: r.benchmark) }
            }
            if switching { ProgressView().controlSize(.mini).tint(Theme.textTertiary) }
        }
    }

    private var presets: [BenchmarkSettings.Preset] { benchmarks?.presets(for: market) ?? [] }

    /// Advance to the next preset, wrapping. Every cached period's report
    /// carries its own benchmark, so they are all stale afterwards — dropped
    /// rather than left to show a legend that disagrees with its curve.
    private func cycleBenchmark(from current: PerformanceReport.Benchmark) async {
        guard !presets.isEmpty, !switching else { return }
        let index = presets.firstIndex { $0.symbol == (benchmarks?.symbol(for: market) ?? current.symbol) }
        let next = presets[((index ?? 0) + 1) % presets.count]
        switching = true
        defer { switching = false }
        guard let updated = try? await APIClient.shared.setBenchmark(market: market,
                                                                    symbol: next.symbol)
        else { return }
        benchmarks = updated
        for p in Self.periods.map(\.0) { DiskCache.remove(name: cacheKey(p)) }
        reports.removeAll()
        fetchedPeriods.removeAll()
        await load()
    }

    // MARK: Series

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func series(_ raw: [PerformanceReport.PctPoint]) -> [ComparisonChart.Point] {
        raw.enumerated().compactMap { index, p in
            guard let d = Self.dayFormat.date(from: p.date) else { return nil }
            return ComparisonChart.Point(id: index, date: d, pct: p.pct)
        }
    }

    // MARK: Monthly P&L

    @ViewBuilder
    private func monthly(_ r: PerformanceReport) -> some View {
        let months = Array(r.monthly.suffix(12))
        if months.count >= 2 {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Monthly P&L").statLabelStyle(small: true)
                BarRow(bars: months.map {
                    BarRow.Bar(id: $0.month, label: String($0.month.suffix(2)), value: $0.pl)
                })
            }
            .padding(.top, Theme.Space.m)
        }
    }

    // MARK: Loading

    private func cacheKey(_ p: String) -> String { "performance-\(market.rawValue)-\(p)" }

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
            let fresh = try await APIClient.shared.getPerformance(market: market, period: period)
            reports[period] = fresh
            DiskCache.save(fresh, as: cacheKey(period))
        } catch let APIError.http(code, _) where code == 404 {
            unavailable = true  // older backend — hide the card
        } catch {
            fetchedPeriods.remove(period)
        }
    }
}
