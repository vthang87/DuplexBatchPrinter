import XCTest
@testable import PDFDuplexBatchPrinter

final class CUPSServiceTests: XCTestCase {
    func testParsesSubmittedJobID() {
        XCTAssertEqual(
            CUPSService.parseSubmittedJobID("request id is Brother_HL-42 (1 file(s))"),
            "Brother_HL-42"
        )
    }

    func testRejectsResponseWithoutJobID() {
        XCTAssertNil(CUPSService.parseSubmittedJobID("printer accepted the document"))
    }

    func testParsesDefaultPrinter() {
        XCTAssertEqual(CUPSService.parseDefaultPrinter("system default destination: Office_Printer\n"), "Office_Printer")
    }

    func testJobStatusQueriesUsePrinterQueueNotRequestID() {
        XCTAssertEqual(
            CUPSService.jobStatusArguments(printer: "EPSON_L1250_Series", completed: false),
            ["-W", "not-completed", "-o", "EPSON_L1250_Series"]
        )
        XCTAssertEqual(
            CUPSService.jobStatusArguments(printer: "EPSON_L1250_Series", completed: true),
            ["-W", "completed", "-o", "EPSON_L1250_Series"]
        )
    }

    func testFindsExactJobIDInPrinterQueueOutput() {
        let output = """
        EPSON_L1250_Series-1169 user 2048 Nov 3 16:40
        EPSON_L1250_Series-1170 user 4096 Nov 3 16:41
        """
        XCTAssertTrue(CUPSService.containsJob(output, id: "EPSON_L1250_Series-1169"))
        XCTAssertFalse(CUPSService.containsJob(output, id: "EPSON_L1250_Series-116"))
    }

    func testDetectsEpsonSkipBlankPageControl() {
        let options = """
        PageSize/Media Size: *A4 Letter
        EPIJ_BSSv/Skip Blank Page: *0 1
        """
        XCTAssertTrue(CUPSService.supportsEpsonSkipBlankControl(options))
        XCTAssertFalse(CUPSService.supportsEpsonSkipBlankControl("PageSize/Media Size: *A4 Letter"))
    }
}
