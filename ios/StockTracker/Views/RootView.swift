import SwiftUI

/// Bottom tab bar — the iOS-native replacement for the web app's top nav.
/// Tab 1 is the portfolio hierarchy (Overview → market → stock detail), tab 2
/// is the AI assistant.
struct RootView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var portfolioPath = NavigationPath()

    var body: some View {
        TabView {
            NavigationStack(path: $portfolioPath) {
                OverviewView()
            }
            .tabItem {
                Label("Portfolio", systemImage: "chart.pie.fill")
            }

            NavigationStack {
                AssistantView()
            }
            .tabItem {
                Label("Assistant", systemImage: "sparkles")
            }
        }
        .task {
            await store.loadMarkets()
            await store.loadAll()
            // UI-test deep link: launch with env UITEST_MARKET=TW|US to jump
            // straight into a portfolio (used for automated screenshots).
            if let m = ProcessInfo.processInfo.environment["UITEST_MARKET"],
               let market = MarketCode(rawValue: m), portfolioPath.isEmpty {
                portfolioPath.append(market)
            }
        }
    }
}
