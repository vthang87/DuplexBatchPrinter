import XCTest
@testable import PDFDuplexBatchPrinter

final class DuplexPlannerTests: XCTestCase {
    func testNewProfileDefaultsToReverseOddAndReverseEven() {
        let profile = PrinterProfile(printerQueue: "test")
        XCTAssertEqual(profile.oddOrder, .reversed)
        XCTAssertEqual(profile.evenOrder, .reversed)
    }

    func testOddDocumentPadsThenReversesEvenPass() {
        let profile = PrinterProfile(printerQueue: "test", oddOrder: .normal, evenOrder: .reversed)
        let plan = DuplexPlanner.plan(pageCount: 5, profile: profile)

        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [1, 3, 5])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 4, 2])
    }

    func testDefaultOrderForThreePageDocumentBacksLastSheetWithBlankFirst() {
        let plan = DuplexPlanner.plan(pageCount: 3, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 2])
    }

    func testDefaultOrderForFivePageDocumentBacksLastSheetWithBlankFirst() {
        let plan = DuplexPlanner.plan(pageCount: 5, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [5, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 4, 2])
    }

    /// After the reversed odd pass the whole stack is turned over without re-sorting,
    /// so the sheet carrying page 9 feeds first and must receive page 10.
    func testDefaultNinePageOrderNeedsNoResortingAfterTurningStackOver() {
        let plan = DuplexPlanner.plan(pageCount: 9, profile: PrinterProfile(printerQueue: "test"))
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [9, 7, 5, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 8, 6, 4, 2])

        let feedOrderAfterTurningOver = plan.oddPass.map(\.sourcePage)
        let backs = plan.evenPass.map(\.sourcePage)
        for (front, back) in zip(feedOrderAfterTurningOver, backs) {
            XCTAssertEqual(back ?? 10, (front ?? 0) + 1)
        }
    }

    /// Simulates the paper path for every length: each printed sheet lands on top of
    /// the output stack, the whole stack is turned over, and the tray feeds the top
    /// sheet first. Every sheet must get the page after its front, and only the last
    /// sheet of an odd-length document gets the blank padding page.
    func testDefaultOrderPairsEverySheetWithoutResortingForOddAndEvenLengths() {
        for pageCount in 2...20 {
            let plan = DuplexPlanner.plan(pageCount: pageCount, profile: PrinterProfile(printerQueue: "test"))

            var outputStack: [Int?] = []
            for page in plan.oddPass { outputStack.insert(page.sourcePage, at: 0) }
            let feedOrder = Array(outputStack.reversed())

            XCTAssertEqual(feedOrder.count, plan.evenPass.count, "\(pageCount) pages")
            for (front, back) in zip(feedOrder, plan.evenPass.map(\.sourcePage)) {
                let frontPage = try? XCTUnwrap(front, "\(pageCount) pages: odd pass must not contain blanks")
                if let back {
                    XCTAssertEqual(back, (frontPage ?? 0) + 1, "\(pageCount) pages")
                } else {
                    XCTAssertTrue(pageCount % 2 == 1 && frontPage == pageCount, "\(pageCount) pages: blank only behind the last page")
                }
            }
            XCTAssertEqual(plan.evenPass.filter { $0.sourcePage == nil }.count, pageCount % 2, "\(pageCount) pages")
        }
    }

    func testCombinedPlanStartsEveryFileOnANewSheet() {
        let plan = DuplexPlanner.plan(pageCounts: [3, 2, 1], profile: PrinterProfile(printerQueue: "test"))
        // Merged pages: a = 1...3, b = 4...5, c = 6. Sheets: (1,2) (3,blank) (4,5) (6,blank).
        XCTAssertEqual(plan.oddPass.map(\.sourcePage), [6, 4, 3, 1])
        XCTAssertEqual(plan.evenPass.map(\.sourcePage), [nil, 5, nil, 2])
    }

    func testCombinedPlanPairsEverySheetWithoutResortingAndNeverSharesASheet() {
        let lengthSets: [[Int]] = [[1, 1], [2, 3], [3, 3, 3], [5, 1, 4, 2], [7, 8, 1, 2, 9]]
        for pageCounts in lengthSets {
            let plan = DuplexPlanner.plan(pageCounts: pageCounts, profile: PrinterProfile(printerQueue: "test"))

            var fileOfPage: [Int: Int] = [:]
            var offset = 0
            for (file, count) in pageCounts.enumerated() {
                for page in 1...count { fileOfPage[offset + page] = file }
                offset += count
            }

            var outputStack: [Int?] = []
            for page in plan.oddPass { outputStack.insert(page.sourcePage, at: 0) }
            let feedOrder = Array(outputStack.reversed())

            XCTAssertEqual(feedOrder.count, plan.evenPass.count, "\(pageCounts)")
            for (front, back) in zip(feedOrder, plan.evenPass.map(\.sourcePage)) {
                guard let front else { return XCTFail("\(pageCounts): odd pass must not contain blanks") }
                if let back {
                    XCTAssertEqual(back, front + 1, "\(pageCounts)")
                    XCTAssertEqual(fileOfPage[back], fileOfPage[front], "\(pageCounts): a sheet must not mix files")
                } else {
                    let file = fileOfPage[front]!
                    XCTAssertTrue(fileOfPage[front + 1] != file, "\(pageCounts): blank only behind a file's last page")
                }
            }
            XCTAssertEqual(
                plan.evenPass.filter { $0.sourcePage == nil }.count,
                pageCounts.filter { !$0.isMultiple(of: 2) }.count,
                "\(pageCounts)"
            )
        }
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
