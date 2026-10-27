import XCTest

/// Run against DesignPreview/server.py: synthetic data, no production writes.
final class ProductTour: XCTestCase {
    private func launch(_ appearance: String, tab: String = "overview", market: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", appearance]
        app.launchEnvironment["UITEST_GUEST"] = "1"
        app.launchEnvironment["UITEST_TAB"] = tab
        if let market { app.launchEnvironment["UITEST_MARKET"] = market }
        app.launch()
        XCTAssertTrue(app.buttons["tab.overview"].waitForExistence(timeout: 15))
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        for tab in ["overview", "trades", "assistant", "dividends", "settings"] {
            let button = app.buttons["tab.\(tab)"]
            if button.exists {
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLight() { tour("light") }
    func testDark() { tour("dark") }

    private func tour(_ theme: String) {
        var app = launch(theme)
        XCTAssertTrue(app.buttons["market.TW"].waitForExistence(timeout: 15))
        snap(app, "\(theme)-01-home")
        app.swipeUp()
        snap(app, "\(theme)-02-history")
        app.terminate()

        app = launch(theme, market: "TW")
        let search = app.textFields["holdings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        snap(app, "\(theme)-03-holdings")
        app.swipeUp()
        search.tap()
        search.typeText("2330")
        XCTAssertTrue(app.staticTexts["2330"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["2382"].exists)
        snap(app, "\(theme)-04-search")
        app.staticTexts["2330"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stock.position"].firstMatch.waitForExistence(timeout: 10))
        snap(app, "\(theme)-05-detail")
        app.terminate()

        app = launch(theme, market: "TW")
        app.buttons["Performance"].tap()
        app.swipeUp()
        snap(app, "\(theme)-06-performance")
        app.buttons["tab.trades"].tap()
        XCTAssertTrue(app.buttons["+ Add trade"].waitForExistence(timeout: 5))
        snap(app, "\(theme)-07-trades")
        app.buttons["+ Add trade"].tap()
        snap(app, "\(theme)-08-add-trade")
        app.terminate()

        app = launch(theme, tab: "dividends")
        XCTAssertTrue(app.buttons["+ Add dividend"].waitForExistence(timeout: 10))
        snap(app, "\(theme)-09-dividends")
        app.buttons["tab.assistant"].tap()
        let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Your daily briefing")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        snap(app, "\(theme)-10-assistant")
        suggestion.tap()
        let composer = app.textFields["assistantComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "How is my portfolio doing today?")
        XCTAssertFalse(app.buttons["tab.overview"].exists, "Tab bar should step aside while composing")
        snap(app, "\(theme)-11-composer")
        app.terminate()

        app = launch(theme, tab: "settings")
        XCTAssertTrue(app.staticTexts["Make Studio your own."].waitForExistence(timeout: 10))
        snap(app, "\(theme)-12-settings")
        app.terminate()
    }

    func testHomeActions() {
        let app = launch("light")
        snap(app, "final-home")
        app.buttons["Add trade"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sheet.title"].isHittable)
        snap(app, "final-trade-entry")
        app.buttons["Close"].tap()
        app.buttons["Ask assistant"].tap()
        XCTAssertTrue(app.staticTexts["A little clarity.\nA better perspective."].waitForExistence(timeout: 5))
    }

    func testFinalHomeDark() {
        let app = launch("dark")
        XCTAssertTrue(app.buttons["market.TW"].waitForExistence(timeout: 15))
        snap(app, "final-home-dark")
    }

    func testLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", "light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launchEnvironment["UITEST_GUEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["market.TW"].waitForExistence(timeout: 15))
        snap(app, "large-text-home")
        app.buttons["Ask assistant"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        snap(app, "large-text-assistant")
    }
}
