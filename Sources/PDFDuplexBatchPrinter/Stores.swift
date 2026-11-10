import Foundation
import PDFKit

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [PrinterProfile] = []
    private let fileURL: URL
    private let userDefaults: UserDefaults

    init(fileURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.fileURL = fileURL ?? Self.defaultDirectory.appendingPathComponent("printer-profiles.json")
        self.userDefaults = userDefaults
        load()
        migrateDefaultPageOrderIfNeeded()
    }

    func profiles(for printer: String) -> [PrinterProfile] {
        profiles.filter { $0.printerQueue == printer }
    }

    func save(_ profile: PrinterProfile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    func delete(_ profile: PrinterProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        try persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PrinterProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }

    private func migrateDefaultPageOrderIfNeeded() {
        let key = "didMigrateDefaultPageOrderToReverseOddV2"
        guard !userDefaults.bool(forKey: key) else { return }

        for index in profiles.indices where
            profiles[index].name == "Default profile" &&
            profiles[index].oddOrder == .normal &&
            profiles[index].evenOrder == .reversed {
            profiles[index].oddOrder = .reversed
            profiles[index].evenOrder = .normal
        }

        do {
            try persist()
            userDefaults.set(true, forKey: key)
        } catch {
            // Leave the migration flag unset so the app retries on next launch.
        }
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var queue: [PDFQueueItem] = [] { didSet { persistQueue() } }
    @Published var imageQueue: [ImageQueueItem] = [] { didSet { persistImageQueue() } }
    @Published var queueContent: QueueContent = .pdfs {
        didSet { userDefaults.set(queueContent.rawValue, forKey: Keys.queueContent) }
    }
    @Published var imagePrintMode: ImagePrintMode = .doubleSided {
        didSet { userDefaults.set(imagePrintMode.rawValue, forKey: Keys.imagePrintMode) }
    }
    @Published var printers: [PrinterDescriptor] = []
    @Published var selectedPrinter = "" { didSet { userDefaults.set(selectedPrinter, forKey: Keys.printer) } }
    @Published var selectedProfileID: UUID? {
        didSet { userDefaults.set(selectedProfileID?.uuidString, forKey: Keys.profileID) }
    }
    @Published var editableProfile = PrinterProfile(printerQueue: "")
    @Published var alertMessage: String?
    @Published var isLoadingPrinters = false

    let profileStore: ProfileStore
    let printService: any PrintServicing
    private let queueCacheStore: QueueCacheStore
    private let imageQueueCacheStore: ImageQueueCacheStore
    private let userDefaults: UserDefaults

    init(
        profileStore: ProfileStore? = nil,
        printService: any PrintServicing = CUPSService(),
        queueCacheStore: QueueCacheStore = QueueCacheStore(),
        imageQueueCacheStore: ImageQueueCacheStore = ImageQueueCacheStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.profileStore = profileStore ?? ProfileStore()
        self.printService = printService
        self.queueCacheStore = queueCacheStore
        self.imageQueueCacheStore = imageQueueCacheStore
        self.userDefaults = userDefaults
        selectedPrinter = userDefaults.string(forKey: Keys.printer) ?? ""
        queueContent = QueueContent(rawValue: userDefaults.string(forKey: Keys.queueContent) ?? "") ?? .pdfs
        imagePrintMode = ImagePrintMode(rawValue: userDefaults.string(forKey: Keys.imagePrintMode) ?? "") ?? .doubleSided
        loadQueue()
        loadImageQueue()
    }

    var matchingProfiles: [PrinterProfile] { profileStore.profiles(for: selectedPrinter) }
    var hasMissingFiles: Bool {
        switch queueContent {
        case .pdfs: queue.contains { $0.status == .missing }
        case .images: imageQueue.contains { $0.status == .missing }
        }
    }

    func reloadPrinters() async {
        isLoadingPrinters = true
        defer { isLoadingPrinters = false }
        do {
            printers = try await printService.listPrinters()
            if !printers.contains(where: { $0.queueName == selectedPrinter }) {
                selectedPrinter = printers.first(where: \PrinterDescriptor.isDefault)?.queueName ?? printers.first?.queueName ?? ""
            }
            selectInitialProfile()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func add(urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            guard !queue.contains(where: { $0.path == url.path }) else { continue }
            do {
                let count = try PDFService().pageCount(at: url)
                queue.append(PDFQueueItem(url: url, pageCount: count))
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func addImages(urls: [URL]) {
        for url in urls {
            guard !imageQueue.contains(where: { $0.path == url.path }) else { continue }
            do {
                try PDFService().validateImage(at: url)
                imageQueue.append(ImageQueueItem(url: url))
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func move(from offsets: IndexSet, to destination: Int) { queue.move(fromOffsets: offsets, toOffset: destination) }
    func remove(at offsets: IndexSet) { queue.remove(atOffsets: offsets) }

    func moveItem(_ id: UUID, direction: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard queue.indices.contains(target) else { return }
        queue.swapAt(index, target)
    }

    func moveImages(from offsets: IndexSet, to destination: Int) {
        imageQueue.move(fromOffsets: offsets, toOffset: destination)
    }

    func removeImages(at offsets: IndexSet) { imageQueue.remove(atOffsets: offsets) }

    func moveImage(_ id: UUID, direction: Int) {
        guard let index = imageQueue.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard imageQueue.indices.contains(target) else { return }
        imageQueue.swapAt(index, target)
    }

    func selectProfile(id: UUID?) {
        selectedProfileID = id
        if let profile = profileStore.profiles.first(where: { $0.id == id }) {
            editableProfile = profile
        } else {
            editableProfile = PrinterProfile(printerQueue: selectedPrinter)
        }
    }

    func printerChanged() {
        selectInitialProfile()
    }

    func saveProfile() {
        editableProfile.printerQueue = selectedPrinter
        do {
            try profileStore.save(editableProfile)
            selectedProfileID = editableProfile.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func selectInitialProfile() {
        let savedID = userDefaults.string(forKey: Keys.profileID).flatMap(UUID.init(uuidString:))
        if let profile = matchingProfiles.first(where: { $0.id == savedID }) ?? matchingProfiles.first {
            selectProfile(id: profile.id)
        } else {
            selectProfile(id: nil)
        }
    }

    private func loadQueue() {
        do {
            queue = try queueCacheStore.load(legacyData: userDefaults.data(forKey: Keys.queue))
        } catch {
            alertMessage = "Cannot restore the saved PDF queue: \(error.localizedDescription)"
        }
    }

    private func persistQueue() {
        do {
            try queueCacheStore.save(queue)
        } catch {
            alertMessage = "Cannot save the PDF queue: \(error.localizedDescription)"
        }
    }

    private func loadImageQueue() {
        do {
            imageQueue = try imageQueueCacheStore.load()
        } catch {
            alertMessage = "Cannot restore the saved image queue: \(error.localizedDescription)"
        }
    }

    private func persistImageQueue() {
        do {
            try imageQueueCacheStore.save(imageQueue)
        } catch {
            alertMessage = "Cannot save the image queue: \(error.localizedDescription)"
        }
    }

    private enum Keys {
        static let queue = "savedPDFQueue"
        static let printer = "selectedPrinter"
        static let profileID = "selectedProfileID"
        static let queueContent = "selectedQueueContent"
        static let imagePrintMode = "selectedImagePrintMode"
    }
}
