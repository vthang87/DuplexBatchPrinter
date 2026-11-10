import Foundation
import XCTest
@testable import PDFDuplexBatchPrinter

@MainActor
final class AppModelTests: XCTestCase {
    func testRestoresSelectedProfileAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "AppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileURL = directory.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: profileURL, userDefaults: defaults)
        let first = PrinterProfile(name: "First", printerQueue: "printer")
        let second = PrinterProfile(name: "Second", printerQueue: "printer")
        try store.save(first)
        try store.save(second)

        let model = makeModel(directory: directory, profileURL: profileURL, defaults: defaults)
        await model.reloadPrinters()
        XCTAssertEqual(model.selectedProfileID, first.id)
        model.selectProfile(id: second.id)

        let relaunched = makeModel(directory: directory, profileURL: profileURL, defaults: defaults)
        await relaunched.reloadPrinters()
        XCTAssertEqual(relaunched.selectedPrinter, "printer")
        XCTAssertEqual(relaunched.selectedProfileID, second.id)
        XCTAssertEqual(relaunched.editableProfile.name, "Second")
    }

    private func makeModel(directory: URL, profileURL: URL, defaults: UserDefaults) -> AppModel {
        AppModel(
            profileStore: ProfileStore(fileURL: profileURL, userDefaults: defaults),
            printService: StubPrinterListService(),
            queueCacheStore: QueueCacheStore(fileURL: directory.appendingPathComponent("pdf-queue.json")),
            imageQueueCacheStore: ImageQueueCacheStore(fileURL: directory.appendingPathComponent("image-queue.json")),
            userDefaults: defaults
        )
    }
}

private actor StubPrinterListService: PrintServicing {
    func listPrinters() async throws -> [PrinterDescriptor] {
        [PrinterDescriptor(queueName: "printer", displayName: "printer", isDefault: true)]
    }

    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob {
        SubmittedPrintJob(id: "stub-1", printer: printer, title: title)
    }

    func waitUntilFinished(job: SubmittedPrintJob) async throws {}
    func cancel(job: SubmittedPrintJob) async {}
}
