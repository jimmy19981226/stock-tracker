import Foundation
import SwiftUI

/// Formatting helpers mirroring the web app's format.js so figures read the
/// same across platforms (NT$ / US$, signed percentages, em-dash for nil).
///
/// Two conventions the design fixes and nothing may deviate from:
/// * a negative sign is a real minus, U+2212 — a hyphen is a different glyph,
///   half the width, and reads as a dash between two numbers;
/// * USD is written `US$`, not `$`, because every screen shows it next to NT$
///   and a bare `$` in that company is ambiguous.
enum Fmt {
    /// U+2212 MINUS SIGN.
    static let minus = "\u{2212}"

    static func symbol(_ currency: String) -> String {
        currency == "TWD" ? "NT$" : currency == "USD" ? "US$" : ""
    }

    static func money(_ value: Double?, currency: String, digits: Int = 2) -> String {
        guard let v = value, v.isFinite else { return "—" }
        let sign = v < 0 ? minus : ""
        return "\(sign)\(symbol(currency))\(number(abs(v), digits: digits))"
    }

    static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let v = value, v.isFinite else { return "—" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minusSign = minus
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "—"
    }

    /// Full share count: integers show no decimals, fractional shares keep them.
    static func shares(_ value: Double) -> String {
        if value == value.rounded() { return number(value, digits: 0) }
        return number(value, digits: 4)
    }

    /// A signed percentage. Daily moves carry 2 dp, returns 1 dp — the design
    /// distinguishes them deliberately, so pass `digits` rather than rounding
    /// a return to look like a tick.
    static func pct(_ value: Double?, digits: Int = 2) -> String {
        guard let v = value, v.isFinite else { return "—" }
        let sign = v > 0 ? "+" : v < 0 ? minus : ""
        return "\(sign)\(String(format: "%.\(digits)f", Swift.abs(v)))%"
    }

    static func signedMoney(_ value: Double?, currency: String, digits: Int = 2) -> String {
        guard let v = value, v.isFinite else { return "—" }
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(money(v, currency: currency, digits: digits))"
    }

    // MARK: - Amounts vs prices
    //
    // Amounts use whole NT dollars and US dollars with cents. Quoted prices
    // retain two decimals. The size of a value never changes its precision,
    // and financial figures are always shown in full with grouping separators.

    /// Digits an *amount* should carry in this currency.
    private static func amountDigits(currency: String) -> Int {
        currency == "TWD" ? 0 : 2
    }

    /// A money amount — totals, P&L, dividends, cost basis.
    static func amount(_ value: Double?, currency: String) -> String {
        money(value, currency: currency, digits: amountDigits(currency: currency))
    }

    /// A money amount with an explicit `+` when positive.
    static func signedAmount(_ value: Double?, currency: String) -> String {
        signedMoney(value, currency: currency, digits: amountDigits(currency: currency))
    }

    /// A quoted price — keeps the precision the market trades it at.
    static func price(_ value: Double?, currency: String) -> String {
        money(value, currency: currency, digits: 2)
    }

    /// "Mar 4, 2025" from an ISO yyyy-MM-dd (or full timestamp) string.
    static func prettyDate(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let datePart = String(iso.prefix(10))
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = inFmt.date(from: datePart) else { return datePart }
        let out = DateFormatter()
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }

    /// Anchor for a time-axis label so edge labels tuck inward: a tick at the
    /// plot's right edge centers its label under itself, clipping half of it
    /// ("Jul…" cut off). First label grows rightward, last leftward.
    static func axisAnchor(_ index: Int, of count: Int) -> UnitPoint {
        if count > 1 && index == count - 1 { return .topTrailing }
        return index == 0 ? .topLeading : .top
    }

    /// Evenly spaced tick dates across the span — first at the start, last at
    /// the end — so labels fill the axis edge-to-edge instead of clumping
    /// wherever calendar-week boundaries happen to land (which left a bare
    /// stretch on one side and a cramped label on the other).
    static func axisDates(from first: Date, to last: Date, count: Int = 4) -> [Date] {
        guard count > 1, last > first else { return [first] }
        let step = last.timeIntervalSince(first) / Double(count - 1)
        return (0..<count).map { first.addingTimeInterval(Double($0) * step) }
    }

    /// Chart time-axis label format matched to the visible span: "Jun 5" for
    /// weeks–months, "Jun" for about a year, "2025" beyond that. A fixed
    /// month-only format repeats the same label on short ranges and drops the
    /// year on long ones.
    static func axisFormat(from first: Date, to last: Date,
                           tickCount: Int = 4) -> Date.FormatStyle {
        let days = last.timeIntervalSince(first) / 86_400
        if days <= 120 { return .dateTime.month(.abbreviated).day() }
        // Gap between two adjacent ticks — the resolution the labels have to
        // distinguish. A format coarser than this repeats itself.
        let stepDays = days / Double(Swift.max(tickCount - 1, 1))
        if days <= 550 {
            // Month-only labels turn ambiguous once the span straddles New
            // Year (e.g. the value chart's MAX from Jan 2025): "Mar" could be
            // either year, so append it.
            let crossesYear = Calendar.current.component(.year, from: first)
                != Calendar.current.component(.year, from: last)
            return crossesYear ? .dateTime.month(.abbreviated).year()
                               : .dateTime.month(.abbreviated)
        }
        // Multi-year spans: year-only is right only when consecutive ticks
        // actually land in different years. Over ~2 years with 4 ticks they
        // don't — the axis renders "2024, 2025, 2025, 2026", the same
        // duplicate-label problem month-only labels have on shorter ranges.
        return stepDays >= 365 ? .dateTime.year()
                               : .dateTime.month(.abbreviated).year()
    }
}
