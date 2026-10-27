import XCTest

final class AssistantReview: XCTestCase {
    private func launch(theme: String, hook: String, largeText: Bool = false, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["UITEST_GUEST": "1", "UITEST_TAB": "assistant", hook: "1"]
        if reduceMotion { app.launchEnvironment["UITEST_REDUCE_MOTION"] = "1" }
        app.launch()
        XCTAssertTrue(app.buttons["tab.assistant"].waitForExistence(timeout: 20))
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        for tab in ["overview", "trades", "assistant", "dividends", "settings"] {
            let button = app.buttons["tab.\(tab)"]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
        }
    }

    func testFormattedReplyLight() { checkFormatting("light") }
    func testFormattedReplyDark() { checkFormatting("dark") }
    func testFormattedReplyReduceMotion() { checkFormatting("dark", reduceMotion: true) }

    private func checkFormatting(_ theme: String, reduceMotion: Bool = false) {
        let app = launch(theme: theme, hook: "UITEST_CHAT_FORMAT", reduceMotion: reduceMotion)
        XCTAssertTrue(app.staticTexts["Your portfolio review"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<!--meta:")).firstMatch.exists)
        let table = app.scrollViews["assistant.table"].firstMatch
        XCTAssertTrue(table.exists)
        let copy = app.buttons["Copy reply"].firstMatch
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Reply copied"].waitForExistence(timeout: 1))
        snapshot(app, "assistant-format-\(theme)")
        table.swipeLeft()
        XCTAssertTrue(app.staticTexts["NT$13,389"].isHittable, "Full profit must remain readable after horizontal scrolling")
        snapshot(app, "assistant-table-scrolled-\(theme)")
        app.terminate()
    }

    func testWelcomeLight() { checkWelcome("light") }
    func testWelcomeDark() { checkWelcome("dark") }
    private func checkWelcome(_ theme: String) {
        let app = launch(theme: theme, hook: "UITEST_CHAT_EMPTY")
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Gemini 3.5 Flash-Lite"].isHittable)
        let daily = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Your daily briefing")).firstMatch
        XCTAssertTrue(daily.isHittable)
        snapshot(app, "assistant-welcome-\(theme)")
        daily.tap()
        XCTAssertEqual(app.textFields["assistantComposer"].value as? String, "How is my portfolio doing today?")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "assistant-welcome-keyboard-\(theme)")
        app.terminate()
    }

    func testLongMetricTableAndFollowUpLight() { checkLongMetricTable("light") }
    func testLongMetricTableAndFollowUpDark() { checkLongMetricTable("dark") }
    private func checkLongMetricTable(_ theme: String) {
        let app = launch(theme: theme, hook: "UITEST_CHAT_LONG_NAME")
        let table = app.descendants(matching: .any)["assistant.metricTable"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let company = app.staticTexts["Taiwan Semiconductor Manufacturing Company Limited"]
        let amount = app.staticTexts["US$1,234.56"]
        XCTAssertTrue(company.isHittable)
        XCTAssertTrue(amount.isHittable)
        XCTAssertGreaterThan(company.frame.height, 24, "Long company names should wrap in the metric table")
        XCTAssertLessThan(amount.frame.height, 30, "A monetary value must stay on one line")
        for element in [table, company, amount] {
            XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        }
        snapshot(app, "assistant-long-metric-table-\(theme)")
        let followUp = app.buttons["assistant.followUp.Explain this simply"]
        XCTAssertTrue(followUp.exists)
        for _ in 0..<4 where !followUp.isHittable { app.swipeUp() }
        followUp.tap()
        XCTAssertEqual(app.textFields["assistantComposer"].value as? String, "Explain this simply")
        XCTAssertEqual(app.buttons["assistantSend"].label, "Send message")
        XCTAssertFalse(app.staticTexts["assistant.progress"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        snapshot(app, "assistant-follow-up-draft-\(theme)")
        app.terminate()
    }

    func testFormattingLargeText() {
        let app = launch(theme: "light", hook: "UITEST_CHAT_FORMAT", largeText: true)
        let table = app.scrollViews["assistant.table"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertLessThan(app.staticTexts["Assistant"].firstMatch.frame.height, 70, "Navigation title must not split across lines")
        for _ in 0..<6 where !table.isHittable { app.swipeUp() }
        XCTAssertTrue(table.isHittable)
        let composer = app.textFields["assistantComposer"]
        let attach = app.buttons["Attach a screenshot"]
        let send = app.buttons["assistantSend"]
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(attach.isHittable)
        XCTAssertLessThanOrEqual(attach.frame.maxX, composer.frame.minX + 1,
                                 "Attachment control must not overlap the composer at large text sizes")
        XCTAssertLessThanOrEqual(composer.frame.maxX, send.frame.minX + 1,
                                 "Send control must not overlap the composer at large text sizes")
        XCTAssertGreaterThan(composer.frame.width, 60)
        XCTAssertLessThan(app.staticTexts["Gemini 3.5 Flash-Lite"].frame.height, 40,
                          "The compact model subtitle should not crowd the header")
        snapshot(app, "assistant-large-text")
        app.terminate()
    }

    func testDiscardingProposalDoesNotSaveIt() {
        let app = launch(theme: "light", hook: "UITEST_CHAT_EDIT")
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        snapshot(app, "assistant-edit-proposal")
        discard.tap()
        XCTAssertFalse(app.buttons["Save change"].exists)
        app.terminate()
    }

    func testDeleteProposalCanBeKept() {
        let app = launch(theme: "dark", hook: "UITEST_CHAT_DELETE")
        let keep = app.buttons["Keep it"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        snapshot(app, "assistant-delete-proposal")
        keep.tap()
        XCTAssertFalse(app.buttons["Keep it"].exists)
        app.terminate()
    }
}
