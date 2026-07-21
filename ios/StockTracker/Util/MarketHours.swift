import Foundation

/// A market's trading status. `.preMarket`/`.afterHours` only ever come back
/// for US — real NYSE/Nasdaq extended-hours sessions. TW cash equities have
/// no evening session (its 14:00–14:30 after-hours window is a same-day
/// fixed-price cross, not an extended trading session), so TW only ever
/// reports `.open`/`.closed`.
enum MarketSession {
    case preMarket
    case open
    case afterHours
    case closed

    var label: String {
        switch self {
        case .preMarket: return "Pre-Market"
        case .open: return "Market open"
        case .afterHours: return "After Hours"
        case .closed: return "Market closed"
        }
    }

    /// Whether the dot should read as "something's moving" (green for the
    /// regular session, amber for the extended ones) vs flat gray.
    var isActive: Bool { self != .closed }
}

/// Is a market currently in session? Mirrors format.ts isMarketOpen — weekday +
/// open/close minutes evaluated in the market's own timezone, minus holidays.
enum MarketHours {
    private static func localParts(_ timezone: String, _ now: Date) -> (weekday: Int, date: String, minutes: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timezone) ?? .current
        let c = cal.dateComponents([.weekday, .year, .month, .day, .hour, .minute], from: now)
        let dateStr = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (c.weekday ?? 1, dateStr, minutes)  // weekday: 1 = Sunday, 7 = Saturday
    }

    private static func isTradingDay(_ m: MarketConfig, weekday: Int, date: String) -> Bool {
        weekday != 1 && weekday != 7 && !m.holidays.contains(date)
    }

    static func isOpen(_ market: MarketConfig?, now: Date = Date()) -> Bool {
        guard let market else { return false }
        let p = localParts(market.timezone, now)
        guard isTradingDay(market, weekday: p.weekday, date: p.date) else { return false }
        return p.minutes >= market.openMinute && p.minutes < market.closeMinute
    }

    // Standard NYSE/Nasdaq extended-hours windows, in ET minutes-from-midnight.
    private static let usPreMarketOpenMinute = 4 * 60        // 4:00 AM ET
    private static let usAfterHoursCloseMinute = 20 * 60     // 8:00 PM ET

    /// Richer status than `isOpen` — adds pre-market/after-hours for US.
    static func session(for market: MarketConfig?, marketCode: MarketCode,
                        now: Date = Date()) -> MarketSession {
        guard let market else { return .closed }
        let p = localParts(market.timezone, now)
        guard isTradingDay(market, weekday: p.weekday, date: p.date) else { return .closed }
        if p.minutes >= market.openMinute && p.minutes < market.closeMinute { return .open }
        guard marketCode == .US else { return .closed }
        if p.minutes >= usPreMarketOpenMinute && p.minutes < market.openMinute { return .preMarket }
        if p.minutes >= market.closeMinute && p.minutes < usAfterHoursCloseMinute { return .afterHours }
        return .closed
    }
}
