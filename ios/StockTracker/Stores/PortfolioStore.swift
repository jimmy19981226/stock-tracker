import Foundation
import SwiftUI

/// Advance from scheduled deadlines, so request latency cannot stretch the
/// five-second cadence. Missed deadlines are skipped without catch-up bursts.
struct QuoteRefreshSchedule {
    static let interval: Duration = .seconds(5)
    private(set) var deadline: ContinuousClock.Instant

    init(now: ContinuousClock.Instant) {
        deadline = now.advanced(by: Self.interval)
    }

    mutating func advance(past now: ContinuousClock.Instant) {
        repeat { deadline = deadline.advanced(by: Self.interval) }
        while deadline <= now
    }
}

/// Keep the latest tick per symbol without publishing every incoming event.
/// Receipt times also protect newer ticks from an older in-flight REST fetch.
struct LiveQuoteBuffer {
    struct Entry {
        let quote: QuoteTick
        let receivedAt: ContinuousClock.Instant
    }
    private(set) var latest: [String: Entry] = [:]

    mutating func insert(_ quote: QuoteTick, at now: ContinuousClock.Instant) {
        guard quote.price.isFinite, quote.price > 0 else { return }
        let symbol = quote.ticker.uppercased()
        if let prior = latest[symbol]?.quote.timestamp, let incoming = quote.timestamp,
           incoming < prior { return }
        latest[symbol] = Entry(quote: quote, receivedAt: now)
    }

    mutating func discard(before now: ContinuousClock.Instant) {
        latest = latest.filter { $0.value.receivedAt >= now }
    }
}

/// App-wide data store. Loads everything the dashboard/trades/dividends screens
/// need in one shot. A single clock publishes quotes every five seconds while
/// either market is open, or every sixty seconds when both are closed.
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
    @Published private(set) var overview: PortfolioOverview? =
        DiskCache.load(PortfolioOverview.self, name: "overview")

    @Published var loading = true
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var liveQuotes = LiveQuoteBuffer()
    private var lastPublication: ContinuousClock.Instant?

    private struct QuoteSnapshot {
        let holdings: [Holding]
        let summaries: [CurrencySummary]
        let indices: [IndexQuote]
        let overview: PortfolioOverview?
        let startedAt: ContinuousClock.Instant
    }
    private var pendingSnapshot: QuoteSnapshot?
    private var fullLoadsInFlight = 0

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
        var overview: PortfolioOverview?
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
            overview = s.overview ?? overview
            loading = false
        }
    }

    private func saveSnapshot() {
        DiskCache.save(
            Snapshot(trades: trades, dividends: dividends, holdings: holdings,
                     summaries: summaries, earnings: earnings, names: names,
                     markets: markets, indices: indices, lastUpdated: lastUpdated,
                     overview: overview),
            as: Self.snapshotKey
        )
    }

    // MARK: - Loading

    func loadAll() async {
        fullLoadsInFlight += 1
        defer { fullLoadsInFlight -= 1 }
        refreshSeq += 1
        let seq = refreshSeq
        let startedAt = ContinuousClock.now
        pendingSnapshot = nil
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
            async let o = fetchOverviewOrKeep()
            let (tt, dd, hh, ss, ee, nn) = try await (t, d, h, s, e, n)
            let ii = await i
            let oo = await o
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            guard seq == refreshSeq else { return }  // superseded by a newer refresh
            trades = tt
            dividends = dd
            earnings = ee
            names = nn
            publish(snapshot: QuoteSnapshot(holdings: hh2, summaries: ss2,
                                             indices: ii, overview: oo, startedAt: startedAt))
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

    // MARK: - Local upserts (optimistic add/edit)

    /// Merge a just-saved trade into the published list immediately, in the
    /// backend's list order, so the form sheet can dismiss without waiting on
    /// the full refresh; a background loadAll() reconciles holdings/summary.
    func upsert(_ trade: Trade) {
        if let i = trades.firstIndex(where: { $0.id == trade.id }) {
            trades[i] = trade
        } else {
            trades.append(trade)
        }
        trades.sort { ($0.tradeDate, $0.id) > ($1.tradeDate, $1.id) }
        saveSnapshot()
    }

    /// Dividend twin of `upsert(_ trade:)`.
    func upsert(_ dividend: Dividend) {
        if let i = dividends.firstIndex(where: { $0.id == dividend.id }) {
            dividends[i] = dividend
        } else {
            dividends.append(dividend)
        }
        dividends.sort { ($0.payDate, $0.id) > ($1.payDate, $1.id) }
        saveSnapshot()
    }

    /// Fetch off the display clock; results wait for its next boundary.
    private func refreshQuietly() async {
        refreshSeq += 1
        let seq = refreshSeq
        let startedAt = ContinuousClock.now
        do {
            async let h = api.getHoldings()
            async let s = api.getSummary()
            async let i = fetchIndicesOrKeep()
            async let o = fetchOverviewOrKeep()
            let (hh, ss) = try await (h, s)
            let ii = await i
            let oo = await o
            let (hh2, ss2) = await Self.applyingMIS(holdings: hh, summaries: ss,
                                                    twOpen: isOpen(.TW))
            guard seq == refreshSeq else { return }  // superseded by a newer refresh
            pendingSnapshot = QuoteSnapshot(holdings: hh2, summaries: ss2,
                                            indices: ii, overview: oo, startedAt: startedAt)
        } catch {
            // Keep showing stale data; surface only hard load failures.
        }
    }

    /// Indices, or the current ones if the fetch fails. Never throws — the
    /// strip must not take the dashboard down with it.
    private func fetchIndicesOrKeep() async -> [IndexQuote] {
        (try? await api.getIndices()) ?? indices
    }

    private func fetchOverviewOrKeep() async -> PortfolioOverview? {
        (try? await api.getOverview()) ?? overview
    }

    /// Re-pull just the index strip (after the user edits their index list).
    func refreshIndices() async {
        if let ii = try? await api.getIndices() {
            indices = ii
            saveSnapshot()
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var schedule = QuoteRefreshSchedule(now: clock.now)
            var nextClosedPublication = clock.now.advanced(by: .seconds(60))
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: schedule.deadline, tolerance: .milliseconds(50))
                } catch { break }
                if Task.isCancelled { break }
                let now = clock.now
                schedule.advance(past: now)
                let open = self.markets.isEmpty || MarketCode.allCases.contains { self.isOpen($0) }
                guard open || now >= nextClosedPublication else { continue }
                nextClosedPublication = schedule.deadline.advanced(by: .seconds(55))
                let snapshot = self.pendingSnapshot
                self.pendingSnapshot = nil
                self.publish(snapshot: snapshot)
                self.beginRefresh()
            }
        }
        startStreaming()
        beginRefresh()
    }

    private func beginRefresh() {
        guard refreshTask == nil, fullLoadsInFlight == 0 else { return }
        let id = UUID()
        refreshTaskID = id
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshQuietly()
            if self.refreshTaskID == id {
                self.refreshTask = nil
                self.refreshTaskID = nil
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        streamTask?.cancel()
        streamTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        refreshSeq += 1
        pendingSnapshot = nil
        liveQuotes = LiveQuoteBuffer()
    }

    // MARK: - Real-time US prices (SSE fan-out of Yahoo's WebSocket)

    /// Hold an SSE connection to /api/quotes/stream while a portfolio is on
    /// screen. Ticks are buffered until the next display boundary, so bursts
    /// of trades cannot repeatedly restart the number animations.
    /// Ticks only flow during regular US hours; outside them the connection
    /// just idles on keep-alives. Reconnects with a short backoff.
    private func startStreaming() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await APIClient.shared.streamQuotes { tick in
                        self?.liveQuotes.insert(tick, at: ContinuousClock.now)
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

    /// Publish a whole quote batch together. The overview uses these same
    /// summaries, rather than another request with a different price snapshot.
    private func publish(snapshot: QuoteSnapshot?) {
        let now = ContinuousClock.now
        if let snapshot { liveQuotes.discard(before: snapshot.startedAt) }
        let baseIndices = snapshot?.indices ?? indices
        let quotes = liveQuotes.latest.values.filter { entry in
            let market = baseIndices.first { $0.symbol == entry.quote.ticker }?.market ?? .US
            guard markets.isEmpty || isOpen(market) else { return false }
            if let date = entry.quote.timestamp, Date().timeIntervalSince(date) > 6.5 * 3600 {
                return false
            }
            return true
        }
        let hasNewQuotes = quotes.contains { entry in
            lastPublication.map { entry.receivedAt > $0 } ?? true
        }
        guard snapshot != nil || hasNewQuotes else { return }
        let values = Self.applyingLiveQuotes(
            holdings: snapshot?.holdings ?? holdings,
            summaries: snapshot?.summaries ?? summaries,
            indices: baseIndices, quotes: quotes.map(\.quote))
        holdings = values.holdings
        summaries = values.summaries
        indices = values.indices
        overview = Self.combinedOverview(summaries: summaries, source: snapshot?.overview ?? overview)
        lastPublication = now
        lastUpdated = Date()
        errorMessage = nil
        saveSnapshot()
        if let overview { DiskCache.save(overview, as: "overview") }
    }

    /// Apply one coalesced quote per symbol and recalculate the USD summary
    /// once, keeping each price, amount, and percentage in the same batch.
    static func applyingLiveQuotes(holdings: [Holding], summaries: [CurrencySummary],
                                   indices: [IndexQuote], quotes: [QuoteTick])
        -> (holdings: [Holding], summaries: [CurrencySummary], indices: [IndexQuote]) {
        var holdings = holdings
        var summaries = summaries
        var indices = indices
        var changedHolding = false
        for tick in quotes {
            // Index tick (^GSPC, ^TWII, …) → update the strip.
            if tick.ticker.hasPrefix("^") {
                if let idx = indices.firstIndex(where: { $0.symbol == tick.ticker }) {
                    indices[idx].price = tick.price
                    indices[idx].change = tick.change
                    indices[idx].changePct = tick.changePct
                }
                continue
            }

            guard let i = holdings.firstIndex(where: {
                $0.market == .US && $0.ticker.caseInsensitiveCompare(tick.ticker) == .orderedSame
            }) else { continue }

            var h = holdings[i]
            let mv = tick.price * h.shares
            let unrealized = mv - h.costBasis
            let previousClose = tick.prevClose ?? tick.change.map { tick.price - $0 }
                ?? h.todayChangePct.flatMap { pct in
                    h.currentPrice.flatMap { price in pct > -100 ? price / (1 + pct / 100) : nil }
                }
            h.currentPrice = tick.price
            h.marketValue = mv
            h.exitCost = 0
            h.unrealizedPl = unrealized
            h.unrealizedPlPct = h.costBasis > 0 ? unrealized / h.costBasis * 100 : nil
            if let pc = previousClose, pc.isFinite, pc > 0 {
                h.todayChange = (tick.price - pc) * h.shares
                h.todayChangePct = (tick.price - pc) / pc * 100
            } else {
                h.todayChange = nil
                h.todayChangePct = nil
            }
            holdings[i] = h
            changedHolding = true
        }

        if changedHolding, let s = summaries.firstIndex(where: { $0.currency == "USD" }) {
            let usd = holdings.filter { $0.currency == "USD" }
            let totalValue = usd.reduce(0.0) { $0 + ($1.marketValue ?? 0) }
            let totalPl = usd.reduce(0.0) { $0 + ($1.unrealizedPl ?? 0) }
            let todayPl = usd.reduce(0.0) { $0 + ($1.todayChange ?? 0) }
            summaries[s].totalValue = totalValue
            summaries[s].totalPl = totalPl
            summaries[s].totalPlPct = summaries[s].totalCost > 0
                ? totalPl / summaries[s].totalCost * 100 : nil
            summaries[s].todayPl = todayPl
            let prevValue = totalValue - todayPl
            summaries[s].todayPlPct = prevValue > 0 ? todayPl / prevValue * 100 : nil
        }
        return (holdings, summaries, indices)
    }

    static func combinedOverview(summaries: [CurrencySummary], source: PortfolioOverview?)
        -> PortfolioOverview? {
        guard let source else { return nil }
        let tw = summaries.first { $0.currency == "TWD" }
        let us = summaries.first { $0.currency == "USD" }
        var twd: Double?, usd: Double?
        if (tw == nil || tw?.totalValue != nil), (us == nil || us?.totalValue != nil) {
            let twValue = tw?.totalValue ?? 0
            let usValue = us?.totalValue ?? 0
            if let fx = source.fx.usdTwd, fx.isFinite, fx > 0 {
                twd = twValue + usValue * fx
                usd = twValue / fx + usValue
            } else if usValue == 0 {
                twd = twValue
            }
        }
        return PortfolioOverview(tw: tw, us: us, fx: source.fx,
                                 combined: .init(twd: twd, usd: usd))
    }

    func config(for market: MarketCode) -> MarketConfig? {
        markets.first { $0.code == market }
    }

    func isOpen(_ market: MarketCode) -> Bool {
        MarketHours.isOpen(config(for: market))
    }

    /// Richer than `isOpen` — surfaces US pre-market/after-hours separately.
    func session(for market: MarketCode) -> MarketSession {
        MarketHours.session(for: config(for: market), marketCode: market)
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
