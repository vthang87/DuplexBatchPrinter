import Foundation
import XCTest
@testable import PDFDuplexBatchPrinter

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.language = .system
        super.tearDown()
    }

    func testEnglishAndVietnameseDefineTheSameKeys() throws {
        let english = try strings(for: "en")
        let vietnamese = try strings(for: "vi")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(vietnamese.keys))
    }

    func testFormatPlaceholdersMatchAcrossLanguages() throws {
        let english = try strings(for: "en")
        let vietnamese = try strings(for: "vi")
        for (key, value) in english {
            XCTAssertEqual(placeholders(in: value), placeholders(in: vietnamese[key] ?? ""), key)
        }
    }

    func testSelectedLanguageChangesLookupAndFormatting() {
        L10n.language = .english
        XCTAssertEqual(L10n.tr("queue.summary.pdfs", 2, 9), "2 files · 9 pages")
        XCTAssertEqual(AppLanguage.system.toolbarTitle, "Auto")
        XCTAssertEqual(AppLanguage.english.toolbarTitle, "EN")
        L10n.language = .vietnamese
        XCTAssertEqual(L10n.tr("queue.summary.pdfs", 2, 9), "2 file · 9 trang")
        XCTAssertEqual(PageOrder.reversed.title, "Ngược")
        XCTAssertEqual(AppLanguage.system.toolbarTitle, "Hệ thống")
        XCTAssertEqual(AppLanguage.vietnamese.toolbarTitle, "VI")
    }

    func testStoredRawValuesStayStableAcrossLanguages() {
        L10n.language = .vietnamese
        XCTAssertEqual(PageOrder.reversed.rawValue, "Reverse")
        XCTAssertEqual(PrintPhase.odd.rawValue, "Odd pages")
    }

    private func strings(for code: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.resourceBundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: code
        ))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func placeholders(in value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(ld|@|d)")
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }.sorted()
    }
}
