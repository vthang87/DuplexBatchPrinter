import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case vietnamese = "vi"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tr("language.system")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    /// Compact label shown next to the globe in the toolbar so the control is recognizable.
    var toolbarTitle: String {
        switch self {
        case .system: L10n.tr("language.system.short")
        case .english: "EN"
        case .vietnamese: "VI"
        }
    }
}

/// Looks up strings in the selected language instead of the process language, so the
/// in-app language picker takes effect immediately without relaunching.
enum L10n {
    static let supportedLanguageCodes = ["en", "vi"]

    static var language: AppLanguage = .system

    static var languageCode: String {
        switch language {
        case .english, .vietnamese:
            return language.rawValue
        case .system:
            return Bundle.preferredLocalizations(
                from: supportedLanguageCodes,
                forPreferences: Locale.preferredLanguages
            ).first ?? "en"
        }
    }

    static var locale: Locale { Locale(identifier: languageCode) }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = strings(for: languageCode).localizedString(forKey: key, value: nil, table: nil)
        let resolved = format == key && languageCode != "en"
            ? strings(for: "en").localizedString(forKey: key, value: nil, table: nil)
            : format
        return arguments.isEmpty ? resolved : String(format: resolved, locale: locale, arguments: arguments)
    }

    private static var cachedBundles: [String: Bundle] = [:]

    private static func strings(for code: String) -> Bundle {
        if let bundle = cachedBundles[code] { return bundle }
        let bundle = resourceBundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        cachedBundles[code] = bundle
        return bundle
    }

    /// The packaged app keeps the SwiftPM resource bundle in Contents/Resources, which the
    /// generated `Bundle.module` accessor does not search.
    static let resourceBundle: Bundle = {
        let name = "PDFDuplexBatchPrinter_PDFDuplexBatchPrinter.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent(name) }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }()
}
