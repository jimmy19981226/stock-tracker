import SwiftUI

enum PortfolioTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case trades = "Trades"
    case dividends = "Dividends"
    var id: String { rawValue }
}

/// A single market's portfolio. A segmented control swaps between the dashboard,
/// the trade log and the dividend log — the iOS take on the web app's tab bar.
struct PortfolioView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var tab: PortfolioTab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(PortfolioTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch tab {
            case .dashboard: DashboardView(market: market)
            case .trades: TradesView(market: market)
            case .dividends: DividendsView(market: market)
            }
        }
        .screenBackground()
        .navigationTitle(market.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Holding.self) { h in
            StockDetailView(ticker: h.ticker, market: market)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(market.flag)
                    Text(market.rawValue).font(.headline)
                }
            }
        }
        .onAppear { store.startPolling(market: market) }
        .onDisappear { store.stopPolling() }
    }
}
