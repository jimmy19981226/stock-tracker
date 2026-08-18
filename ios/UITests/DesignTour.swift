import XCTest

/// Not a test — a scripted tour that walks every screen and saves screenshots,
/// so UI work can be reviewed against what the app actually renders instead of
/// against what the code looks like. Points the app at a local backend seeded
/// with demo data via the standard NSUserDefaults argument-domain override.
///
/// Run:
///   xcodebuild test -scheme StockTracker \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:StockTrackerUITests/DesignTour/testTour
final class DesignTour: XCTestCase {

    /// Where the PNGs land: the test runner's own tmp. The runner is sandboxed,
    /// so an absolute path like /tmp silently fails — pull them off the host with
    ///   xcrun simctl get_app_container booted com.aistockstudio.uitests.xctrunner data
    private var outDir: String { NSTemporaryDirectory() + "design-tour" }

    private var baseURL: String {
        ProcessInfo.processInfo.environment["TOUR_API"] ?? "http://127.0.0.1:8099"
    }

    /// Both themes ship, so both get toured — `testTour` walks light and
    /// `testTourDark` walks dark. It's a stored property rather than an
    /// environment switch because neither plain env vars nor `TEST_RUNNER_*`
    /// reach this process; the latter is forwarded to the app under test.
    private var appearance = "light"

    private func snap(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Argument domain wins over the stored default, so the tour always hits
        // the local demo backend without touching the user's saved setting.
        app.launchArguments += ["-api.baseURL", baseURL, "-appearance", appearance]
        app.launchEnvironment["UITEST_GUEST"] = "1"
        return app
    }

    /// Tap the first element that exists among `labels`; returns what matched.
    @discardableResult
    private func tapAny(_ app: XCUIApplication, _ labels: [String],
                        timeout: TimeInterval = 20) -> String? {
        for label in labels {
            for element in [app.buttons[label].firstMatch,
                            app.staticTexts[label].firstMatch] {
                if element.waitForExistence(timeout: timeout / Double(labels.count) + 1),
                   element.isHittable {
                    element.tap()
                    return label
                }
            }
        }
        return nil
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons[name].firstMatch
        if button.waitForExistence(timeout: 10), button.isHittable { button.tap() }
    }

    func testSplashShowsVersion() throws {
        let app = makeApp()
        app.launch()
        let version = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Version'")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 6),
                      "No version label on the splash screen")
        snap(app, "splash-version")
    }

    /// Just the market dashboard — the quick loop while iterating on that screen.
    func testDashboardOnly() throws {
        let app = makeApp()
        app.launch()
        let taiwan = app.staticTexts["Taiwan"].firstMatch
        XCTAssertTrue(taiwan.waitForExistence(timeout: 120), "Taiwan card never appeared")
        taiwan.tap()
        sleep(12)  // live quotes + value history
        snap(app, "dash-top")
        app.swipeUp(); sleep(2); snap(app, "dash-scroll1")
        app.swipeUp(); sleep(2); snap(app, "dash-scroll2")
    }

    /// A single dark-theme shot for the README.
    func testOverviewDark() throws {
        appearance = "dark"
        let app = makeApp()
        app.launch()
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        sleep(8)
        snap(app, "05-overview-dark")
        let taiwan = app.staticTexts["Taiwan"].firstMatch
        if taiwan.isHittable {
            taiwan.tap(); sleep(10); snap(app, "15-dashboard-dark")
        }
    }

    /// The same walk in the dark theme.
    func testTourDark() throws {
        appearance = "dark"
        try testTour()
    }

    /// The market-index strip, expanded — the one panel whose sparkline shares
    /// its box with a label.
    func testIndexBar() throws {
        let app = makeApp()
        app.launch()
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        let expand = app.buttons["Show index details"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 20), "No index strip")
        expand.tap()
        sleep(6)  // the 1-month history has to land before the sparkline draws
        snap(app, "70-index-bar-expanded")
    }

    /// Focused check: with a keyboard up, is the tab bar still on screen?
    func testKeyboardChrome() throws {
        let app = makeApp()
        app.launch()
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        tab(app, "Assistant")
        sleep(3)
        let composer = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.tap()
        sleep(3)
        let overviewTab = app.buttons["Overview"].firstMatch
        XCTAssertFalse(overviewTab.exists,
                       "The tab bar is still on screen with the keyboard up")
        snap(app, "kbd-check")
    }

    /// README shots: the assistant with a real answer in it, seeded by the
    /// app's own demo hook rather than by hitting a provider.
    func testAssistantDemo() throws {
        let app = makeApp()
        app.launchEnvironment["UITEST_ASSISTANT_DEMO"] = "1"
        app.launchEnvironment["UITEST_TAB"] = "assistant"
        app.launch()
        sleep(8)
        snap(app, "55-assistant-demo")
        app.swipeUp(); sleep(1); snap(app, "56-assistant-demo-scrolled")
    }

    func testTour() throws {
        let app = makeApp()
        app.launch()

        // ---- Overview -----------------------------------------------------
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        sleep(8)
        snap(app, "01-overview-top")
        app.swipeUp(); sleep(1); snap(app, "02-overview-scrolled")
        app.swipeUp(); sleep(1); snap(app, "03-overview-bottom")
        app.swipeDown(); app.swipeDown(); sleep(1)

        // ---- Taiwan dashboard ---------------------------------------------
        let taiwan = app.staticTexts["Taiwan"].firstMatch
        if taiwan.waitForExistence(timeout: 30), taiwan.isHittable {
            taiwan.tap()
            sleep(10)  // live quotes + earnings history
            snap(app, "10-dashboard-top")
            for i in 1...4 {
                app.swipeUp(); sleep(2); snap(app, "1\(i)-dashboard-scroll\(i)")
            }

            // ---- Stock detail ---------------------------------------------
            var back = 0
            while !app.staticTexts["2330"].firstMatch.isHittable && back < 8 {
                app.swipeDown(); back += 1
            }
            let row = app.staticTexts["2330"].firstMatch
            if row.waitForExistence(timeout: 10), row.isHittable {
                row.tap()
                _ = app.staticTexts["Your position"].waitForExistence(timeout: 90)
                sleep(3)
                snap(app, "20-stock-detail-top")
                app.swipeUp(); sleep(2); snap(app, "21-stock-detail-mid")
                app.swipeUp(); sleep(2); snap(app, "22-stock-detail-low")
                app.swipeUp(); sleep(2); snap(app, "23-stock-detail-records")
                tapAny(app, ["Taiwan"], timeout: 10)
                sleep(2)
            }
            tapAny(app, ["Overview"], timeout: 10)
            sleep(2)
        }

        // ---- Trades -------------------------------------------------------
        tab(app, "Trades"); sleep(4)
        snap(app, "30-trades")
        app.swipeUp(); sleep(1); snap(app, "31-trades-scrolled")
        // Page two, to check the pager holds its position.
        let next = app.buttons.matching(identifier: "chevron.right").firstMatch
        if next.exists, next.isHittable {
            next.tap(); sleep(2); snap(app, "34-trades-page2")
            let prev = app.buttons.matching(identifier: "chevron.left").firstMatch
            if prev.exists, prev.isHittable { prev.tap(); sleep(2) }
        }
        app.swipeDown(); sleep(1)

        // ---- One trade's record page --------------------------------------
        let firstTrade = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'fee '  OR label CONTAINS ' · fee '")).firstMatch
        if firstTrade.waitForExistence(timeout: 8), firstTrade.isHittable {
            firstTrade.tap()
            sleep(3)
            snap(app, "32-trade-record")
            app.swipeUp(); sleep(1); snap(app, "33-trade-record-scrolled")
            tapAny(app, ["Trades"], timeout: 8)
            sleep(2)
        }

        // ---- Dividends ----------------------------------------------------
        tab(app, "Dividends"); sleep(5)
        snap(app, "40-dividends")
        app.swipeUp(); sleep(1); snap(app, "41-dividends-scrolled")
        let firstDividend = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '2026-'")).firstMatch
        if firstDividend.waitForExistence(timeout: 8), firstDividend.isHittable {
            firstDividend.tap()
            sleep(3)
            snap(app, "42-dividend-record")
            tapAny(app, ["Dividends"], timeout: 8)
            sleep(2)
        }

        // ---- Assistant ----------------------------------------------------
        tab(app, "Assistant"); sleep(4)
        snap(app, "50-assistant")
        // Typing must not lift the tab bar onto the keyboard.
        let composer = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch : app.textFields.firstMatch
        if composer.waitForExistence(timeout: 5), composer.isHittable {
            composer.tap(); sleep(2)
            snap(app, "51-assistant-keyboard")
        }

        // ---- Settings -----------------------------------------------------
        tab(app, "Settings"); sleep(4)
        snap(app, "60-settings-top")
        app.swipeUp(); sleep(1); snap(app, "61-settings-mid")
        app.swipeUp(); sleep(1); snap(app, "62-settings-bottom")
    }
}
