import XCTest

final class MarketTickerTests: XCTestCase {
    private func launch(_ theme: String, flags: [String: String] = [:], baseURL: String = "http://127.0.0.1:8099") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", baseURL, "-appearance", theme]
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

    // Run DesignPreview/index_preview_server.py alongside the ordinary preview.
    func testEmptyHistoryCanBeRetried() { retryHistory("empty", theme: "light") }
    func testFailedHistoryCanBeRetried() { retryHistory("error", theme: "dark") }

    private func retryHistory(_ scenario: String, theme: String) {
        let app = launch(theme, baseURL: "http://127.0.0.1:8111/\(scenario)")
        let ticker = app.buttons["marketTicker.next"]
        XCTAssertTrue(ticker.label.contains("Unavailable"), "Missing quotes must be described explicitly")
        XCTAssertFalse(ticker.label.contains("0.00%"), "Unavailable changes must not look like zero returns")
        app.buttons["marketTicker.details"].tap()
        let retry = app.buttons["index.retry.^TWOII"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Finished empty/error history must offer Retry")
        snapshot(app, "index-\(scenario)-unavailable-\(theme)")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "index-\(scenario)-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(app.staticTexts["Chart unavailable"].isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Unavailable"))
            .allElementsBoundByIndex.contains { $0.isHittable }, "A visible index quote must say Unavailable")
        XCTAssertFalse(app.progressIndicators["index.loading.^TWOII"].exists,
                       "Failed history must stop the indefinite loading spinner")
        retry.tap()
        let chart = app.descendants(matching: .any)["index.chart.^TWOII"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "Retry must render recovered history")
        XCTAssertTrue(chart.isHittable)
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.staticTexts["Chart unavailable"].exists)
        XCTAssertFalse(app.progressIndicators["index.loading.^TWOII"].exists)
        snapshot(app, "index-\(scenario)-recovered-\(theme)")
        app.buttons["Close"].tap()
        XCTAssertTrue(ticker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.assistant"].isHittable)
        app.terminate()
    }
}
