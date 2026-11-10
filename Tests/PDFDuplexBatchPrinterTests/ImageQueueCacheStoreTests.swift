import Foundation
import XCTest
@testable import PDFDuplexBatchPrinter

final class ImageQueueCacheStoreTests: XCTestCase {
    func testRestoresImageListOrderAndResetsStatuses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.png")
        let secondURL = directory.appendingPathComponent("second.jpg")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let store = ImageQueueCacheStore(fileURL: directory.appendingPathComponent("images.json"))
        try store.save([
            ImageQueueItem(url: secondURL, status: .completed),
            ImageQueueItem(url: firstURL, status: .failed)
        ])

        let restored = try store.load()
        XCTAssertEqual(restored.map(\.name), ["second.jpg", "first.png"])
        XCTAssertEqual(restored.map(\.status), [.ready, .ready])
    }

    func testKeepsMissingImageVisibleAfterRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImageQueueCacheStore(fileURL: directory.appendingPathComponent("images.json"))
        try store.save([ImageQueueItem(url: directory.appendingPathComponent("missing.png"))])

        let restored = try store.load()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].status, .missing)
    }
}
