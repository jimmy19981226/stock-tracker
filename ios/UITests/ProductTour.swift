import XCTest

/// Run against DesignPreview/server.py: synthetic data, no production writes.
final class ProductTour: XCTestCase {
    private func launch(_ appearance: String, tab: String = "overview", market: String? = nil, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", appearance]
        app.launchEnvironment["UITEST_GUEST"] = "1"
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment["UITEST_TAB"] = tab
        if let market { app.launchEnvironment["UITEST_MARKET"] = market }
        app.launch()
        XCTAssertTrue(app.buttons["tab.overview"].waitForExistence(timeout: 15))
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        for tab in ["overview", "trades", "assistant", "dividends", "settings"] {
            let button = app.buttons["tab.\(tab)"]
            if !app.buttons["Close"].exists {
                XCTAssertTrue(button.exists, "Missing main navigation: \(tab)")
                XCTAssertTrue(button.isHittable, "Unreachable main navigation: \(tab)")
                XCTAssertGreaterThan(button.frame.height, 0)
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

    func testGreetingLight() { checkGreeting("light", hour: 9, name: "James", expected: "Good morning, James") }
    func testGreetingDark() { checkGreeting("dark", hour: 19, name: "James", expected: "Good evening, James") }
    func testGreetingLargeText() {
        checkGreeting("light", hour: 14, name: "Alexandria", expected: "Good afternoon, Alexandria", largeText: true)
    }

    private func checkGreeting(_ theme: String, hour: Int, name: String, expected: String, largeText: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"] }
        app.launchEnvironment = ["UITEST_GUEST": "1", "UITEST_GREETING_NAME": name, "UITEST_GREETING_HOUR": String(hour)]
        app.launch()
        let greeting = app.staticTexts["overview.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15))
        XCTAssertEqual(greeting.label, expected)
        XCTAssertTrue(greeting.isHittable)
        XCTAssertTrue(app.staticTexts["Your portfolio"].isHittable)
        let settings = app.buttons["Account settings"]
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(greeting.frame.maxX, settings.frame.minX)
        XCTAssertLessThanOrEqual(greeting.frame.maxY, app.staticTexts["Your portfolio"].frame.minY)
        XCTAssertTrue(app.buttons["marketTicker.next"].waitForExistence(timeout: 10))
        snap(app, largeText ? "greeting-large-text" : "greeting-\(theme)")
        app.terminate()
    }

    func testYearEarningsLight() { checkYearEarnings("light") }
    func testYearEarningsDark() { checkYearEarnings("dark") }
    func testYearEarningsLargeText() { checkYearEarnings("light", largeText: true) }

    private func checkYearEarnings(_ theme: String, largeText: Bool = false) {
        continueAfterFailure = false
        let app = launch(theme, largeText: largeText)
        let hero = app.descendants(matching: .any)["overview.portfolioHero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15))
        let card = app.descendants(matching: .any)["overview.yearEarnings"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let expected = [
            ("Taiwan, Realized stock P/L", "NT$0"),
            ("United States, Realized stock P/L", "US$0.00"),
            ("Taiwan, Dividends received", "NT$3,180"),
            ("United States, Dividends received", "US$54.30"),
        ]
        // SwiftUI exposes each metric through its parent label/value and
        // propagates the card identifier, so assert the VoiceOver contract.
        let values = expected.map { app.staticTexts[$0.0] }
        let loaded = zip(values, expected).map { element, item in
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", item.1), object: element)
        }
        XCTAssertEqual(XCTWaiter.wait(for: loaded, timeout: 15), .completed,
                       "Year-to-date realized P/L and dividends must retain each market's currency")
        func cardFrame() -> CGRect {
            app.staticTexts.matching(identifier: "overview.yearEarnings").allElementsBoundByIndex
                .reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -16, dy: -16)
        }
        let scroll = app.scrollViews.firstMatch
        let nav = app.buttons["tab.overview"]
        for _ in 0..<8 {
            if cardFrame().minY >= app.frame.minY + 60 && cardFrame().maxY <= nav.frame.minY { break }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: cardFrame().maxY > nav.frame.minY ? 0.48 : 0.92))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertGreaterThanOrEqual(cardFrame().minY, app.frame.minY + 60)
        XCTAssertLessThanOrEqual(cardFrame().maxY, nav.frame.minY,
                                 "The full earnings card should fit above the main navigation")
        snap(app, "year-earnings-\(largeText ? "large-text" : theme)")
        for (element, item) in zip(values, expected) {
            XCTAssertTrue(element.isHittable, "Year-to-date amount is not visible: \(item.0)")
            XCTAssertEqual(element.value as? String, item.1)
            XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX + 16)
            XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX - 16)
            XCTAssertTrue(hero.frame.contains(element.frame), "Year-to-date earnings must be inside the portfolio hero")
        }
        XCTAssertGreaterThanOrEqual(app.buttons["Add trade"].frame.minY, hero.frame.maxY,
                                    "Quick actions should follow the combined portfolio card")
        app.buttons["tab.assistant"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.terminate()
    }

    private func tour(_ theme: String) {
        var app = launch(theme)
        XCTAssertTrue(app.buttons["market.TW"].waitForExistence(timeout: 15))
        snap(app, "\(theme)-01-home")
        let history = app.staticTexts["Portfolio history"]
        for _ in 0..<5 {
            if history.isHittable && history.frame.minY < app.frame.midY { break }
            app.swipeUp()
        }
        XCTAssertTrue(history.isHittable, "Portfolio history must be visible in its screenshot")
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
        XCTAssertTrue(app.buttons["tab.overview"].isHittable, "Main navigation must remain available while composing")
        snap(app, "\(theme)-11-composer")
        app.terminate()

        app = launch(theme, tab: "settings")
        XCTAssertTrue(app.staticTexts["Make Studio your own."].waitForExistence(timeout: 10))
        snap(app, "\(theme)-12-settings")
        app.terminate()
    }

    func testHomeActions() { checkHomeActions("light") }
    func testHomeActionsDark() { checkHomeActions("dark") }

    private func checkHomeActions(_ theme: String) {
        let app = launch(theme)
        XCTAssertTrue(app.buttons["market.TW"].waitForExistence(timeout: 15))
        snap(app, "final-home-\(theme)")
        app.buttons["Add trade"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sheet.title"].isHittable)
        XCTAssertEqual(app.staticTexts["sheet.title"].label, "Add trade")
        snap(app, "final-trade-entry-\(theme)")
        app.buttons["Close"].tap()
        app.buttons["Add dividend"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sheet.title"].label, "Add dividend")
        XCTAssertTrue(app.staticTexts["Cash dividend · TWD"].isHittable)
        XCTAssertFalse(app.staticTexts["TWSE/TPEx · fees 0.1425% + tax"].exists,
                       "Cash dividend entry must not claim trade fees or transaction tax")
        snap(app, "final-dividend-entry-\(theme)")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["tab.overview"].isHittable)
        app.buttons["tab.assistant"].tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 5))
        app.terminate()
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
        app.buttons["tab.assistant"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        snap(app, "large-text-assistant")
    }
}
