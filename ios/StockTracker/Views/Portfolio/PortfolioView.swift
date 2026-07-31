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
    @State private var tab: PortfolioTab =
        (ProcessInfo.processInfo.environment["UITEST_TRADE_FORM"] == "1"
         || ProcessInfo.processInfo.environment["UITEST_IMPORT"] == "1") ? .trades : .dashboard

    var body: some View {
        VStack(spacing: 0) {
            UnderlineTabs(
                tabs: PortfolioTab.allCases.map { ($0, $0.rawValue) },
                selection: $tab
            )
            .padding(.top, 6)

            switch tab {
            case .dashboard: DashboardView(market: market)
            case .trades: TradesView(market: market)
            case .dividends: DividendsView(market: market)
            }

            // Pinned market-index strip — stays visible across all three tabs
            // and shows only this market's indices.
            IndexBarView(market: market)
        }
        .screenBackground()
        .navigationTitle(market.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Holding.self) { h in
            StockDetailView(ticker: h.ticker, market: market)
        }
        // Tapping an index (strip or expanded card) opens the same detail
        // page a stock gets — chart, day stats, everything that applies.
        .navigationDestination(for: IndexQuote.self) { q in
            StockDetailView(ticker: q.symbol, market: q.market)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The market's full name, set as a title — the flag emoji that
                // used to sit here rendered as clip-art beside typography that
                // is otherwise entirely drawn, and it read as decoration rather
                // than as the screen's subject.
                Text(market.displayName)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
            }
        }
        .onAppear { store.startPolling(market: market) }
        .onDisappear { store.stopPolling() }
    }
}
