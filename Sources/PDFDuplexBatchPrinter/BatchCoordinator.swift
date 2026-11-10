import Foundation

@MainActor
final class BatchCoordinator: ObservableObject {
    enum ErrorDecision { case retry, skip, cancel }

    @Published private(set) var state: BatchState = .idle
    @Published private(set) var currentIndex: Int?

    private let printService: any PrintServicing
    private let pdfService: PDFService
    private var task: Task<Void, Never>?
    private var flipContinuation: CheckedContinuation<Void, Error>?
    private var errorContinuation: CheckedContinuation<ErrorDecision, Never>?
    private var activeJob: SubmittedPrintJob?

    init(printService: any PrintServicing, pdfService: PDFService = PDFService()) {
        self.printService = printService
        self.pdfService = pdfService
    }

    func start(queue: BindingBox<[PDFQueueItem]>, profile: PrinterProfile) {
        guard !state.isRunning, !queue.value.isEmpty, !profile.printerQueue.isEmpty else { return }
        resetStatuses(queue: queue)
        task = Task { await run(queue: queue, profile: profile) }
    }

    func startImages(queue: BindingBox<[ImageQueueItem]>, mode: ImagePrintMode, profile: PrinterProfile) {
        guard !state.isRunning, !queue.value.isEmpty, !profile.printerQueue.isEmpty else { return }
        resetImageStatuses(queue: queue)
        if mode == .singleSided {
            task = Task { await runSingleSidedImages(queue: queue, profile: profile) }
        } else {
            task = Task { await runImages(queue: queue, profile: profile) }
        }
    }

    func confirmPaperFlipped() {
        flipContinuation?.resume()
        flipContinuation = nil
    }

    func resolveError(_ decision: ErrorDecision) {
        errorContinuation?.resume(returning: decision)
        errorContinuation = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let job = activeJob { Task { await printService.cancel(job: job) } }
        activeJob = nil
        flipContinuation?.resume(throwing: CancellationError())
        flipContinuation = nil
        errorContinuation?.resume(returning: .cancel)
        errorContinuation = nil
        state = .cancelled
    }

    private func run(queue: BindingBox<[PDFQueueItem]>, profile: PrinterProfile) async {
        defer {
            activeJob = nil
            currentIndex = nil
            task = nil
        }

        for index in queue.value.indices {
            guard !Task.isCancelled else { state = .cancelled; return }
            currentIndex = index
            var shouldRetry = true
            while shouldRetry {
                shouldRetry = false
                do {
                    try await printFile(index: index, queue: queue, profile: profile)
                } catch is CancellationError {
                    state = .cancelled
                    return
                } catch {
                    queue.value[index].status = .failed
                    state = .pausedOnError(file: queue.value[index].name, message: error.localizedDescription)
                    let decision = await withCheckedContinuation { errorContinuation = $0 }
                    switch decision {
                    case .retry:
                        queue.value[index].status = .ready
                        shouldRetry = true
                    case .skip:
                        queue.value[index].status = .skipped
                    case .cancel:
                        state = .cancelled
                        return
                    }
                }
            }
        }
        state = .completed
    }

    private func runSingleSidedImages(
        queue: BindingBox<[ImageQueueItem]>,
        profile: PrinterProfile
    ) async {
        defer {
            activeJob = nil
            currentIndex = nil
            task = nil
        }

        for index in queue.value.indices {
            guard !Task.isCancelled else { state = .cancelled; return }
            currentIndex = index
            var shouldRetry = true
            while shouldRetry {
                shouldRetry = false
                do {
                    try await printSingleImage(index: index, queue: queue, profile: profile)
                } catch is CancellationError {
                    state = .cancelled
                    return
                } catch {
                    queue.value[index].status = .failed
                    state = .pausedOnError(file: queue.value[index].name, message: error.localizedDescription)
                    let decision = await withCheckedContinuation { errorContinuation = $0 }
                    switch decision {
                    case .retry:
                        queue.value[index].status = .ready
                        shouldRetry = true
                    case .skip:
                        queue.value[index].status = .skipped
                    case .cancel:
                        state = .cancelled
                        return
                    }
                }
            }
        }
        state = .completed
    }

    private func runImages(queue: BindingBox<[ImageQueueItem]>, profile: PrinterProfile) async {
        defer {
            activeJob = nil
            currentIndex = nil
            task = nil
        }

        var shouldRetry = true
        while shouldRetry {
            shouldRetry = false
            do {
                try await printImages(queue: queue, profile: profile)
                state = .completed
            } catch is CancellationError {
                state = .cancelled
                return
            } catch {
                setImageStatus(.failed, queue: queue)
                state = .pausedOnError(file: "Image list", message: error.localizedDescription)
                let decision = await withCheckedContinuation { errorContinuation = $0 }
                switch decision {
                case .retry:
                    setImageStatus(.ready, queue: queue)
                    shouldRetry = true
                case .skip:
                    setImageStatus(.skipped, queue: queue)
                    state = .completed
                case .cancel:
                    state = .cancelled
                    return
                }
            }
        }
    }

    private func printFile(index: Int, queue: BindingBox<[PDFQueueItem]>, profile: PrinterProfile) async throws {
        let item = queue.value[index]
        state = .preparing(file: item.name)
        let plan = DuplexPlanner.plan(pageCount: item.pageCount, profile: profile)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        var temporaryFiles: [URL] = []
        defer { for url in temporaryFiles { try? FileManager.default.removeItem(at: url) } }

        let oddURL = try pdfService.makePass(sourceURL: item.url, pages: plan.oddPass, rotation: .none, temporaryDirectory: tempDirectory, label: "odd")
        temporaryFiles.append(oddURL)
        queue.value[index].status = .printingOdd
        try await printPass(url: oddURL, fileName: item.name, phase: .odd, profile: profile)

        // If the even plan contains only padding (a one-page document), there
        // is no real back-side content. Finish immediately without a flip alert
        // or a blank Even job. Documents with 3+ odd pages still feed padding.
        guard plan.evenPass.contains(where: { $0.sourcePage != nil }) else {
            queue.value[index].status = .completed
            return
        }

        queue.value[index].status = .waitingForFlip
        state = .waitingForFlip(file: item.name, instruction: flipInstruction(profile: profile))
        try await withCheckedThrowingContinuation { flipContinuation = $0 }

        let evenURL = try pdfService.makePass(sourceURL: item.url, pages: plan.evenPass, rotation: profile.evenRotation, temporaryDirectory: tempDirectory, label: "even")
        temporaryFiles.append(evenURL)
        queue.value[index].status = .printingEven
        try await printPass(url: evenURL, fileName: item.name, phase: .even, profile: profile)
        queue.value[index].status = .completed
    }

    private func printImages(
        queue: BindingBox<[ImageQueueItem]>,
        profile: PrinterProfile
    ) async throws {
        let fileName = "Image list (\(queue.value.count))"
        state = .preparing(file: fileName)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        var temporaryFiles: [URL] = []
        defer { for url in temporaryFiles { try? FileManager.default.removeItem(at: url) } }

        let sourceURL = try pdfService.makeImageDocument(
            sourceURLs: queue.value.map(\.url),
            paperSize: profile.paperSize,
            temporaryDirectory: tempDirectory
        )
        temporaryFiles.append(sourceURL)

        let plan = DuplexPlanner.plan(pageCount: queue.value.count, profile: profile)
        let oddURL = try pdfService.makePass(
            sourceURL: sourceURL,
            pages: plan.oddPass,
            rotation: .none,
            temporaryDirectory: tempDirectory,
            label: "image-odd"
        )
        temporaryFiles.append(oddURL)
        setImageStatus(.printingOdd, queue: queue)
        try await printPass(url: oddURL, fileName: fileName, phase: .odd, profile: profile)

        guard plan.evenPass.contains(where: { $0.sourcePage != nil }) else {
            setImageStatus(.completed, queue: queue)
            return
        }

        setImageStatus(.waitingForFlip, queue: queue)
        state = .waitingForFlip(file: fileName, instruction: flipInstruction(profile: profile))
        try await withCheckedThrowingContinuation { flipContinuation = $0 }

        let evenURL = try pdfService.makePass(
            sourceURL: sourceURL,
            pages: plan.evenPass,
            rotation: profile.evenRotation,
            temporaryDirectory: tempDirectory,
            label: "image-even"
        )
        temporaryFiles.append(evenURL)
        setImageStatus(.printingEven, queue: queue)
        try await printPass(url: evenURL, fileName: fileName, phase: .even, profile: profile)
        setImageStatus(.completed, queue: queue)
    }

    private func printSingleImage(
        index: Int,
        queue: BindingBox<[ImageQueueItem]>,
        profile: PrinterProfile
    ) async throws {
        let item = queue.value[index]
        state = .preparing(file: item.name)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFDuplexBatchPrinter", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let pageURL = try pdfService.makeImageDocument(
            sourceURLs: [item.url],
            paperSize: profile.paperSize,
            temporaryDirectory: tempDirectory,
            label: "image-page-\(index + 1)"
        )
        defer { try? FileManager.default.removeItem(at: pageURL) }

        queue.value[index].status = .printingOdd
        try await printPass(url: pageURL, fileName: item.name, phase: .single, profile: profile)
        queue.value[index].status = .completed
    }

    private func printPass(url: URL, fileName: String, phase: PrintPhase, profile: PrinterProfile) async throws {
        state = .printing(file: fileName, phase: phase, jobID: nil)
        let title = "\(fileName) — \(phase.rawValue)"
        let job = try await printService.submit(pdfURL: url, printer: profile.printerQueue, title: title, profile: profile)
        activeJob = job
        state = .printing(file: fileName, phase: phase, jobID: job.id)
        try await printService.waitUntilFinished(job: job)
        activeJob = nil
    }

    private func flipInstruction(profile: PrinterProfile) -> String {
        let rotation = profile.evenRotation == .rotate180 ? "rotate the stack 180°, then " : ""
        return "Take the printed stack, \(rotation)reinsert it for \(profile.flipEdge.rawValue.lowercased()) binding. Keep the page order unchanged, then continue."
    }

    private func resetStatuses(queue: BindingBox<[PDFQueueItem]>) {
        for index in queue.value.indices where queue.value[index].status != .missing {
            queue.value[index].status = .ready
        }
    }

    private func resetImageStatuses(queue: BindingBox<[ImageQueueItem]>) {
        for index in queue.value.indices where queue.value[index].status != .missing {
            queue.value[index].status = .ready
        }
    }

    private func setImageStatus(_ status: QueueItemStatus, queue: BindingBox<[ImageQueueItem]>) {
        for index in queue.value.indices where queue.value[index].status != .missing {
            queue.value[index].status = status
        }
    }
}

/// A small reference wrapper lets the coordinator update the same queue owned by SwiftUI.
@MainActor
final class BindingBox<Value> {
    var value: Value {
        get { getter() }
        set { setter(newValue) }
    }
    private let getter: () -> Value
    private let setter: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }
}
