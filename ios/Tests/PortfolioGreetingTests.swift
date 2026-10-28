import XCTest
@testable import StockTracker

final class PortfolioGreetingTests: XCTestCase {
    func testLocalHourBoundaries() {
        for hour in [0, 4, 17, 21, 23] {
            XCTAssertEqual(PortfolioGreeting.text(hour: hour, firstName: "James"), "Good evening, James")
        }
        for hour in [5, 11] {
            XCTAssertEqual(PortfolioGreeting.text(hour: hour, firstName: "James"), "Good morning, James")
        }
        for hour in [12, 16] {
            XCTAssertEqual(PortfolioGreeting.text(hour: hour, firstName: "James"), "Good afternoon, James")
        }
    }

    func testProviderGivenNameAndExistingProfileFallback() {
        let user = AuthUser(name: "Chen James", email: "demo@example.com", picture: nil,
                            provider: "google", givenName: " James ")
        XCTAssertEqual(user.firstName, "James")
        let old = AuthUser(name: "  James\tChen  ", email: "demo@example.com", picture: nil, provider: "google")
        XCTAssertEqual(old.firstName, "James")
        let localized = AuthUser(name: "陳大明", email: "demo@example.com", picture: nil,
                                 provider: "google", givenName: "大明")
        XCTAssertEqual(localized.firstName, "大明")
    }

    func testGuestAndMissingNamesDoNotExposeEmailOrPlaceholder() {
        for user in [AuthUser(name: "Guest", email: "", picture: nil, provider: "guest"),
                     AuthUser(name: "demo@example.com", email: "demo@example.com", picture: nil, provider: "google"),
                     AuthUser(name: "Signed in", email: "", picture: nil, provider: "google"),
                     AuthUser(name: " ", email: "", picture: nil, provider: "google")] {
            XCTAssertNil(user.firstName)
            XCTAssertEqual(PortfolioGreeting.text(hour: 9, firstName: user.firstName), "Good morning")
        }
    }

    func testOlderCachedProfileStillDecodes() throws {
        let data = Data(#"{"name":"James Chen","email":"demo@example.com","provider":"google"}"#.utf8)
        let user = try JSONDecoder().decode(AuthUser.self, from: data)
        XCTAssertNil(user.givenName)
        XCTAssertEqual(user.firstName, "James")
    }
}
