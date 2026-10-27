import XCTest

final class MarketTickerTests: XCTestCase {
    private func launch(_ theme: String, flags: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        app.launchEnvironment = ["UITEST_GUEST": "1"].merging(flags) { _, new in new }
        app.launch()
        XCTAssertTrue(app.buttons["marketTicker.next"].waitForExistence(timeout: 20))
        return app
    }

    private func assertPlacement(_ app: XCUIApplication) {
        let heading = app.staticTexts["Your portfolio"]
        let ticker = app.buttons["marketTicker.next"]
        let total = app.staticTexts["Total portfolio value"]
        XCTAssertTrue(heading.isHittable)
        XCTAssertTrue(ticker.isHittable)
        XCTAssertTrue(total.exists)
        XCTAssertGreaterThanOrEqual(ticker.frame.minY, heading.frame.maxY,
                                    "Market ticker must appear below Your portfolio")
        XCTAssertLessThanOrEqual(ticker.frame.maxY, total.frame.minY,
                                 "Market ticker must appear before the portfolio value card")
    }

    private func assertAutomaticRotation(_ ticker: XCUIElement, minimumUnique: Int = 3) {
        var observed = Set<String>()
        let rotates = NSPredicate { _, _ in
            if let symbol = ticker.value as? String, !symbol.isEmpty { observed.insert(symbol) }
            return observed.count >= minimumUnique
        }
        let expectation = XCTNSPredicateExpectation(predicate: rotates, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 18), .completed,
                       "Ticker must automatically rotate through at least \(minimumUnique) indices; saw \(observed.sorted())")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRotationAndDetailsLight() { rotation("light") }
    func testRotationAndDetailsDark() { rotation("dark") }

    private func rotation(_ theme: String) {
        let app = launch(theme)
        let ticker = app.buttons["marketTicker.next"]
        assertPlacement(app)
        assertAutomaticRotation(ticker)
        let current = ticker.value as? String
        ticker.tap()
        XCTAssertNotEqual(ticker.value as? String, current, "Tapping must advance the index")
        assertPlacement(app)
        snapshot(app, "portfolio-market-ticker-\(theme)")

        for tab in ["trades", "assistant", "dividends", "settings"] {
            app.buttons["tab.\(tab)"].tap()
            XCTAssertFalse(ticker.exists, "The portfolio ticker must not become global navigation on \(tab)")
        }
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(ticker.waitForExistence(timeout: 5))
        assertPlacement(app)
        assertAutomaticRotation(ticker, minimumUnique: 2)

        app.buttons["marketTicker.details"].tap()
        XCTAssertTrue(app.staticTexts["sheet.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sheet.title"].label, "Market indices")
        XCTAssertTrue(app.staticTexts["TAIEX"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["S&P 500"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["NASDAQ"].firstMatch.exists)
        let edit = app.buttons["Edit indices"]
        for _ in 0..<5 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Close"].tap()
        XCTAssertTrue(ticker.waitForExistence(timeout: 5))
        assertAutomaticRotation(ticker, minimumUnique: 2)
        app.terminate()
    }

    func testReducedMotionStillAdvancesQuotes() {
        let app = launch("light", flags: ["UITEST_REDUCE_MOTION": "1"])
        assertPlacement(app)
        assertAutomaticRotation(app.buttons["marketTicker.next"])
        snapshot(app, "portfolio-market-ticker-reduced-motion")
        app.terminate()
    }

    func testMirroringInactiveSceneStillAdvancesQuotes() {
        let app = launch("dark", flags: ["UITEST_TICKER_INACTIVE": "1"])
        assertPlacement(app)
        assertAutomaticRotation(app.buttons["marketTicker.next"])
        snapshot(app, "portfolio-market-ticker-mirroring-inactive")
        app.terminate()
    }
}
