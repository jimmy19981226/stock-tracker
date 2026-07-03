import Foundation

/// Formatting helpers mirroring the web app's format.ts so figures read the
/// same across platforms (NT$ / $, signed percentages, em-dash for nil).
enum Fmt {
    static func money(_ value: Double?, currency: String, digits: Int = 2) -> String {
        guard let v = value, !v.isNaN else { return "—" }
        let symbol = currency == "TWD" ? "NT$" : currency == "USD" ? "$" : ""
        let sign = v < 0 ? "-" : ""
        return "\(sign)\(symbol)\(number(abs(v), digits: digits))"
    }

    static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let v = value, !v.isNaN else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "—"
    }

    /// Compact share count: integers show no decimals, fractional shares keep them.
    static func shares(_ value: Double) -> String {
        if value == value.rounded() { return number(value, digits: 0) }
        return number(value, digits: 4)
    }

    static func pct(_ value: Double?) -> String {
        guard let v = value, !v.isNaN else { return "—" }
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }

    static func signedMoney(_ value: Double?, currency: String, digits: Int = 2) -> String {
        guard let v = value, !v.isNaN else { return "—" }
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(money(v, currency: currency, digits: digits))"
    }

    /// Big "net worth" style number — thousands separators, no decimals.
    static func bigMoney(_ value: Double?, currency: String) -> String {
        money(value, currency: currency, digits: 0)
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

    /// Abbreviate large counts (market cap, volume): 1.2B, 340M, 12K.
    static func compact(_ value: Double?) -> String {
        guard let v = value, !v.isNaN else { return "—" }
        let abs = Swift.abs(v)
        let sign = v < 0 ? "-" : ""
        switch abs {
        case 1e12...: return "\(sign)\(String(format: "%.2f", abs / 1e12))T"
        case 1e9...: return "\(sign)\(String(format: "%.2f", abs / 1e9))B"
        case 1e6...: return "\(sign)\(String(format: "%.2f", abs / 1e6))M"
        case 1e3...: return "\(sign)\(String(format: "%.1f", abs / 1e3))K"
        default: return number(v, digits: 0)
        }
    }

    /// Chart time-axis label format matched to the visible span: "Jun 5" for
    /// weeks–months, "Jun" for about a year, "2025" beyond that. A fixed
    /// month-only format repeats the same label on short ranges and drops the
    /// year on long ones.
    static func axisFormat(from first: Date, to last: Date) -> Date.FormatStyle {
        let days = last.timeIntervalSince(first) / 86_400
        if days <= 120 { return .dateTime.month(.abbreviated).day() }
        if days <= 550 {
            // Month-only labels turn ambiguous once the span straddles New
            // Year (e.g. the value chart's MAX from Jan 2025): "Mar" could be
            // either year, so append it.
            let crossesYear = Calendar.current.component(.year, from: first)
                != Calendar.current.component(.year, from: last)
            return crossesYear ? .dateTime.month(.abbreviated).year()
                               : .dateTime.month(.abbreviated)
        }
        return .dateTime.year()
    }
}
