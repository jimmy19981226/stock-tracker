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
    @Published var indices: [IndexQuote] = []

    @Published var loading = true
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    /// Everything needed to repaint the UI on next launch without the network.
    private struct Snapshot: Codable {
        var trades: [Trade]
        var dividends: [Dividend]
        var holdings: [Holding]
        var summaries: [CurrencySummary]
        var earnings: [String: [EarningsPoint]]
        var names: [String: String]
        var markets: [MarketConfig]
        var indices: [IndexQuote]?  // optional: pre-index snapshots still decode
        var lastUpdated: Date?
    }
    private static let snapshotKey = "portfolio-snapshot"
    // Monotonic refresh generation. A manual loadAll() and the background poll's
    // refreshQuietly() can be in flight at once; whichever STARTED last owns the
    // final state. An older fetch that resolves late checks this and drops its
    // writes instead of clobbering newer data.
    private var refreshSeq = 0

    init() {
        // Hydrate from the last saved snapshot so launch paints instantly with
        // slightly stale data instead of a spinner; loadAll() then replaces it
        // quietly (and slowly, if the Render backend is cold-starting).
        if let s = DiskCache.load(Snapshot.self, name: Self.snapshotKey) {
            trades = s.trades
            dividends = s.dividends
            holdings = s.holdings
            summaries = s.summaries
            earnings = s.earnings
            names = s.names
            markets = s.markets
            indices = s.indices ?? []
            lastUpdated = s.lastUpdated
            loading = false
        }
    }

    private func saveSnapshot() {
        DiskCache.save(
            Snapshot(trades: trades, dividends: dividends, holdings: holdings,
                     summaries: summaries, earnings: earnings, names: names,
                     markets: markets, indices: indices, lastUpdated: lastUpdated),
            as: Self.snapshotKey
        )
    }

    // MARK: - Loading

    func loadAll() async {
        refreshSeq += 1
        let seq = refreshSeq
        do {
            async let t = api.listTrades()
            async let d = api.listDividends()
            async let h = api.getHoldings()
            async let s = api.getSummary()
            async let e = api.getEarningsHistory()
            async let n = api.getNames()
            // Indices are decoration — fetched tolerantly so a missing/failing
            // /api/indices (e.g. an older backend) can never block core data.
            async let i = fetchIndicesOrKeep()
            let (tt, dd, hh, ss, ee, nn) = try await (t, d, h, s, e, n)
            let ii = await i
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            guard seq == refreshSeq else { return }  // superseded by a newer refresh
            trades = tt
            dividends = dd
            holdings = hh2
            summaries = ss2
            earnings = ee
            names = nn
            indices = ii
            errorMessage = nil
            lastUpdated = Date()
            saveSnapshot()
        } catch {
            guard seq == refreshSeq else { return }
            // Only surface the failure when there's nothing to show. Over good
            // (cached/stale) data, a transient refresh hiccup shouldn't flash
            // a red banner — the poll loop heals it on the next tick.
            if summaries.isEmpty {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
        loading = false
    }

    func loadMarkets() async {
        if let m = try? await api.getMarkets(), m != markets {
            markets = m
            saveSnapshot()
        }
    }

    /// Pull fresh data but keep the current UI (no full-screen spinner).
    func refreshQuietly() async {
        refreshSeq += 1
        let seq = refreshSeq
        do {
            async let h = api.getHoldings()
            async let s = api.getSummary()
            async let i = fetchIndicesOrKeep()
            let (hh, ss) = try await (h, s)
            let ii = await i
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            guard seq == refreshSeq else { return }  // superseded by a newer refresh
            holdings = hh2
            summaries = ss2
            indices = ii
            lastUpdated = Date()
            errorMessage = nil
            saveSnapshot()
        } catch {
            // Keep showing stale data; surface only hard load failures.
        }
    }

    /// Indices, or the current ones if the fetch fails. Never throws — the
    /// strip must not take the dashboard down with it.
    private func fetchIndicesOrKeep() async -> [IndexQuote] {
        (try? await api.getIndices()) ?? indices
    }

    /// Re-pull just the index strip (after the user edits their index list).
    func refreshIndices() async {
        if let ii = try? await api.getIndices() {
            indices = ii
            saveSnapshot()
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
        startStreaming()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Real-time US prices (SSE fan-out of Yahoo's WebSocket)

    /// Hold an SSE connection to /api/quotes/stream while a portfolio is on
    /// screen. Each tick patches the matching US holding / index in place, so
    /// US prices move the moment a trade prints instead of on the 5s poll.
    /// Ticks only flow during regular US hours; outside them the connection
    /// just idles on keep-alives. Reconnects with a short backoff.
    private func startStreaming() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await APIClient.shared.streamQuotes { tick in
                        self?.apply(tick: tick)
                    }
                } catch {
                    // Fall through to the retry sleep. Covers an older backend
                    // without /api/quotes/stream (404) — retry slowly, the 5s
                    // poll still keeps prices moving.
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// Patch one live tick into the published state, recomputing the touched
    /// US holding and the USD summary with the backend's formulas (US exit
    /// cost is 0 — see services/portfolio.py).
    private func apply(tick: QuoteTick) {
        // Index tick (^GSPC, ^TWII, …) → update the strip.
        if tick.ticker.hasPrefix("^") {
            if let idx = indices.firstIndex(where: { $0.symbol == tick.ticker }) {
                indices[idx].price = tick.price
                indices[idx].change = tick.change
                indices[idx].changePct = tick.changePct
            }
            return
        }

        guard let i = holdings.firstIndex(where: {
            $0.market == .US && $0.ticker.caseInsensitiveCompare(tick.ticker) == .orderedSame
        }) else { return }

        var h = holdings[i]
        let mv = tick.price * h.shares
        let unrealized = mv - h.costBasis
        h.currentPrice = tick.price
        h.marketValue = mv
        h.exitCost = 0
        h.unrealizedPl = unrealized
        h.unrealizedPlPct = h.costBasis > 0 ? unrealized / h.costBasis * 100 : nil
        if let pc = tick.prevClose, pc > 0 {
            h.todayChange = (tick.price - pc) * h.shares
            h.todayChangePct = (tick.price - pc) / pc * 100
        }
        holdings[i] = h

        if let s = summaries.firstIndex(where: { $0.currency == "USD" }) {
            let usd = holdings.filter { $0.currency == "USD" }
            let totalValue = usd.reduce(0.0) { $0 + ($1.marketValue ?? 0) }
            let totalPl = usd.reduce(0.0) { $0 + ($1.unrealizedPl ?? 0) }
            let todayPl = usd.reduce(0.0) { $0 + ($1.todayChange ?? 0) }
            summaries[s].totalValue = totalValue
            summaries[s].totalPl = totalPl
            summaries[s].totalPlPct = summaries[s].totalCost > 0
                ? totalPl / summaries[s].totalCost * 100 : 0
            summaries[s].todayPl = todayPl
            let prevValue = totalValue - todayPl
            summaries[s].todayPlPct = prevValue > 0 ? todayPl / prevValue * 100 : 0
        }
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
