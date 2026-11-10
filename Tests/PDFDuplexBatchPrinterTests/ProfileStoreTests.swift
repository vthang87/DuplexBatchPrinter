import Foundation
import XCTest
@testable import PDFDuplexBatchPrinter

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testMigratesOnlyOldDefaultProfilePageOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileURL = directory.appendingPathComponent("profiles.json")
        let oldDefault = PrinterProfile(
            name: "Default profile",
            printerQueue: "printer",
            oddOrder: .normal,
            evenOrder: .reversed
        )
        let custom = PrinterProfile(
            name: "Custom calibrated profile",
            printerQueue: "printer",
            oddOrder: .normal,
            evenOrder: .reversed
        )
        try JSONEncoder().encode([oldDefault, custom]).write(to: profileURL)

        let suiteName = "ProfileStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProfileStore(fileURL: profileURL, userDefaults: defaults)
        XCTAssertEqual(store.profiles[0].oddOrder, .reversed)
        XCTAssertEqual(store.profiles[0].evenOrder, .normal)
        XCTAssertEqual(store.profiles[1].oddOrder, .normal)
        XCTAssertEqual(store.profiles[1].evenOrder, .reversed)
    }
}
