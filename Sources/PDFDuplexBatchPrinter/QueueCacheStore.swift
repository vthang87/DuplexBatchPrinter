import Foundation

struct QueueCacheStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
            .appendingPathComponent("pdf-queue.json")
    }

    func load(legacyData: Data? = nil) throws -> [PDFQueueItem] {
        let data: Data
        if FileManager.default.fileExists(atPath: fileURL.path) {
            data = try Data(contentsOf: fileURL)
        } else if let legacyData {
            data = legacyData
        } else {
            return []
        }

        var items = try JSONDecoder().decode([PDFQueueItem].self, from: data)
        for index in items.indices { items[index].refreshFileReference() }

        // Transparently migrate the previous UserDefaults cache to the JSON file.
        if !FileManager.default.fileExists(atPath: fileURL.path), legacyData != nil {
            try save(items)
        }
        return items
    }

    func save(_ items: [PDFQueueItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistentItems = items.map { item -> PDFQueueItem in
            var copy = item
            copy.status = .ready
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persistentItems).write(to: fileURL, options: .atomic)
    }
}
