import XCTest
@testable import StockTracker

final class MarkdownTextTests: XCTestCase {
    func testFinancialTablePreservesEscapedPipesAndFullAmounts() {
        let blocks = MarkdownText.parse("| Position | Profit |\n| --- | ---: |\n| Tech \\| Taiwan | NT$1,234,567.89 |")
        XCTAssertEqual(blocks, [.table(["Position", "Profit"], [["Tech | Taiwan", "NT$1,234,567.89"]])])
    }

    func testTableWithoutOutsidePipesAndUnevenRows() {
        let blocks = MarkdownText.parse("Market | Profit | Return\n--- | ---: | ---:\nTW | NT$13,389 | 2.5%\nUS | Unavailable\nUS | 10 | 2% | ignored")
        XCTAssertEqual(blocks, [.table(["Market", "Profit", "Return"], [
            ["TW", "NT$13,389", "2.5%"], ["US", "Unavailable", ""], ["US", "10", "2%"]
        ])])
    }

    func testCodePreservesLiteralLongMarkdownLinks() {
        let code = "[https://example.com/a/very/long/path](https://example.com/a/very/long/path)"
        XCTAssertEqual(MarkdownText.parse("```text\n\(code)\n```"), [.code(code)])
    }

    func testIncompleteStreamKeepsContentUntilTableSeparatorArrives() {
        XCTAssertEqual(MarkdownText.parse("| Market | Profit |\n| --"), [.paragraph(["| Market | Profit |", "| --"])])
        XCTAssertEqual(MarkdownText.parse("| Market | Profit |\n| --- | --- |\n| TW |"), [.table(["Market", "Profit"], [["TW", ""]])])
    }

    func testParagraphPipeIsNotMistakenForATable() {
        XCTAssertEqual(MarkdownText.parse("TW | US\n---\nSummary"), [.paragraph(["TW | US"]), .rule, .paragraph(["Summary"])])
    }

    func testHeadingsListsAndQuotesRemainSeparateBlocks() {
        XCTAssertEqual(MarkdownText.parse("## Summary\n\n- **TW**\n- US\n\n1. Review\n2. Confirm\n\n> Updated today"), [
            .heading(2, "Summary"), .bullet(["**TW**", "US"]), .ordered(["Review", "Confirm"]), .quote(["Updated today"])
        ])
    }

    func testSourceLinkKeepsItsDestination() {
        let url = "https://example.com/very/long/path?source=annual-report"
        XCTAssertEqual(MarkdownText.shortenLinkLabels("[\(url)](\(url))"), "[example.com](\(url))")
    }
}
