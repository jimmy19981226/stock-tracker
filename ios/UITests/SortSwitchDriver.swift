import XCTest

/// Not a real test — a scripted driver that walks to a market dashboard,
/// switches the holdings sort, and saves screenshots to /tmp so the CLI can
/// inspect what the UI actually does.
final class SortSwitchDriver: XCTestCase {

    private func snap(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "/tmp/sortswitch-\(name).png"))
    }

    func testSwitchHoldingsSort() throws {
        let app = XCUIApplication()
        app.launch()

        // Overview → Taiwan dashboard.
        let taiwan = app.staticTexts["Taiwan"].firstMatch
        XCTAssertTrue(taiwan.waitForExistence(timeout: 30), "Taiwan card not found")
        taiwan.tap()

        // Wait for the holdings section, then scroll it into view.
        let sortButton = app.buttons["Market value"].firstMatch
        XCTAssertTrue(sortButton.waitForExistence(timeout: 30), "sort button not found")
        var tries = 0
        while !sortButton.isHittable && tries < 12 {
            app.swipeUp()
            tries += 1
        }
        snap(app, "1-before")

        sortButton.tap()
        sleep(1)
        snap(app, "2-menu")

        let todays = app.buttons["Today's move"].firstMatch
        XCTAssertTrue(todays.waitForExistence(timeout: 10), "menu item not found")
        todays.tap()

        // Capture mid-animation and settled states.
        usleep(200_000)
        snap(app, "3-mid-animation")
        sleep(2)
        snap(app, "4-after")

        // Switch again to Gain % to see a second reorder.
        let sortButton2 = app.buttons["Today's move"].firstMatch
        if sortButton2.waitForExistence(timeout: 5) {
            sortButton2.tap()
            sleep(1)
            let gain = app.buttons["Gain %"].firstMatch
            if gain.waitForExistence(timeout: 5) {
                gain.tap()
                usleep(200_000)
                snap(app, "5-mid-animation-2")
                sleep(2)
                snap(app, "6-after-2")
            }
        }

        // Now scroll deep into the list and switch sort from there — the
        // reorder animation over off-screen rows is where glitches hide.
        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        snap(app, "7-deep-before")
        let sortButton3 = app.buttons["Gain %"].firstMatch
        guard sortButton3.waitForExistence(timeout: 5) else { return }
        var scrollBack = 0
        while !sortButton3.isHittable && scrollBack < 10 {
            app.swipeDown()
            scrollBack += 1
        }
        // Scroll down again so holdings fill the screen but the pinned-ish
        // header is reachable; if the button scrolled away we just re-tap
        // after the swipes above.
        sortButton3.tap()
        sleep(1)
        let mv = app.buttons["Market value"].firstMatch
        guard mv.waitForExistence(timeout: 5) else { return }
        mv.tap()
        // Burst-capture the animation.
        for i in 0..<6 {
            usleep(120_000)
            snap(app, "8-burst-\(i)")
        }
        sleep(1)
        snap(app, "9-final")

        // Hit-target check: switch to Gain %, then immediately tap the row
        // that shows "2382" (Quanta, 2nd by gain). If navigation opens a
        // different ticker, hit targets didn't move with the rows.
        let sb = app.buttons["Market value"].firstMatch
        guard sb.waitForExistence(timeout: 5) else { return }
        sb.tap()
        sleep(1)
        let gain2 = app.buttons["Gain %"].firstMatch
        guard gain2.waitForExistence(timeout: 5) else { return }
        gain2.tap()
        usleep(600_000) // mid/just-after animation, like an impatient user
        let quanta = app.staticTexts["2382"].firstMatch
        if quanta.waitForExistence(timeout: 5) {
            quanta.tap()
            // Wait for the loaded content (position card), not the skeleton.
            _ = app.staticTexts["Your position"].waitForExistence(timeout: 45)
            sleep(1)
            snap(app, "10-detail-after-sort")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        // Direction toggle: Gain % low-to-high should put the worst gainer
        // on top.
        let sb2 = app.buttons["Gain %"].firstMatch
        guard sb2.waitForExistence(timeout: 5) else { return }
        var back = 0
        while !sb2.isHittable && back < 10 {
            app.swipeDown()
            back += 1
        }
        sb2.tap()
        sleep(1)
        let lowToHigh = app.buttons["Low to high"].firstMatch
        guard lowToHigh.waitForExistence(timeout: 5) else { return }
        lowToHigh.tap()
        sleep(2)
        snap(app, "11-ascending")
    }
}
