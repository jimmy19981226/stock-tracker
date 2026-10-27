import XCTest
@testable import StockTracker

final class PositionAccountingTests: XCTestCase {
    func testTaiwanPartialSaleUsesMovingAverageIncludingPurchaseFees() {
        let booked = PositionAccounting.realized(Array(ledger(.TW).reversed()))
        XCTAssertEqual(booked[3]!, 997, accuracy: 0.000_001)
        XCTAssertEqual(booked[5]!, 35.875, accuracy: 0.000_001)
        XCTAssertNil(booked[1])
    }

    func testUSRetainsFIFOForTheSamePurchasesAndSales() {
        let booked = PositionAccounting.realized(ledger(.US))
        XCTAssertEqual(booked[3]!, 1_497, accuracy: 0.000_001)
        XCTAssertEqual(booked[5]!, 98.5, accuracy: 0.000_001)
    }

    func testClosedTaiwanPositionStartsANewAverageOnReentry() {
        let trades = [trade(1, .buy, 10, 100, 2, .TW),
                      trade(2, .sell, 10, 150, 1, .TW),
                      trade(3, .buy, 5, 70, 3, .TW),
                      trade(4, .sell, 2, 80, 1, .TW)]
        let booked = PositionAccounting.realized(trades)
        XCTAssertEqual(booked[2]!, 497, accuracy: 0.000_001)
        XCTAssertEqual(booked[4]!, 17.8, accuracy: 0.000_001)
    }

    func testMixedMarketsKeepIndependentAccounting() {
        let tw = ledger(.TW)
        let us = ledger(.US, offset: 10)
        let booked = PositionAccounting.realized(tw + us)
        XCTAssertEqual(booked[3]!, 997, accuracy: 0.000_001)
        XCTAssertEqual(booked[13]!, 1_497, accuracy: 0.000_001)
    }

    private func ledger(_ market: MarketCode, offset: Int = 0) -> [Trade] {
        [trade(offset + 1, .buy, 10, 100, 2, market),
         trade(offset + 2, .buy, 10, 200, 2, market),
         trade(offset + 3, .sell, 10, 250, 1, market),
         trade(offset + 4, .buy, 10, 300, 3, market),
         trade(offset + 5, .sell, 2.5, 240, 1, market)]
    }

    private func trade(_ id: Int, _ type: TradeType, _ shares: Double,
                       _ price: Double, _ fee: Double, _ market: MarketCode) -> Trade {
        // All on one date to also verify deterministic ordering by trade id.
        Trade(id: id, type: type, ticker: market == .TW ? "2330" : "AAPL",
              shares: shares, price: price, tradeDate: "2026-09-30", fee: fee,
              notes: nil, market: market, createdAt: "2026-09-30T00:00:00",
              status: .closed)
    }
}
