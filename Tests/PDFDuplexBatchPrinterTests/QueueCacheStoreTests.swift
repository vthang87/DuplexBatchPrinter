import Foundation
import XCTest
@testable import PDFDuplexBatchPrinter

final class QueueCacheStoreTests: XCTestCase {
    func testRestoresQueueOrderAcrossStoreInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let cacheURL = directory.appendingPathComponent("queue.json")

        let writer = QueueCacheStore(fileURL: cacheURL)
        try writer.save([
            PDFQueueItem(url: secondURL, pageCount: 7),
            PDFQueueItem(url: firstURL, pageCount: 3)
        ])

        let reader = QueueCacheStore(fileURL: cacheURL)
        let restored = try reader.load()
        XCTAssertEqual(restored.map(\.name), ["second.pdf", "first.pdf"])
        XCTAssertEqual(restored.map(\.pageCount), [7, 3])
        XCTAssertEqual(restored.map(\.status), [.ready, .ready])
    }

    func testKeepsMissingFileInQueueInsteadOfDroppingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingURL = directory.appendingPathComponent("missing.pdf")
        let store = QueueCacheStore(fileURL: directory.appendingPathComponent("queue.json"))
        try store.save([PDFQueueItem(url: missingURL, pageCount: 4)])

        let restored = try store.load()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].name, "missing.pdf")
        XCTAssertEqual(restored[0].status, .missing)
    }

    func testMigratesLegacyUserDefaultsDataToJSONCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("legacy.pdf")
        try Data("legacy".utf8).write(to: sourceURL)
        let legacyData = try JSONEncoder().encode([PDFQueueItem(url: sourceURL, pageCount: 2)])
        let cacheURL = directory.appendingPathComponent("queue.json")
        let store = QueueCacheStore(fileURL: cacheURL)

        let restored = try store.load(legacyData: legacyData)
        XCTAssertEqual(restored.map(\.name), ["legacy.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
