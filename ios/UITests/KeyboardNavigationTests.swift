import XCTest

/// Interaction regressions against synthetic data, never a personal account.
final class KeyboardNavigationTests: XCTestCase {
    private let tabs = ["overview", "trades", "assistant", "dividends", "settings"]
    private func launch(_ theme: String, tab: String, market: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        app.launchEnvironment = ["UITEST_GUEST": "1", "UITEST_TAB": tab]
        if let market { app.launchEnvironment["UITEST_MARKET"] = market }
        app.launch()
        XCTAssertTrue(app.buttons["tab.\(tab)"].waitForExistence(timeout: 20))
        return app
    }
    private func menu(_ app: XCUIApplication, keyboard: Bool) {
        if keyboard { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)) }
        for tab in tabs {
            let button = app.buttons["tab.\(tab)"]
            XCTAssertTrue(button.exists, "Missing \(tab)")
            XCTAssertTrue(button.isHittable, "Unreachable \(tab)")
            XCTAssertGreaterThan(button.frame.height, 0)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            XCTAssertLessThanOrEqual(button.frame.maxY, keyboard ? app.keyboards.firstMatch.frame.minY + 1 : app.frame.maxY)
        }
    }
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testChatKeyboardLight() { chat("light") }
    func testChatKeyboardDark() { chat("dark") }
    private func chat(_ theme: String) {
        let app = launch(theme, tab: "assistant")
        let composer = app.textFields["assistantComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Review my portfolio tomorrow")
        menu(app, keyboard: true)
        XCTAssertTrue(app.buttons["assistantSend"].isHittable)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.buttons["tab.assistant"].frame.minY)
        snap(app, "keyboard-chat-\(theme)")
        for tab in tabs where tab != "assistant" {
            app.buttons["tab.\(tab)"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            menu(app, keyboard: false)
            app.buttons["tab.assistant"].tap()
            XCTAssertEqual(composer.value as? String, "Review my portfolio tomorrow")
            composer.tap(); menu(app, keyboard: true)
        }
        app.terminate()
    }
    func testHoldingsSearchCanNavigateAway() {
        let app = launch("light", tab: "overview", market: "TW")
        let search = app.textFields["holdings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        for _ in 0..<4 where !search.isHittable { app.swipeUp() }
        search.tap(); search.typeText("2330")
        menu(app, keyboard: true)
        XCTAssertLessThan(search.frame.maxY, app.buttons["tab.overview"].frame.minY)
        XCTAssertTrue(app.staticTexts["2330"].firstMatch.isHittable, "Matching holdings must be visible while typing")
        snap(app, "keyboard-holdings-search")
        app.buttons["tab.trades"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["+ Add trade"].waitForExistence(timeout: 5))
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5)); menu(app, keyboard: false)
        app.terminate()
    }
    func testTradeAndDividendCanDismissNumericKeyboardAndCancel() {
        for tab in ["trades", "dividends"] {
            let app = launch("light", tab: tab)
            let add = app.buttons[tab == "trades" ? "+ Add trade" : "+ Add dividend"]
            XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
            let number = app.textFields[tab == "trades" ? "100" : "0"]
            XCTAssertTrue(number.waitForExistence(timeout: 5)); number.tap(); number.typeText("123")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Close"].isHittable); snap(app, "keyboard-\(tab)-form")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            number.tap(); app.buttons["Close"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(add.waitForExistence(timeout: 5)); menu(app, keyboard: false)
            app.terminate()
        }
    }
    func testImportCanCancelWhileTyping() {
        let app = launch("dark", tab: "trades")
        let entry = app.buttons["AI import"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let note = app.textFields["US trades are in USD · the 優群 row is 3217"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        for _ in 0..<3 where !note.isHittable { app.swipeUp() }
        note.tap(); note.typeText("This is an unsaved note")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["Close"].frame.height, 44)
        snap(app, "keyboard-import-cancel"); app.buttons["Close"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5)); menu(app, keyboard: false)
        app.terminate()
    }
    func testSettingsKeyboardKeepsNavigation() {
        let app = launch("light", tab: "settings")
        let key = app.secureTextFields["AIza…"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        for _ in 0..<5 where !key.isHittable { app.swipeUp() }
        key.tap() // Focus only: never change a stored credential.
        menu(app, keyboard: true)
        XCTAssertLessThan(key.frame.maxY, app.buttons["tab.settings"].frame.minY)
        snap(app, "keyboard-settings")
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5)); menu(app, keyboard: false)
        app.terminate()
    }
    func testReplyContinuesAcrossTabSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8109", "-appearance", "light"]
        app.launchEnvironment = ["UITEST_GUEST": "1", "UITEST_TAB": "assistant"]
        app.launch()
        let composer = app.textFields["assistantComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap(); composer.typeText("Check the sample portfolio")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["Checking the sample portfolio…"].waitForExistence(timeout: 5))
        app.buttons["tab.trades"].tap()
        XCTAssertTrue(app.buttons["+ Add trade"].waitForExistence(timeout: 5))
        app.buttons["tab.assistant"].tap()
        let reply = app.staticTexts["Navigation test reply completed once."]
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Navigation test reply completed once.")).count, 1)
        menu(app, keyboard: false)
        snap(app, "chat-reply-survives-navigation")
        app.terminate()
    }

}
