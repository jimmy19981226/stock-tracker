import SwiftUI

/// Bottom tab bar — the iOS-native replacement for the web app's top nav.
/// Tab 1 is the portfolio hierarchy (Overview → market → stock detail), tab 2
/// is the AI assistant.
struct RootView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var portfolioPath = NavigationPath()
    @State private var selectedTab = 0
    // App-scoped so an in-flight AI reply keeps streaming while the user
    // browses other tabs/pages, and the transcript is there on return.
    @StateObject private var assistantVM = AssistantViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $portfolioPath) {
                OverviewView()
            }
            .tabItem {
                Label("Portfolio", systemImage: "chart.pie.fill")
            }
            .tag(0)

            NavigationStack {
                AssistantView(vm: assistantVM)
            }
            .tabItem {
                Label("Assistant", systemImage: "sparkles")
            }
            .tag(1)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["UITEST_TAB"] == "assistant" {
                selectedTab = 1
            }
        }
        .task {
            // Concurrent, not sequential — one round trip of latency, not two.
            // (Market hours for the MIS overlay come from the cached snapshot
            // on warm launches, so loadAll doesn't need loadMarkets first.)
            async let markets: Void = store.loadMarkets()
            async let all: Void = store.loadAll()
            _ = await (markets, all)
            // UI-test deep link: launch with env UITEST_MARKET=TW|US to jump
            // straight into a portfolio (used for automated screenshots).
            if let m = ProcessInfo.processInfo.environment["UITEST_MARKET"],
               let market = MarketCode(rawValue: m), portfolioPath.isEmpty {
                portfolioPath.append(market)
            }
        }
    }
}
