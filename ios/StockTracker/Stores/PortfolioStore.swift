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
            trades = tt
            dividends = dd
            holdings = hh
            summaries = ss
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
            holdings = hh
            summaries = ss
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
}
