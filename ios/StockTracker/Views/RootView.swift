import SwiftUI

/// The five destinations of the app.
enum AppTab: String, CaseIterable, Identifiable {
    case overview, trades, assistant, dividends, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .trades: return "Trades"
        case .assistant: return "Assistant"
        case .dividends: return "Dividends"
        case .settings: return "Settings"
        }
    }

    /// SF Symbols standing in for the drawn glyphs in the design. Where a
    /// filled twin exists it carries the selected state; where it doesn't
    /// (`arrow.left.arrow.right`, `slider.horizontal.3`) the weight does.
    var symbol: String {
        switch self {
        case .overview: return "house"
        case .trades: return "arrow.left.arrow.right"
        case .assistant: return "sparkles"
        case .dividends: return "dollarsign.circle"
        case .settings: return "slider.horizontal.3"
        }
    }
    var hasFilledTwin: Bool {
        switch self {
        case .overview, .dividends: return true
        case .trades, .assistant, .settings: return false
        }
    }
}

/// The app shell: five tabs, the pinned market-index strip above the tab bar on
/// Overview, and the toast layer.
///
/// The tab bar is drawn rather than `TabView`'s, because the design specifies a
/// solid glyph plus a 600-weight label when selected and a 1.7pt outline with a
/// regular label when not — a distinction `.tabItem` cannot express.
struct RootView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter
    @State private var tab: AppTab = .overview
    @State private var overviewMarket: MarketCode?
    @State private var overviewTicker: String?
    // App-scoped so an in-flight AI reply keeps streaming while the user
    // browses other tabs, and the transcript is there on return.
    @StateObject private var assistantVM = AssistantViewModel()

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()

            Group {
                switch tab {
                case .overview: overviewStack
                case .trades: TradesView()
                case .assistant: AssistantView(vm: assistantVM)
                case .dividends: DividendsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if tab == .overview && overviewTicker == nil {
                    IndexBarView(market: overviewMarket)
                }
                AppTabBar(selection: $tab)
            }
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Theme.chrome
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = toasts.message {
                ToastView(text: message).padding(.bottom, 8)
            }
        }
        .task { await bootstrap() }
    }

    /// Overview → market dashboard → stock detail. Modelled as state rather
    /// than a `NavigationStack` because the index strip and the tab bar have to
    /// stay pinned across the whole hierarchy, and the screens carry their own
    /// back rows instead of a system nav bar.
    @ViewBuilder
    private var overviewStack: some View {
        if let ticker = overviewTicker, let market = overviewMarket {
            StockDetailView(ticker: ticker, market: market) { overviewTicker = nil }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let market = overviewMarket {
            DashboardView(market: market,
                          onBack: { overviewMarket = nil },
                          onOpen: { overviewTicker = $0 })
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            OverviewView { market in
                withAnimation(.easeOut(duration: 0.22)) { overviewMarket = market }
            }
        }
    }

    private func bootstrap() async {
        async let markets: Void = store.loadMarkets()
        async let all: Void = store.loadAll()
        _ = await (markets, all)
        store.startPolling(market: .TW)

        let env = ProcessInfo.processInfo.environment
        if let raw = env["UITEST_TAB"], let t = AppTab(rawValue: raw) { tab = t }
        if let m = env["UITEST_MARKET"], let market = MarketCode(rawValue: m) {
            overviewMarket = market
            if let t = env["UITEST_TICKER"] { overviewTicker = t }
        }
    }
}

/// The drawn tab bar.
private struct AppTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let on = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: on && tab.hasFilledTwin ? tab.symbol + ".fill" : tab.symbol)
                            .font(.system(size: 21, weight: on ? .semibold : .regular))
                            .frame(height: 25)
                        Text(tab.label)
                            .font(on ? Theme.Typo.tabOn : Theme.Typo.tab)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(on ? Theme.accentSelected : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 5)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
