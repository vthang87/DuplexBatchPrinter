import XCTest
@testable import PDFDuplexBatchPrinter

final class FlipNotificationServiceTests: XCTestCase {
    func testFlipNotificationContainsFileAndInstruction() {
        let content = FlipNotificationService.makeContent(file: "lesson.pdf")
        XCTAssertEqual(content.title, "Đã in xong mặt lẻ")
        XCTAssertEqual(content.subtitle, "lesson.pdf")
        XCTAssertTrue(content.body.contains("lật"))
        XCTAssertEqual(content.categoryIdentifier, "PAPER_FLIP_REQUIRED")
        XCTAssertNotNil(content.sound)
    }
}
