import XCTest
@testable import PDFDuplexBatchPrinter

final class FlipNotificationServiceTests: XCTestCase {
    override func tearDown() {
        L10n.language = .system
        super.tearDown()
    }

    func testFlipNotificationContainsFileAndInstruction() {
        L10n.language = .vietnamese
        let content = FlipNotificationService.makeContent(file: "lesson.pdf")
        XCTAssertEqual(content.title, "Đã in xong mặt lẻ")
        XCTAssertEqual(content.subtitle, "lesson.pdf")
        XCTAssertTrue(content.body.contains("úp ngược"))
        XCTAssertEqual(content.categoryIdentifier, "PAPER_FLIP_REQUIRED")
        XCTAssertNotNil(content.sound)
    }

    func testFlipNotificationFollowsSelectedLanguage() {
        L10n.language = .english
        XCTAssertEqual(FlipNotificationService.makeContent(file: "lesson.pdf").title, "Odd pages finished")
    }
}
