import Foundation
import SwiftUI

/// App-wide data store. Loads everything the dashboard/trades/dividends screens
/// need in one shot and exposes per-market filtered slices. Polls while a
/// portfolio is on screen (fast while that market is open, slow otherwise) —
/// the same cadence strategy the web app uses.
@MainActor
final class PortfolioStore: ObservableObject {
    @Published var trades: [Trade] = []
    @Published var dividends: [Dividend] = []
    @Published var holdings: [Holding] = []
    @Published var summaries: [CurrencySummary] = []
    @Published var earnings: [String: [EarningsPoint]] = [:]
    @Published var names: [String: String] = [:]
    @Published var markets: [MarketConfig] = []

    @Published var loading = true
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?

    // MARK: - Loading

    func loadAll() async {
        do {
            async let t = api.listTrades()
            async let d = api.listDividends()
            async let h = api.getHoldings()
            async let s = api.getSummary()
            async let e = api.getEarningsHistory()
            async let n = api.getNames()
            let (tt, dd, hh, ss, ee, nn) = try await (t, d, h, s, e, n)
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            trades = tt
            dividends = dd
            holdings = hh2
            summaries = ss2
            earnings = ee
            names = nn
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    func loadMarkets() async {
        if let m = try? await api.getMarkets() { markets = m }
    }

    /// Pull fresh data but keep the current UI (no full-screen spinner).
    func refreshQuietly() async {
        do {
            async let h = api.getHoldings()
            async let s = api.getSummary()
            let (hh, ss) = try await (h, s)
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            holdings = hh2
            summaries = ss2
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            // Keep showing stale data; surface only hard load failures.
        }
    }

    // MARK: - Polling

    func startPolling(market: MarketCode) {
        stopPolling()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let cfg = await self.config(for: market)
                let open = MarketHours.isOpen(cfg)
                let delay: UInt64 = open ? 5 : 60
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refreshQuietly()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func config(for market: MarketCode) -> MarketConfig? {
        markets.first { $0.code == market }
    }

    func isOpen(_ market: MarketCode) -> Bool {
        MarketHours.isOpen(config(for: market))
    }

    // MARK: - Per-market slices

    func currency(for market: MarketCode) -> String { market.currencyCode }

    func holdings(for market: MarketCode) -> [Holding] {
        holdings.filter { $0.market == market }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
    }

    func summary(for market: MarketCode) -> CurrencySummary? {
        summaries.first { $0.currency == market.currencyCode }
    }

    func trades(for market: MarketCode) -> [Trade] {
        trades.filter { $0.market == market }
    }

    func dividends(for market: MarketCode) -> [Dividend] {
        dividends.filter { $0.market == market }
    }

    func earnings(for market: MarketCode) -> [EarningsPoint] {
        earnings[market.currencyCode] ?? []
    }

    func name(for ticker: String) -> String {
        names[ticker] ?? ticker
    }

    // MARK: - Device-side real-time TW prices

    /// Overlay real-time TWSE MIS quotes (fetched directly by this device) on
    /// the backend's TW rows, recomputing each holding's P&L and the TWD
    /// summary with the backend's exact formulas (services/portfolio.py).
    /// No-op while the TW market is closed (backend data is already final) or
    /// when MIS doesn't answer — so the app flips between real-time and
    /// delayed automatically on every refresh.
    private static func applyingMIS(
        holdings: [Holding], summaries: [CurrencySummary], twOpen: Bool
    ) async -> ([Holding], [CurrencySummary]) {
        guard twOpen else { return (holdings, summaries) }
        let twTickers = holdings.filter { $0.market == .TW }.map(\.ticker)
        guard !twTickers.isEmpty else { return (holdings, summaries) }
        let quotes = await MISQuotes.fetch(twTickers)
        guard !quotes.isEmpty else { return (holdings, summaries) }

        var hs = holdings
        for i in hs.indices where hs[i].market == .TW {
            guard let q = quotes[hs[i].ticker.uppercased()] else { continue }
            let mv = q.price * hs[i].shares
            let exit = estimateExitCost(ticker: hs[i].ticker, marketValue: mv)
            let unrealized = mv - hs[i].costBasis - exit
            hs[i].currentPrice = q.price
            hs[i].marketValue = mv
            hs[i].exitCost = exit
            hs[i].unrealizedPl = unrealized
            hs[i].unrealizedPlPct = hs[i].costBasis > 0
                ? unrealized / hs[i].costBasis * 100 : nil
            if let pc = q.previousClose, pc > 0 {
                hs[i].todayChange = (q.price - pc) * hs[i].shares
                hs[i].todayChangePct = (q.price - pc) / pc * 100
            }
        }

        var ss = summaries
        if let idx = ss.firstIndex(where: { $0.currency == "TWD" }) {
            let twd = hs.filter { $0.currency == "TWD" }
            let totalValue = twd.reduce(0.0) { $0 + ($1.marketValue ?? 0) }
            let totalPl = twd.reduce(0.0) { $0 + ($1.unrealizedPl ?? 0) }
            let todayPl = twd.reduce(0.0) { $0 + ($1.todayChange ?? 0) }
            ss[idx].totalValue = totalValue
            ss[idx].totalPl = totalPl
            ss[idx].totalPlPct = ss[idx].totalCost > 0
                ? totalPl / ss[idx].totalCost * 100 : 0
            ss[idx].todayPl = todayPl
            let prevValue = totalValue - todayPl
            ss[idx].todayPlPct = prevValue > 0 ? todayPl / prevValue * 100 : 0
        }
        return (hs, ss)
    }

    /// TW sell-side commission + securities transaction tax, floored to the
    /// dollar per component — mirrors estimate_exit_cost in the backend so
    /// unrealized P&L matches the broker's 損益試算.
    private static func estimateExitCost(ticker: String, marketValue: Double) -> Double {
        guard marketValue > 0 else { return 0 }
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        let taxRate: Double = t.hasPrefix("00") ? (t.hasSuffix("B") ? 0 : 0.001) : 0.003
        return (marketValue * 0.001425).rounded(.down) + (marketValue * taxRate).rounded(.down)
    }
}
