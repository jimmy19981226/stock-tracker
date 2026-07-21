import Foundation
import UIKit

// Codable models mirroring the FastAPI schemas (see frontend/src/api.ts). The
// API speaks snake_case; the shared decoder/encoder in APIClient uses the
// convertFromSnakeCase / convertToSnakeCase strategies, so properties here stay
// camelCase and map automatically (trade_date <-> tradeDate, etc.).

enum MarketCode: String, Codable, CaseIterable, Identifiable {
    case TW
    case US
    var id: String { rawValue }
    var displayName: String { self == .TW ? "Taiwan" : "United States" }
    var currencyCode: String { self == .TW ? "TWD" : "USD" }
    var flag: String { self == .TW ? "🇹🇼" : "🇺🇸" }
}

enum TradeType: String, Codable { case buy, sell }
enum TradeStatus: String, Codable { case open, closed }

struct Trade: Codable, Identifiable, Hashable {
    let id: Int
    let type: TradeType
    let ticker: String
    let shares: Double
    let price: Double
    let tradeDate: String
    let fee: Double
    let notes: String?
    let market: MarketCode
    let createdAt: String
    let status: TradeStatus
}

struct TradeCreate: Codable {
    var type: TradeType
    var ticker: String
    var shares: Double
    var price: Double
    var tradeDate: String
    var fee: Double
    var notes: String?
    var market: MarketCode?
}

// Price-derived fields are `var` so PortfolioStore can overlay real-time
// device-fetched TWSE MIS prices on top of the backend's values.
struct Holding: Codable, Identifiable, Hashable {
    var id: String { ticker }
    let ticker: String
    let name: String
    let currency: String
    let market: MarketCode
    let shares: Double
    let avgCost: Double
    var currentPrice: Double?
    var marketValue: Double?
    let costBasis: Double
    var exitCost: Double?
    var unrealizedPl: Double?
    var unrealizedPlPct: Double?
    var todayChange: Double?
    var todayChangePct: Double?
}

struct CurrencySummary: Codable, Identifiable, Hashable {
    var id: String { currency }
    let currency: String
    var totalValue: Double?
    let totalCost: Double
    var totalPl: Double?
    var totalPlPct: Double?
    var todayPl: Double?
    var todayPlPct: Double?
    let realizedPl: Double
    let dividends: Double
    let totalEarned: Double
    let yearEarned: Double
    let year: Int
    let holdingsCount: Int
}

struct Dividend: Codable, Identifiable, Hashable {
    let id: Int
    let ticker: String
    let amount: Double
    let currency: String
    let market: MarketCode
    let payDate: String
    let notes: String?
    let createdAt: String
}

struct DividendCreate: Codable {
    var ticker: String
    var amount: Double
    var payDate: String
    var notes: String?
    var market: MarketCode?
}

struct PortfolioOverview: Codable {
    let tw: CurrencySummary?
    let us: CurrencySummary?
    let fx: FX
    let combined: Combined

    struct FX: Codable {
        let usdTwd: Double?
        let asof: String?
    }
    struct Combined: Codable {
        let twd: Double?
        let usd: Double?
    }
}

struct MarketConfig: Codable, Identifiable, Hashable {
    var id: String { code.rawValue }
    let code: MarketCode
    let name: String
    let currency: String
    let timezone: String
    let openMinute: Int
    let closeMinute: Int
    let holidays: [String]
}

/// Availability of one quote source, as probed live by /api/quotes/sources.
struct QuoteSourceInfo: Codable, Hashable {
    let available: Bool
    let via: String?      // "relay" | "direct" | nil
    let realtime: Bool
}

struct QuoteSourcesStatus: Codable {
    let mis: QuoteSourceInfo
    let yahoo: QuoteSourceInfo
}

struct EarningsPoint: Codable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    let realized: Double
    let dividends: Double
    let total: Double
}

// MARK: - Market indices (pinned index strip)

/// One market index in the strip pinned across a market's pages.
struct IndexQuote: Codable, Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String        // Yahoo symbol, e.g. "^TWII", "^GSPC"
    let name: String
    let market: MarketCode
    var price: Double?
    var change: Double?
    var changePct: Double?
}

struct IndicesResponse: Codable {
    let indices: [IndexQuote]
}

/// One live price tick from /api/quotes/stream (US stocks + indices).
struct QuoteTick {
    let ticker: String
    let price: Double
    let prevClose: Double?
    let change: Double?
    let changePct: Double?
}

// MARK: - Dividend calendar (除權息行事曆 + projected income)

struct CurrencyAmount: Codable, Hashable {
    let currency: String
    let amount: Double
}

struct DividendCalendar: Codable {
    let projectedAnnual: [CurrencyAmount]
    let months: [Month]
    let upcoming: [Upcoming]

    struct Item: Codable, Hashable {
        let ticker: String
        let market: MarketCode
        let currency: String
        let amount: Double
        let perShare: Double?
    }
    struct Month: Codable, Hashable {
        let month: String          // "2026-08"
        let items: [Item]
        let totals: [CurrencyAmount]
    }
    struct Upcoming: Codable, Hashable {
        let ticker: String
        let market: MarketCode
        let currency: String
        let exDate: String
        let amount: Double?
        let perShare: Double?
    }
}

// MARK: - Performance (TWR / XIRR / benchmark / 期間績效)

struct PerformanceReport: Codable {
    let market: MarketCode
    let currency: String
    let period: String
    let twrPct: Double?
    let twrAnnualizedPct: Double?
    let xirrPct: Double?
    let periodPl: Double?
    let portfolioSeries: [PctPoint]
    let benchmark: Benchmark
    let monthly: [MonthlyPL]

    struct PctPoint: Codable, Hashable {
        let date: String
        let pct: Double
    }
    struct Benchmark: Codable {
        let symbol: String
        let name: String
        let returnPct: Double?
        let series: [PctPoint]
    }
    struct MonthlyPL: Codable, Hashable, Identifiable {
        var id: String { month }
        let month: String          // "2026-04"
        let pl: Double
        let returnPct: Double?
    }
}

// MARK: - AI image import (parse a brokerage screenshot into records)

struct ParsedTradeRow: Codable, Hashable {
    let type: TradeType
    let ticker: String
    let shares: Double
    let price: Double
    let date: String
    let fee: Double?
    let notes: String?
}

struct ParsedDividendRow: Codable, Hashable {
    let ticker: String
    let amount: Double
    let date: String
    let notes: String?
}

struct ParsedRecords: Codable {
    let trades: [ParsedTradeRow]
    let dividends: [ParsedDividendRow]
    let notes: String
}

// MARK: - AI Assistant

struct AiStatus: Codable {
    let configured: Bool
    let model: String
}

struct ChatMessage: Codable, Hashable {
    let role: String   // "user" | "assistant"
    let content: String
    /// A data URL (`data:image/jpeg;base64,...`) when an image was attached
    /// to this turn — present on server-loaded history. Locally-composed
    /// messages (not yet round-tripped) instead populate `localImage` below.
    var image: String? = nil

    /// The just-picked image for a message this device is about to send /
    /// just sent, before the server round-trip would give us `image` back.
    /// Not Codable (never persisted or decoded) — purely a local UI hint.
    var localImage: UIImage? = nil

    enum CodingKeys: String, CodingKey { case role, content, image }

    init(role: String, content: String, image: String? = nil, localImage: UIImage? = nil) {
        self.role = role
        self.content = content
        self.image = image
        self.localImage = localImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        localImage = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(image, forKey: .image)
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.role == rhs.role && lhs.content == rhs.content && lhs.image == rhs.image
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(role)
        hasher.combine(content)
        hasher.combine(image)
    }

    /// A UIImage for display, whichever source has it — the locally-picked
    /// image before send, or the server's base64 data URL after reload.
    var displayImage: UIImage? {
        if let localImage { return localImage }
        guard let image, let comma = image.firstIndex(of: ","),
              let data = Data(base64Encoded: String(image[image.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }
}

struct ChatSummary: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let createdAt: String
    let updatedAt: String
    let messageCount: Int
}

struct ChatDetail: Codable, Identifiable {
    let id: Int
    let title: String
    let createdAt: String
    let updatedAt: String
    let messages: [ChatMessage]
}

// MARK: - Stock detail

struct StockDetailLive: Codable {
    let price: Double?
    let previousClose: Double?
    let todayChange: Double?
    let todayChangePct: Double?
    let dayOpen: Double?
    let dayHigh: Double?
    let dayLow: Double?
    let bid: Double?
    let ask: Double?
    let volume: Double?
}

struct StockDetailFundamentals: Codable {
    var symbol: String?
    var longName: String?
    var shortName: String?
    var sector: String?
    var industry: String?
    var marketCap: Double?
    var currency: String?
    var pe: Double?
    var forwardPe: Double?
    var eps: Double?
    var dividendYield: Double?
    var dividendRate: Double?
    var payoutRatio: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
    var fiftyDayAvg: Double?
    var twoHundredDayAvg: Double?
    var beta: Double?
    var bookValue: Double?
    var priceToBook: Double?
    var sharesOutstanding: Double?
    var averageVolume: Double?
    var averageVolume10d: Double?
    var earningsDate: String?
    var exDividendDate: String?
    var lastDividendDate: String?
    var targetMeanPrice: Double?
    var targetMedianPrice: Double?
    var targetHighPrice: Double?
    var targetLowPrice: Double?
    var analystCount: Double?
    var recommendationMean: Double?
    var recommendationKey: String?
}

struct StockDetailPosition: Codable {
    let shares: Double
    let avgCost: Double?
    let costBasis: Double
    let marketValue: Double?
    let exitCost: Double?
    let unrealizedPl: Double?
    let unrealizedPlPct: Double?
    let realizedPl: Double
    let dividendsReceived: Double
    let totalReturn: Double
    let totalReturnPct: Double
    let firstBuyDate: String?
    let holdingDays: Int?
    let tradeCount: Int
    let feesPaid: Double
}

struct StockHistoryBar: Codable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double?
    let volume: Double?
}

struct StockTradeMarker: Codable, Hashable {
    let date: String
    let type: TradeType
    let shares: Double
    let price: Double
    let fee: Double
    let notes: String?
}

struct StockDividendMarker: Codable, Hashable {
    let date: String
    let amount: Double
    let notes: String?
}

struct MonthlyRevenue: Codable, Identifiable, Hashable {
    var id: String { month }
    let month: String
    let revenue: Double
    let yoyPct: Double?
}

struct QuarterlyFinancials: Codable, Identifiable, Hashable {
    var id: String { quarter }
    let quarter: String
    let revenue: Double?
    let netIncome: Double?
    let grossProfit: Double?
    let operatingIncome: Double?
    let epsDiluted: Double?
    let grossMargin: Double?
    let operatingMargin: Double?
    let netMargin: Double?
}

struct StockDetail: Codable {
    let ticker: String
    let symbol: String
    let name: String
    let live: StockDetailLive
    let fundamentals: StockDetailFundamentals
    let position: StockDetailPosition?
    let history: [StockHistoryBar]
    let taiexHistory: [StockHistoryBar]
    let trades: [StockTradeMarker]
    let dividends: [StockDividendMarker]
    let yieldOnCost: Double?
    let monthlyRevenue: [MonthlyRevenue]
    let quarterlyFinancials: [QuarterlyFinancials]
}

/// One day of the portfolio's total market value (the net-worth curve).
struct ValuePoint: Codable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    let total: Double
}

/// Period tabs for the portfolio-value chart (Stocks-app style).
enum ValuePeriod: String, CaseIterable, Identifiable {
    case week = "5d"
    case month = "1mo"
    case threeMonth = "3mo"
    case ytd = "ytd"
    case year = "1y"
    case max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "1W"
        case .month: return "1M"
        case .threeMonth: return "3M"
        case .ytd: return "YTD"
        case .year: return "1Y"
        case .max: return "MAX"
        }
    }
    /// Suffix for the range-change line ("+NT$12,345 (+1.2%) Past month").
    var changeSuffix: String {
        switch self {
        case .week: return "Past week"
        case .month: return "Past month"
        case .threeMonth: return "Past 3 months"
        case .ytd: return "This year"
        case .year: return "Past year"
        case .max: return "All time"
        }
    }
}

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case oneMonth = "1mo"
    case threeMonth = "3mo"
    case sixMonth = "6mo"
    case oneYear = "1y"
    case twoYear = "2y"
    case fiveYear = "5y"
    case max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oneMonth: return "1M"
        case .threeMonth: return "3M"
        case .sixMonth: return "6M"
        case .oneYear: return "1Y"
        case .twoYear: return "2Y"
        case .fiveYear: return "5Y"
        case .max: return "MAX"
        }
    }
}
