import XCTest

final class MarketTickerTests: XCTestCase {
    private func launch(_ theme: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        app.launchEnvironment = ["UITEST_GUEST": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["marketTicker.next"].waitForExistence(timeout: 20))
        return app
    }

    func testRotationAndDetailsLight() { rotation("light") }
    func testRotationAndDetailsDark() { rotation("dark") }

    private func rotation(_ theme: String) {
        let app = launch(theme)
        let ticker = app.buttons["marketTicker.next"]
        let original = ticker.value as? String
        XCTAssertNotNil(original)
        let changed = NSPredicate { _, _ in ticker.value as? String != original }
        expectation(for: changed, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(ticker.isHittable)
        let current = ticker.value as? String
        ticker.tap()
        XCTAssertNotEqual(ticker.value as? String, current, "Tapping must advance the index")
        XCTAssertLessThan(ticker.frame.maxY, app.buttons["market.TW"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "top-market-ticker-\(theme)"; shot.lifetime = .keepAlways; add(shot)

        for tab in ["trades", "assistant", "dividends", "settings", "overview"] {
            app.buttons["tab.\(tab)"].tap()
            XCTAssertTrue(ticker.isHittable, "Ticker must remain at the top of \(tab)")
        }
        app.buttons["marketTicker.details"].tap()
        XCTAssertTrue(app.staticTexts["sheet.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sheet.title"].label, "Market indices")
        XCTAssertTrue(app.staticTexts["TAIEX"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["S&P 500"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Edit indices"].isHittable)
        app.buttons["Close"].tap()
        XCTAssertTrue(ticker.isHittable)
        app.terminate()
    }
}
