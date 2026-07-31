import XCTest

/// Not a test — a scripted tour that walks every screen and saves screenshots,
/// so UI work can be reviewed against what the app actually renders instead of
/// against what the code looks like. Points the app at a local backend seeded
/// with demo data (see the repo's dev notes) via the standard NSUserDefaults
/// argument-domain override.
///
/// Run:
///   xcodebuild test -scheme StockTracker \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:StockTrackerUITests/DesignTour/testTour
final class DesignTour: XCTestCase {

    /// Where the PNGs land: the test runner's own tmp. The runner is sandboxed,
    /// so an absolute path like /tmp silently fails — pull them off the host with
    ///   xcrun simctl get_app_container booted com.aistockstudio.uitests.xctrunner data
    private var outDir: String {
        NSTemporaryDirectory() + "design-tour"
    }

    private var baseURL: String {
        ProcessInfo.processInfo.environment["TOUR_API"] ?? "http://127.0.0.1:8099"
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        // Belt and braces: also attach, so the shots survive in the .xcresult
        // even if the container is cleaned up between runs.
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Argument domain wins over the stored default, so the tour always hits
        // the local demo backend without touching the user's saved setting.
        app.launchArguments += ["-api.baseURL", baseURL]
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

    /// The splash only shows for ~1.2s, which is too tight to race with a
    /// screenshot reliably — assert on the label instead.
    func testSplashShowsVersion() throws {
        let app = makeApp()
        app.launch()
        let version = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Version'")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 6),
                      "No version label on the splash screen")
        print("SPLASH_VERSION_LABEL=\(version.label)")
        snap(app, "splash-version")
    }

    /// Settings, reached from the Overview toolbar.
    func testSettings() throws {
        let app = makeApp()
        app.launch()
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        sleep(3)
        let gear = app.buttons.matching(identifier: "gearshape.fill").firstMatch
        if gear.waitForExistence(timeout: 8), gear.isHittable {
            gear.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        sleep(3)
        snap(app, "settings-top")
        // Open the folded developer section too.
        let advanced = app.staticTexts["ADVANCED"].firstMatch
        if advanced.waitForExistence(timeout: 5) {
            advanced.tap()
            sleep(1)
            snap(app, "settings-advanced")
        }
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
    }

    func testTour() throws {
        let app = makeApp()
        app.launch()

        // ---- Overview -----------------------------------------------------
        // Wait for real data, not the cached/empty first paint.
        _ = app.staticTexts["Taiwan"].firstMatch.waitForExistence(timeout: 120)
        sleep(8)
        snap(app, "01-overview-top")
        app.swipeUp()
        sleep(1)
        snap(app, "02-overview-scrolled")
        app.swipeUp()
        sleep(1)
        snap(app, "03-overview-bottom")
        app.swipeDown()
        app.swipeDown()
        sleep(1)

        // ---- Taiwan dashboard ---------------------------------------------
        let taiwan = app.staticTexts["Taiwan"].firstMatch
        if taiwan.waitForExistence(timeout: 30) {
            taiwan.tap()
            sleep(10)  // live quotes + value history
            snap(app, "10-dashboard-top")
            for i in 1...4 {
                app.swipeUp()
                sleep(2)
                snap(app, "1\(i)-dashboard-scroll\(i)")
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
                app.navigationBars.buttons.firstMatch.tap()
                sleep(2)
            }

            // ---- Trades / Dividends ---------------------------------------
            for (label, tag) in [("Trades", "30-trades"), ("Dividends", "40-dividends")] {
                var tries = 0
                while !app.buttons[label].firstMatch.isHittable && tries < 8 {
                    app.swipeDown(); tries += 1
                }
                if tapAny(app, [label]) != nil {
                    sleep(4)
                    snap(app, tag)
                    app.swipeUp(); sleep(1); snap(app, "\(tag)-scrolled")
                }
            }
        }

        // ---- Assistant ------------------------------------------------------
        if tapAny(app, ["Assistant"], timeout: 20) != nil {
            sleep(5)
            snap(app, "50-assistant")
        }

        // ---- Settings -------------------------------------------------------
        if tapAny(app, ["Portfolio"], timeout: 20) != nil { sleep(2) }
        var settled = 0
        while !app.buttons["Settings"].firstMatch.exists && settled < 6 {
            app.swipeDown(); settled += 1
        }
        if tapAny(app, ["Settings"], timeout: 15) != nil {
            sleep(3)
            snap(app, "60-settings")
        }
    }
}
