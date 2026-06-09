import SwiftUI
import Charts

struct DashboardView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore

    private var currency: String { market.currencyCode }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SummaryCard(summary: store.summary(for: market), currency: currency)
                EarningsCard(points: store.earnings(for: market), currency: currency)
                HoldingsSection(holdings: store.holdings(for: market), store: store)
            }
            .padding(16)
        }
        .refreshable { await store.loadAll() }
    }
}

// MARK: - Summary

private struct SummaryCard: View {
    let summary: CurrencySummary?
    let currency: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PORTFOLIO VALUE")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .tracking(0.6)
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.money(summary?.totalValue, currency: currency, digits: 0))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Spacer()
                        PLBadge(value: summary?.todayPl, pct: summary?.todayPlPct,
                                currency: currency, compact: true)
                    }
                }

                Divider().overlay(Theme.stroke)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatBlock(label: "Total P&L",
                              value: Fmt.signedMoney(summary?.totalPl, currency: currency),
                              valueColor: Theme.pl(summary?.totalPl))
                    StatBlock(label: "Return",
                              value: Fmt.pct(summary?.totalPlPct),
                              valueColor: Theme.pl(summary?.totalPlPct),
                              alignment: .trailing)
                    StatBlock(label: "Realized P&L",
                              value: Fmt.signedMoney(summary?.realizedPl, currency: currency),
                              valueColor: Theme.pl(summary?.realizedPl))
                    StatBlock(label: "Dividends",
                              value: Fmt.money(summary?.dividends, currency: currency),
                              alignment: .trailing)
                    StatBlock(label: "Cost basis",
                              value: Fmt.money(summary?.totalCost, currency: currency))
                    StatBlock(label: "This year",
                              value: Fmt.signedMoney(summary?.yearEarned, currency: currency),
                              valueColor: Theme.pl(summary?.yearEarned),
                              alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Earnings chart

private struct EarningsCard: View {
    let points: [EarningsPoint]
    let currency: String

    private struct Row: Identifiable {
        let id = UUID()
        let date: Date
        let total: Double
    }

    private var rows: [Row] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return points.compactMap { p in
            guard let d = f.date(from: String(p.date.prefix(10))) else { return nil }
            return Row(date: d, total: p.total)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Cumulative earnings") {
                    if let last = rows.last {
                        Text(Fmt.signedMoney(last.total, currency: currency))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.pl(last.total))
                    }
                }

                if rows.count < 2 {
                    EmptyState(icon: "chart.line.uptrend.xyaxis",
                               title: "Not enough history yet")
                } else {
                    Chart(rows) { row in
                        AreaMark(x: .value("Date", row.date), y: .value("Total", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        LineMark(x: .value("Date", row.date), y: .value("Total", row.total))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Theme.stroke)
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(Fmt.compact(v))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.mutedText)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(Theme.stroke)
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                    .frame(height: 160)
                }
            }
        }
    }
}

// MARK: - Holdings

private struct HoldingsSection: View {
    let holdings: [Holding]
    let store: PortfolioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Holdings") {
                Text("\(holdings.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            if holdings.isEmpty {
                Card { EmptyState(icon: "tray", title: "No positions",
                                  message: "Add a trade to start tracking.") }
            } else {
                VStack(spacing: 10) {
                    ForEach(holdings) { h in
                        NavigationLink(value: h) {
                            HoldingRow(holding: h, name: store.name(for: h.ticker))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HoldingRow: View {
    let holding: Holding
    let name: String

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                TickerBadge(ticker: holding.ticker)
                VStack(alignment: .leading, spacing: 3) {
                    Text(holding.ticker)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Text("\(Fmt.shares(holding.shares)) sh · avg \(Fmt.money(holding.avgCost, currency: holding.currency))")
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Fmt.money(holding.marketValue, currency: holding.currency, digits: 0))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    PLBadge(value: holding.unrealizedPl, pct: holding.unrealizedPlPct,
                            currency: holding.currency, compact: true)
                }
            }
        }
    }
}
