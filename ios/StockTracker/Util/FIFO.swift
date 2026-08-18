import Foundation

/// FIFO lot matching, mirroring the backend's `_apply_trade`.
///
/// The backend reports realized P/L per *market*, not per trade, but a trade
/// row has to be able to say what that particular sell booked. Rather than add
/// an endpoint, the same walk is done here over the trades the app already
/// holds: a sell consumes the oldest open lots first, buy fees go into the
/// cost basis and sell fees come off the proceeds.
///
/// Keep this in step with services/portfolio.py — if the two ever disagree, the
/// row and the dashboard disagree, which is worse than showing nothing.
enum FIFO {
    /// Realized P/L booked by each *sell*, keyed by trade id. Buys are absent.
    static func realized(_ trades: [Trade]) -> [Int: Double] {
        var lots: [String: [(shares: Double, costPerShare: Double)]] = [:]
        var out: [Int: Double] = [:]

        for t in trades.sorted(by: { ($0.tradeDate, $0.id) < ($1.tradeDate, $1.id) }) {
            if t.type == .buy {
                guard t.shares > 0 else { continue }
                lots[t.ticker, default: []]
                    .append((t.shares, (t.shares * t.price + t.fee) / t.shares))
                continue
            }
            var remaining = t.shares
            var booked = -t.fee
            var open = lots[t.ticker] ?? []
            while remaining > 1e-9, !open.isEmpty {
                let take = min(remaining, open[0].shares)
                booked += take * (t.price - open[0].costPerShare)
                open[0].shares -= take
                remaining -= take
                if open[0].shares <= 1e-9 { open.removeFirst() }
            }
            lots[t.ticker] = open
            // An over-sell has no cost basis left to match against; the
            // proceeds are all that can be booked.
            if remaining > 1e-9 { booked += remaining * t.price }
            out[t.id] = booked
        }
        return out
    }
}
