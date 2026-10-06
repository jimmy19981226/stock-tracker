import XCTest
@testable import StockTracker

@MainActor
final class QuoteRefreshTests: XCTestCase {
    func testNetworkDelayDoesNotShiftTheNextDeadline() {
        let start = ContinuousClock.now
        var schedule = QuoteRefreshSchedule(now: start)
        XCTAssertEqual(schedule.deadline, start.advanced(by: .seconds(5)))
        schedule.advance(past: start.advanced(by: .seconds(7)))
        XCTAssertEqual(schedule.deadline, start.advanced(by: .seconds(10)))
        schedule.advance(past: start.advanced(by: .seconds(10)))
        XCTAssertEqual(schedule.deadline, start.advanced(by: .seconds(15)))
    }

    func testResumingSkipsMissedUpdatesInsteadOfReplayingThem() {
        let start = ContinuousClock.now
        var schedule = QuoteRefreshSchedule(now: start)
        schedule.advance(past: start.advanced(by: .seconds(42)))
        XCTAssertEqual(schedule.deadline, start.advanced(by: .seconds(45)))
    }

    func testBurstKeepsOnlyTheNewestQuoteForEachSymbol() {
        let start = ContinuousClock.now
        var buffer = LiveQuoteBuffer()
        for price in 101...150 {
            buffer.insert(tick(Double(price)), at: start)
        }
        buffer.insert(tick(200, ticker: "MSFT"), at: start)
        XCTAssertEqual(buffer.latest.count, 2)
        XCTAssertEqual(buffer.latest["AAPL"]?.quote.price, 150)
        XCTAssertEqual(buffer.latest["MSFT"]?.quote.price, 200)
    }

    func testLateOlderQuoteCannotReplaceANewerQuote() {
        let start = ContinuousClock.now
        var buffer = LiveQuoteBuffer()
        buffer.insert(tick(120, timestamp: Date(timeIntervalSince1970: 200)), at: start)
        buffer.insert(tick(110, timestamp: Date(timeIntervalSince1970: 100)),
                      at: start.advanced(by: .seconds(1)))
        XCTAssertEqual(buffer.latest["AAPL"]?.quote.price, 120)
    }

    func testSlowSnapshotKeepsQuotesReceivedAfterItsRequestStarted() {
        let start = ContinuousClock.now
        var buffer = LiveQuoteBuffer()
        buffer.insert(tick(100, ticker: "MSFT"), at: start)
        buffer.insert(tick(120), at: start.advanced(by: .seconds(3)))
        // A request started at second 1, but finished after the second-5
        // display update. The new AAPL tick must survive its later commit.
        buffer.discard(before: start.advanced(by: .seconds(1)))
        XCTAssertNil(buffer.latest["MSFT"])
        XCTAssertEqual(buffer.latest["AAPL"]?.quote.price, 120)
    }

    func testPriceProfitAndPercentagesUseTheSameQuoteBatch() {
        let updated = PortfolioStore.applyingLiveQuotes(
            holdings: [holding()], summaries: [summary("USD", value: 1_000, cost: 800)],
            indices: [], quotes: [tick(120)])
        let position = updated.holdings[0]
        XCTAssertEqual(position.currentPrice, 120)
        XCTAssertEqual(position.marketValue, 1_200)
        XCTAssertEqual(position.unrealizedPl, 400)
        XCTAssertEqual(position.unrealizedPlPct, 50)
        XCTAssertEqual(position.todayChange, 200)
        XCTAssertEqual(position.todayChangePct, 20)
        XCTAssertEqual(updated.summaries[0].totalValue, 1_200)
        XCTAssertEqual(updated.summaries[0].todayPlPct, 20)
    }

    func testMissingPreviousCloseUsesThePriorQuoteRatherThanTheNewPrice() {
        let withoutClose = QuoteTick(ticker: "AAPL", price: 120, prevClose: nil,
                                    change: nil, changePct: nil)
        let updated = PortfolioStore.applyingLiveQuotes(
            holdings: [holding()], summaries: [summary("USD", value: 1_000, cost: 800)],
            indices: [], quotes: [withoutClose])
        XCTAssertEqual(updated.holdings[0].todayChangePct, 20)
        XCTAssertEqual(updated.holdings[0].todayChange, 200)
    }

    func testOverviewMatchesThePublishedMarketTotals() {
        let summaries = [summary("TWD", value: 10_000, cost: 8_000),
                         summary("USD", value: 1_200, cost: 800)]
        let source = PortfolioOverview(tw: nil, us: nil,
                                       fx: .init(usdTwd: 30, asof: nil),
                                       combined: .init(twd: 1, usd: 1))
        let overview = PortfolioStore.combinedOverview(summaries: summaries, source: source)
        XCTAssertEqual(overview?.combined.twd, 46_000)
        XCTAssertEqual(overview?.us?.totalValue, 1_200)
        XCTAssertEqual(overview!.combined.usd!, 46_000.0 / 30, accuracy: 0.000_001)
    }

    func testMissingExchangeRateDoesNotProduceAPartialCombinedTotal() {
        let source = PortfolioOverview(tw: nil, us: nil,
                                       fx: .init(usdTwd: nil, asof: nil),
                                       combined: .init(twd: nil, usd: nil))
        let overview = PortfolioStore.combinedOverview(
            summaries: [summary("TWD", value: 10_000, cost: 8_000),
                        summary("USD", value: 1_200, cost: 800)], source: source)
        XCTAssertNil(overview?.combined.twd)
        XCTAssertNil(overview?.combined.usd)
    }

    func testInvalidQuotesCannotEnterTheDisplayBuffer() {
        var buffer = LiveQuoteBuffer()
        for price in [Double.nan, .infinity, -.infinity, 0, -1] {
            buffer.insert(tick(price), at: ContinuousClock.now)
        }
        XCTAssertTrue(buffer.latest.isEmpty)
    }

    func testRemovedMarketDoesNotKeepItsOldOverviewValue() {
        let source = PortfolioOverview(tw: summary("TWD", value: 10_000, cost: 8_000), us: nil,
                                       fx: .init(usdTwd: 30, asof: nil),
                                       combined: .init(twd: 10_000, usd: 10_000.0 / 30))
        let overview = PortfolioStore.combinedOverview(summaries: [], source: source)
        XCTAssertNil(overview?.tw)
        XCTAssertEqual(overview?.combined.twd, 0)
        XCTAssertEqual(overview?.combined.usd, 0)
    }

    private func tick(_ price: Double, ticker: String = "AAPL", timestamp: Date? = nil) -> QuoteTick {
        QuoteTick(ticker: ticker, price: price, prevClose: 100,
                  change: price - 100, changePct: price - 100, timestamp: timestamp)
    }

    private func holding() -> Holding {
        Holding(ticker: "AAPL", name: "Apple", currency: "USD", market: .US,
                shares: 10, avgCost: 80, currentPrice: 100, marketValue: 1_000,
                costBasis: 800, exitCost: 0, unrealizedPl: 200, unrealizedPlPct: 25,
                todayChange: 0, todayChangePct: 0)
    }

    private func summary(_ currency: String, value: Double, cost: Double) -> CurrencySummary {
        CurrencySummary(currency: currency, totalValue: value, totalCost: cost,
                        totalPl: value - cost, totalPlPct: (value - cost) / cost * 100,
                        todayPl: 0, todayPlPct: 0, realizedPl: 0, dividends: 0,
                        totalEarned: 0, yearEarned: 0, year: 2026, holdingsCount: 1)
    }
}
