import Foundation

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
}
