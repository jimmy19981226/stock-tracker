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

/// Hero: combined net worth — big bold number with a change line under it.
private struct NetWorthCard: View {
    let overview: PortfolioOverview?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Investing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            Text(Fmt.bigMoney(overview?.combined.twd, currency: "TWD"))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(spacing: 10) {
                Text("≈ \(Fmt.bigMoney(overview?.combined.usd, currency: "USD"))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                if let fx = overview?.fx.usdTwd {
                    Text("USD/TWD \(Fmt.number(fx, digits: 2))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// One market row, flat with a hairline separator and a solid change pill.
private struct MarketCard: View {
    let market: MarketCode
    let summary: CurrencySummary?
    let isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(market.flag).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 3) {
                    Text(market.displayName)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOpen ? Theme.positive : Theme.mutedText)
                            .frame(width: 6, height: 6)
                        Text(isOpen ? "Market open" : "Market closed")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text("· \(summary?.holdingsCount ?? 0) positions")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Fmt.money(summary?.totalValue, currency: market.currencyCode, digits: 0))
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    PLBadge(value: summary?.todayPl, pct: summary?.todayPlPct,
                            currency: market.currencyCode, compact: true)
                }
            }
            .padding(.vertical, 14)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
