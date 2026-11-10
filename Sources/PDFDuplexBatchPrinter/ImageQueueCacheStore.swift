import Foundation

struct ImageQueueCacheStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
            .appendingPathComponent("image-queue.json")
    }

    func load() throws -> [ImageQueueItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var items = try JSONDecoder().decode([ImageQueueItem].self, from: data)
        for index in items.indices { items[index].refreshFileReference() }
        return items
    }

    func save(_ items: [ImageQueueItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistentItems = items.map { item -> ImageQueueItem in
            var copy = item
            copy.status = .ready
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persistentItems).write(to: fileURL, options: .atomic)
    }
}
