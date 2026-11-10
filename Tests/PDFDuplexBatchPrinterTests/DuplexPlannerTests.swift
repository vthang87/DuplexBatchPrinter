import XCTest
@testable import PDFDuplexBatchPrinter

final class DuplexPlannerTests: XCTestCase {
    func testNewProfileDefaultsToReverseOddAndNormalEven() {
        let profile = PrinterProfile(printerQueue: "test")
        XCTAssertEqual(profile.oddOrder, .reversed)
        XCTAssertEqual(profile.evenOrder, .normal)
    }

    func testOddDocumentPadsThenReversesEvenPass() {
        let profile = PrinterProfile(printerQueue: "test", oddOrder: .normal, evenOrder: .reversed)
        let plan = DuplexPlanner.plan(pageCount: 5, profile: profile)

        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [1, 3, 5])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 4, 2])
    }

    func testDefaultOrderForThreePageDocumentFeedsBlankPageLast() {
        let plan = DuplexPlanner.plan(pageCount: 3, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [2, nil])
    }

    func testDefaultOrderForFivePageDocumentFeedsBlankPageLast() {
        let plan = DuplexPlanner.plan(pageCount: 5, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [5, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [2, 4, nil])
    }

    func testDefaultNinePageRuleMatchesPhysicalPrintOrder() {
        let plan = DuplexPlanner.plan(pageCount: 9, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [9, 7, 5, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [2, 4, 6, 8, nil])
    }

    func testSinglePageDocumentFeedsOneBlankEvenPage() {
        let plan = DuplexPlanner.plan(pageCount: 1, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil])
    }

    func testOrdersAreIndependentlyConfigurable() {
        let profile = PrinterProfile(printerQueue: "test", oddOrder: .reversed, evenOrder: .normal)
        let plan = DuplexPlanner.plan(pageCount: 6, profile: profile)

        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [5, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [2, 4, 6])
    }

    func testEmptyDocumentProducesEmptyPlan() {
        let profile = PrinterProfile(printerQueue: "test")
        XCTAssertEqual(DuplexPlanner.plan(pageCount: 0, profile: profile), DuplexPlan(oddPass: [], evenPass: []))
    }
}
