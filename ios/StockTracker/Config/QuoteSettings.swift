import Foundation

/// Which market-data source the backend should use for Taiwan quotes. Sent
/// with every API request as the X-Quote-Source header and applied server-side
/// per request. Yahoo always covers US tickers and anything the real-time
/// sources can't serve, so no choice ever breaks the dashboard.
enum QuoteSource: String, CaseIterable, Identifiable {
    case auto
    case mis
    case yahoo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .mis: return "TWSE MIS"
        case .yahoo: return "Yahoo"
        }
    }
}

enum QuoteSettings {
    private static let key = "quotes.source"

    static var source: QuoteSource {
        get { QuoteSource(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
