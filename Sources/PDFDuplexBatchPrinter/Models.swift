import Foundation

enum QueueItemStatus: String, Codable {
    case ready, printingOdd, waitingForFlip, printingEven, completed, skipped, failed, missing
}

struct PDFQueueItem: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String
    var pageCount: Int
    var status: QueueItemStatus
    var bookmarkData: Data?

    init(id: UUID = UUID(), url: URL, pageCount: Int, status: QueueItemStatus = .ready) {
        self.id = id
        self.path = url.path
        self.pageCount = pageCount
        self.status = status
        self.bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    var url: URL {
        guard let bookmarkData else { return URL(fileURLWithPath: path) }
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? URL(fileURLWithPath: path)
    }

    mutating func refreshFileReference() {
        let resolvedURL = url
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            path = resolvedURL.path
            bookmarkData = try? resolvedURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            status = .ready
        } else {
            status = .missing
        }
    }

    var name: String { url.lastPathComponent }
}

struct ImageQueueItem: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String
    var status: QueueItemStatus
    var bookmarkData: Data?

    init(id: UUID = UUID(), url: URL, status: QueueItemStatus = .ready) {
        self.id = id
        self.path = url.path
        self.status = status
        self.bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    var url: URL {
        guard let bookmarkData else { return URL(fileURLWithPath: path) }
        var isStale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? URL(fileURLWithPath: path)
    }

    mutating func refreshFileReference() {
        let resolvedURL = url
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            path = resolvedURL.path
            bookmarkData = try? resolvedURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            status = .ready
        } else {
            status = .missing
        }
    }

    var name: String { url.lastPathComponent }
}

enum QueueContent: String, CaseIterable, Identifiable {
    case pdfs = "PDFs"
    case images = "Images"
    var id: String { rawValue }
}

enum QueueViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case thumbnails = "Thumbnails"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .thumbnails: "square.grid.2x2"
        }
    }
}

enum ImagePrintMode: String, CaseIterable, Identifiable {
    case singleSided = "1 mặt"
    case doubleSided = "2 mặt"
    var id: String { rawValue }
}

struct PrinterDescriptor: Identifiable, Hashable {
    var id: String { queueName }
    let queueName: String
    let displayName: String
    let isDefault: Bool
}

enum PageOrder: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal"
    case reversed = "Reverse"
    var id: String { rawValue }
}

enum PaperRotation: String, Codable, CaseIterable, Identifiable {
    case none = "Keep orientation"
    case rotate180 = "Rotate 180°"
    var id: String { rawValue }
}

enum FlipEdge: String, Codable, CaseIterable, Identifiable {
    case longEdge = "Long edge"
    case shortEdge = "Short edge"
    var id: String { rawValue }
}

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a4 = "A4"
    case letter = "Letter"
    var id: String { rawValue }

    var cupsValue: String { rawValue }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case grayscale = "Grayscale"
    case color = "Color"
    var id: String { rawValue }
}

struct PrinterProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var printerQueue: String
    var paperSize: PaperSize
    var colorMode: ColorMode
    var oddOrder: PageOrder
    var evenOrder: PageOrder
    var evenRotation: PaperRotation
    var flipEdge: FlipEdge
    var cupsOptions: [String: String]
    var lastCalibrated: Date?

    init(
        id: UUID = UUID(),
        name: String = "Default profile",
        printerQueue: String,
        paperSize: PaperSize = .a4,
        colorMode: ColorMode = .automatic,
        oddOrder: PageOrder = .reversed,
        evenOrder: PageOrder = .normal,
        evenRotation: PaperRotation = .none,
        flipEdge: FlipEdge = .longEdge,
        cupsOptions: [String: String] = [:],
        lastCalibrated: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.printerQueue = printerQueue
        self.paperSize = paperSize
        self.colorMode = colorMode
        self.oddOrder = oddOrder
        self.evenOrder = evenOrder
        self.evenRotation = evenRotation
        self.flipEdge = flipEdge
        self.cupsOptions = cupsOptions
        self.lastCalibrated = lastCalibrated
    }
}

enum PrintPhase: String, Equatable {
    case single = "All pages"
    case odd = "Odd pages"
    case even = "Even pages"
}

struct SubmittedPrintJob: Equatable {
    let id: String
    let printer: String
    let title: String
}

enum BatchState: Equatable {
    case idle
    case preparing(file: String)
    case printing(file: String, phase: PrintPhase, jobID: String?)
    case waitingForFlip(file: String, instruction: String)
    case pausedOnError(file: String, message: String)
    case completed
    case cancelled

    var isRunning: Bool {
        switch self {
        case .preparing, .printing, .waitingForFlip, .pausedOnError: true
        default: false
        }
    }
}
