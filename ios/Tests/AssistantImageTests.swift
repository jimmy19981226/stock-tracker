import UIKit
import XCTest
@testable import StockTracker

@MainActor
final class AssistantImageTests: XCTestCase {
    func testLargeAttachmentUsesImagePixelsInsteadOfRetinaDisplayPoints() throws {
        let viewModel = AssistantViewModel()
        viewModel.input = "Compare this screenshot with my records"
        viewModel.attachImage(try imageData(size: CGSize(width: 2400, height: 1200)))

        let image = try XCTUnwrap(viewModel.pendingAttachment?.cgImage)
        XCTAssertEqual(image.width, 2200)
        XCTAssertEqual(image.height, 1100)
        XCTAssertEqual(viewModel.input, "Compare this screenshot with my records")
        XCTAssertTrue(viewModel.canSend)
        XCTAssertNil(viewModel.error)
    }

    func testSmallAttachmentIsNotUpscaledOnRetinaDevices() throws {
        let viewModel = AssistantViewModel()
        viewModel.attachImage(try imageData(size: CGSize(width: 600, height: 400)))

        let image = try XCTUnwrap(viewModel.pendingAttachment?.cgImage)
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 400)
        XCTAssertTrue(viewModel.canSend, "An image can be sent without a text message")
    }

    private func imageData(size: CGSize) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            "US$1,234.56".draw(at: CGPoint(x: 20, y: 20), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black,
            ])
        }
        return try XCTUnwrap(image.pngData())
    }
}
