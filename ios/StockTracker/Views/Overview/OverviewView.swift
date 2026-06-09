import SwiftUI

/// Landing screen: combined net worth across both markets plus a tappable card
/// per market. The iOS-native equivalent of the web app's Overview page.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var overview: PortfolioOverview?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = store.errorMessage {
                    ErrorBanner(message: error) {
                        Task { await reload() }
                    }
                }

                NetWorthCard(overview: overview)

                ForEach(MarketCode.allCases) { market in
                    NavigationLink(value: market) {
                        MarketCard(
                            market: market,
                            summary: store.summary(for: market),
                            isOpen: store.isOpen(market)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if store.loading && store.summaries.isEmpty {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Portfolios")
        .navigationDestination(for: MarketCode.self) { market in
            PortfolioView(market: market)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .refreshable { await reload() }
        .task { await loadOverview() }
    }

    private func reload() async {
        await store.loadAll()
        await loadOverview()
    }

    private func loadOverview() async {
        overview = try? await APIClient.shared.getOverview()
    }
}

/// Hero card: combined net worth (in TWD) with the USD equivalent + FX line.
private struct NetWorthCard: View {
    let overview: PortfolioOverview?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("TOTAL NET WORTH")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .tracking(0.6)

                Text(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text("≈ \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                    if let fx = overview?.fx.usdTwd {
                        Text("· USD/TWD \(Fmt.number(fx, digits: 2))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedText)
                    }
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.22), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        )
    }
}

/// One market summary row, tappable into that portfolio.
private struct MarketCard: View {
    let market: MarketCode
    let summary: CurrencySummary?
    let isOpen: Bool

    var body: some View {
        Card {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Text(market.flag).font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(market.displayName)
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isOpen ? Theme.positive : Theme.mutedText)
                                .frame(width: 7, height: 7)
                            Text(isOpen ? "Market open" : "Market closed")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.mutedText)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.money(summary?.totalValue, currency: market.currencyCode, digits: 0))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer()
                    PLBadge(value: summary?.todayPl, pct: summary?.todayPlPct,
                            currency: market.currencyCode, compact: true)
                }

                HStack {
                    StatBlock(label: "Total P&L",
                              value: Fmt.signedMoney(summary?.totalPl, currency: market.currencyCode),
                              valueColor: Theme.pl(summary?.totalPl))
                    StatBlock(label: "Positions",
                              value: "\(summary?.holdingsCount ?? 0)",
                              alignment: .trailing)
                }
            }
        }
    }
}
