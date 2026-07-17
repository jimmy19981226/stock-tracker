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
    @State private var period = "1y"
    @State private var loading = false
    @State private var unavailable = false

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
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            Text(d, format: .dateTime.month(.abbreviated))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading) {
                HStack(spacing: 12) {
                    legendDot(color: Theme.accent, label: "Portfolio")
                    legendDot(color: .white.opacity(0.45), label: r.benchmark.name)
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

    private func load() async {
        guard reports[period] == nil else { return }
        loading = true
        defer { loading = false }
        do {
            reports[period] = try await APIClient.shared.getPerformance(
                market: market, period: period)
        } catch let APIError.http(code, _) where code == 404 {
            unavailable = true  // older backend — hide the card
        } catch {
            // Transient — leave the card in its "not enough history" state;
            // switching periods or reopening retries.
        }
    }
}
