import SwiftUI
import UIKit

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

/// The app shell: five persistent destinations and the toast layer.
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
    @ObservedObject private var reports = ReportsStore.shared

    var body: some View {
        GeometryReader { geometry in
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
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // Keep every destination reachable while typing. SwiftUI moves this
        // safe-area inset above the keyboard and the active screen/composer
        // uses the remaining space. A tab tap dismisses editing first.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selection: $tab)
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.xs)
        }
        .overlay(alignment: .bottom) {
            if let message = toasts.message {
                ToastView(text: message).padding(.bottom, 8)
            }
        }
        // The report viewer is presented here, not from the screen that asked
        // for it. Two screens open reports — Settings and the assistant's card
        // — and SwiftUI honours only one presentation modifier per view, so
        // Settings' own sheet and full-screen cover had already used up its
        // budget and this one silently never appeared.
        .fullScreenCover(item: $reports.viewing) { ReportViewerSheet(job: $0) }
        .task { await bootstrap() }
        .onDisappear { store.stopPolling() }
    }

    /// Overview → market dashboard → stock detail; preserve the selected market
    /// and ticker when switching tabs. Screens provide their own back controls.
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
            OverviewView(onOpenMarket: { market in
                withAnimation(.easeOut(duration: 0.22)) { overviewMarket = market }
            }, onAskAssistant: { tab = .assistant }, onOpenSettings: { tab = .settings })
        }
    }

    private func bootstrap() async {
        async let markets: Void = store.loadMarkets()
        async let all: Void = store.loadAll()
        _ = await (markets, all)
        guard !Task.isCancelled else { return }
        store.startPolling()

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let on = tab == selection
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: on && tab.hasFilledTwin ? tab.symbol + ".fill" : tab.symbol)
                            .font(.system(size: 22, weight: on ? .semibold : .regular))
                            .frame(height: 25)
                        Text(tab.label)
                            .font(on ? Theme.Typo.tabOn : Theme.Typo.tab)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(on ? Theme.accentSelected : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                .fill(Theme.accentTint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityIdentifier("tab.\(tab.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(Theme.line.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: Theme.shadow, radius: 14, x: 0, y: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
