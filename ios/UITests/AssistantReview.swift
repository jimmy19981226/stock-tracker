import XCTest

final class AssistantReview: XCTestCase {
    private func launch(theme: String, hook: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-api.baseURL", "http://127.0.0.1:8099", "-appearance", theme]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["UITEST_GUEST": "1", "UITEST_TAB": "assistant", hook: "1"]
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
            let frame = app.buttons["tab.\(tab)"].frame
            XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
        }
    }

    func testFormattedReplyLight() { checkFormatting("light") }
    func testFormattedReplyDark() { checkFormatting("dark") }

    private func checkFormatting(_ theme: String) {
        let app = launch(theme: theme, hook: "UITEST_CHAT_FORMAT")
        XCTAssertTrue(app.staticTexts["Your portfolio review"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<!--meta:")).firstMatch.exists)
        let table = app.scrollViews["assistant.table"].firstMatch
        XCTAssertTrue(table.exists)
        snapshot(app, "assistant-format-\(theme)")
        table.swipeLeft()
        XCTAssertTrue(app.staticTexts["NT$13,389"].isHittable, "Full profit must remain readable after horizontal scrolling")
        snapshot(app, "assistant-table-scrolled-\(theme)")
        app.terminate()
    }

    func testFormattingLargeText() {
        let app = launch(theme: "light", hook: "UITEST_CHAT_FORMAT", largeText: true)
        let table = app.scrollViews["assistant.table"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertLessThan(app.staticTexts["Assistant"].firstMatch.frame.height, 70, "Navigation title must not split across lines")
        for _ in 0..<6 where !table.isHittable { app.swipeUp() }
        XCTAssertTrue(table.isHittable)
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
