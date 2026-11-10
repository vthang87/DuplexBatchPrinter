import AppKit
import PDFKit
import XCTest
@testable import PDFDuplexBatchPrinter

@MainActor
final class BatchCoordinatorTests: XCTestCase {
    func testImageListSingleSidedUpdatesEachPageAsItsJobCompletes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try [makeImageItem(named: "1.png", in: directory), makeImageItem(named: "2.png", in: directory)]
        let service = ControlledPrintService()
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[ImageQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.startImages(queue: box, mode: .singleSided, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { queue.map(\.status) == [.printingOdd, .ready] }
        let firstTitles = await service.submittedTitles()
        XCTAssertEqual(firstTitles, ["1.png — All pages"])

        await service.completeNextJob()
        try await waitUntil { queue.map(\.status) == [.completed, .printingOdd] }
        let secondTitles = await service.submittedTitles()
        XCTAssertEqual(secondTitles, ["1.png — All pages", "2.png — All pages"])

        await service.completeNextJob()
        try await waitUntil { coordinator.state == .completed }
        XCTAssertEqual(queue.map(\.status), [.completed, .completed])
    }

    func testSingleSidedImageRetryResumesAtFailedImageWithoutReprintingCompletedOnes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try ["1.png", "2.png", "3.png"].map { try makeImageItem(named: $0, in: directory) }
        let service = FailingOncePrintService(failingTitle: "2.png — All pages")
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[ImageQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.startImages(queue: box, mode: .singleSided, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state.isPausedOnError }
        XCTAssertEqual(queue.map(\.status), [.completed, .failed, .ready])

        coordinator.resolveError(.retry)
        try await waitUntil { coordinator.state == .completed }
        let titles = await service.submittedTitles()
        XCTAssertEqual(titles, [
            "1.png — All pages",
            "2.png — All pages",
            "2.png — All pages",
            "3.png — All pages"
        ])
        XCTAssertEqual(queue.map(\.status), [.completed, .completed, .completed])
    }

    func testSingleSidedImageSkipContinuesWithNextImage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try ["1.png", "2.png", "3.png"].map { try makeImageItem(named: $0, in: directory) }
        let service = FailingOncePrintService(failingTitle: "2.png — All pages")
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[ImageQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.startImages(queue: box, mode: .singleSided, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state.isPausedOnError }

        coordinator.resolveError(.skip)
        try await waitUntil { coordinator.state == .completed }
        let titles = await service.submittedTitles()
        XCTAssertEqual(titles, ["1.png — All pages", "2.png — All pages", "3.png — All pages"])
        XCTAssertEqual(queue.map(\.status), [.completed, .skipped, .completed])
    }

    func testImageListDoubleSidedWaitsForFlipBetweenPasses() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try [
            makeImageItem(named: "1.png", in: directory),
            makeImageItem(named: "2.png", in: directory),
            makeImageItem(named: "3.png", in: directory)
        ]
        let service = RecordingPrintService()
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[ImageQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.startImages(queue: box, mode: .doubleSided, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state.isWaitingForFlip(file: "Image list (3)") }
        let oddTitles = await service.submittedTitles()
        XCTAssertEqual(oddTitles, ["Image list (3) — Odd pages"])

        coordinator.confirmPaperFlipped()
        try await waitUntil { coordinator.state == .completed }
        let finalTitles = await service.submittedTitles()
        XCTAssertEqual(finalTitles, [
            "Image list (3) — Odd pages",
            "Image list (3) — Even pages"
        ])
        XCTAssertEqual(queue.map(\.status), [.completed, .completed, .completed])
    }

    func testSingleImageDoubleSidedSkipsFlipAndBlankJob() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = try [makeImageItem(named: "only.png", in: directory)]
        let service = RecordingPrintService()
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[ImageQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.startImages(queue: box, mode: .doubleSided, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state == .completed }

        let titles = await service.submittedTitles()
        XCTAssertEqual(titles, ["Image list (1) — Odd pages"])
        XCTAssertEqual(queue[0].status, .completed)
    }

    func testCompletesOddFlipEvenBeforeStartingNextFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = try makePDF(named: "first.pdf", in: directory)
        let secondURL = try makePDF(named: "second.pdf", in: directory)
        var queue = [
            PDFQueueItem(url: firstURL, pageCount: 2),
            PDFQueueItem(url: secondURL, pageCount: 2)
        ]
        let service = RecordingPrintService()
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[PDFQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.start(queue: box, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state.isWaitingForFlip(file: "first.pdf") }
        let afterFirstOdd = await service.submittedTitles()
        XCTAssertEqual(afterFirstOdd, ["first.pdf — Odd pages"])

        coordinator.confirmPaperFlipped()
        try await waitUntil { coordinator.state.isWaitingForFlip(file: "second.pdf") }
        let afterSecondOdd = await service.submittedTitles()
        XCTAssertEqual(afterSecondOdd, [
            "first.pdf — Odd pages",
            "first.pdf — Even pages",
            "second.pdf — Odd pages"
        ])

        coordinator.confirmPaperFlipped()
        try await waitUntil { coordinator.state == .completed }
        let finalTitles = await service.submittedTitles()
        XCTAssertEqual(finalTitles, [
            "first.pdf — Odd pages",
            "first.pdf — Even pages",
            "second.pdf — Odd pages",
            "second.pdf — Even pages"
        ])
        XCTAssertEqual(queue.map(\.status), [.completed, .completed])
    }

    func testSinglePageFileSkipsFlipAndBlankEvenJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = try makePDF(named: "single.pdf", pageCount: 1, in: directory)
        var queue = [PDFQueueItem(url: sourceURL, pageCount: 1)]
        let service = RecordingPrintService()
        let coordinator = BatchCoordinator(printService: service)
        let box = BindingBox<[PDFQueueItem]>(get: { queue }, set: { queue = $0 })

        coordinator.start(queue: box, profile: PrinterProfile(printerQueue: "test"))
        try await waitUntil { coordinator.state == .completed }

        let titles = await service.submittedTitles()
        XCTAssertEqual(titles, ["single.pdf — Odd pages"])
        XCTAssertEqual(queue[0].status, .completed)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("Timed out waiting for batch state"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePDF(named name: String, pageCount: Int = 2, in directory: URL) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 200, height: 300))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            "\(index + 1)".draw(at: NSPoint(x: 90, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
            image.unlockFocus()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImageItem(named name: String, in directory: URL) throws -> ImageQueueItem {
        let image = NSImage(size: NSSize(width: 100, height: 150))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return ImageQueueItem(url: url)
    }
}

private actor RecordingPrintService: PrintServicing {
    private var titles: [String] = []

    func listPrinters() async throws -> [PrinterDescriptor] { [] }

    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob {
        titles.append(title)
        return SubmittedPrintJob(id: "test-\(titles.count)", printer: printer, title: title)
    }

    func waitUntilFinished(job: SubmittedPrintJob) async throws {}
    func cancel(job: SubmittedPrintJob) async {}
    func submittedTitles() -> [String] { titles }
}

private actor ControlledPrintService: PrintServicing {
    private var titles: [String] = []
    private var completedJobCount = 0

    func listPrinters() async throws -> [PrinterDescriptor] { [] }

    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob {
        titles.append(title)
        return SubmittedPrintJob(id: "controlled-\(titles.count)", printer: printer, title: title)
    }

    func waitUntilFinished(job: SubmittedPrintJob) async throws {
        guard let number = Int(job.id.split(separator: "-").last ?? "") else { return }
        while completedJobCount < number {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func cancel(job: SubmittedPrintJob) async {}
    func submittedTitles() -> [String] { titles }
    func completeNextJob() { completedJobCount += 1 }
}

private actor FailingOncePrintService: PrintServicing {
    struct SimulatedFailure: Error {}

    private let failingTitle: String
    private var hasFailed = false
    private var titles: [String] = []

    init(failingTitle: String) {
        self.failingTitle = failingTitle
    }

    func listPrinters() async throws -> [PrinterDescriptor] { [] }

    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob {
        titles.append(title)
        if title == failingTitle && !hasFailed {
            hasFailed = true
            throw SimulatedFailure()
        }
        return SubmittedPrintJob(id: "failing-once-\(titles.count)", printer: printer, title: title)
    }

    func waitUntilFinished(job: SubmittedPrintJob) async throws {}
    func cancel(job: SubmittedPrintJob) async {}
    func submittedTitles() -> [String] { titles }
}

private extension BatchState {
    func isWaitingForFlip(file: String) -> Bool {
        guard case .waitingForFlip(let current, _) = self else { return false }
        return current == file
    }

    var isPausedOnError: Bool {
        guard case .pausedOnError = self else { return false }
        return true
    }
}
