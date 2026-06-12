import Foundation

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

struct Holding: Codable, Identifiable, Hashable {
    var id: String { ticker }
    let ticker: String
    let name: String
    let currency: String
    let market: MarketCode
    let shares: Double
    let avgCost: Double
    let currentPrice: Double?
    let marketValue: Double?
    let costBasis: Double
    let exitCost: Double?
    let unrealizedPl: Double?
    let unrealizedPlPct: Double?
    let todayChange: Double?
    let todayChangePct: Double?
}

struct CurrencySummary: Codable, Identifiable, Hashable {
    var id: String { currency }
    let currency: String
    let totalValue: Double?
    let totalCost: Double
    let totalPl: Double?
    let totalPlPct: Double?
    let todayPl: Double?
    let todayPlPct: Double?
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
