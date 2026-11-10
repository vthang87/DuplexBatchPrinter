import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: BatchCoordinator
    @State private var isImporting = false
    @State private var showCalibration = false
    @State private var flipAlert: FlipAlertContext?
    @State private var queueViewMode: QueueViewMode = .list
    @State private var previewSelection: PreviewSelection?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                queuePanel
                    .frame(minWidth: 500)
                settingsPanel
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 440)
            }
            Divider()
            progressPanel
                .padding(16)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { isImporting = true } label: {
                    Label(model.queueContent == .pdfs ? "Add PDFs" : "Add Images", systemImage: "plus")
                }
                    .disabled(coordinator.state.isRunning)
                Button { Task { await model.reloadPrinters() } } label: { Label("Refresh printers", systemImage: "arrow.clockwise") }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                if model.queueContent == .pdfs { model.add(urls: urls) }
                else { model.addImages(urls: urls) }
            }
            if case .failure(let error) = result { model.alertMessage = error.localizedDescription }
        }
        .task {
            await model.reloadPrinters()
            await FlipNotificationService.shared.requestAuthorization()
        }
        .onChange(of: coordinator.state) { _, newState in
            guard case .waitingForFlip(let file, let instruction) = newState else { return }
            flipAlert = FlipAlertContext(file: file, instruction: instruction)
            Task { await FlipNotificationService.shared.sendFlipReminder(file: file) }
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView(model: model, isPresented: $showCalibration)
        }
        .sheet(item: $previewSelection) { selection in
            QueuePreviewSheet(selection: selection)
        }
        .alert("PDF Duplex Batch Printer", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(item: $flipAlert) { context in
            Alert(
                title: Text("Đã in xong mặt lẻ"),
                message: Text("\(context.file)\n\n\(context.instruction)"),
                primaryButton: .default(Text("Đã lật giấy – In mặt chẵn")) {
                    coordinator.confirmPaperFlipped()
                },
                secondaryButton: .cancel(Text("Để sau"))
            )
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.queueContent == .pdfs ? "PDF Print Queue" : "Image Print Queue").font(.title2.bold())
                    Text(queueSummary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showPreview(index: 0) } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(activeQueueIsEmpty)
                Button("Clear") { clearActiveQueue() }
                    .disabled(activeQueueIsEmpty || coordinator.state.isRunning)
            }

            HStack {
                Picker("Queue type", selection: $model.queueContent) {
                    ForEach(QueueContent.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Picker("View", selection: $queueViewMode) {
                    ForEach(QueueViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }
            .disabled(coordinator.state.isRunning)

            if activeQueueIsEmpty {
                ContentUnavailableView(
                    model.queueContent == .pdfs ? "No PDFs" : "No Images",
                    systemImage: model.queueContent == .pdfs ? "doc.richtext" : "photo.on.rectangle.angled",
                    description: Text(model.queueContent == .pdfs
                        ? "Add PDF files to create a sequential print queue."
                        : "Add images in the order you want them printed.")
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dropDestination(for: URL.self) { urls, _ in
                        addDropped(urls)
                    }
            } else {
                if queueViewMode == .list {
                    if model.queueContent == .pdfs {
                        List {
                            ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                                PDFQueueRow(
                                    item: item,
                                    index: index,
                                    count: model.queue.count,
                                    isLocked: coordinator.state.isRunning,
                                    preview: { showPreview(index: index) },
                                    move: { model.moveItem(item.id, direction: $0) }
                                )
                            }
                            .onDelete(perform: coordinator.state.isRunning ? nil : { model.remove(at: $0) })
                            .onMove(perform: coordinator.state.isRunning ? nil : { model.move(from: $0, to: $1) })
                        }
                        .dropDestination(for: URL.self) { urls, _ in addDropped(urls) }
                    } else {
                        List {
                            ForEach(Array(model.imageQueue.enumerated()), id: \.element.id) { index, item in
                                ImageQueueRow(
                                    item: item,
                                    index: index,
                                    count: model.imageQueue.count,
                                    isLocked: coordinator.state.isRunning,
                                    preview: { showPreview(index: index) },
                                    move: { model.moveImage(item.id, direction: $0) }
                                )
                            }
                            .onDelete(perform: coordinator.state.isRunning ? nil : { model.removeImages(at: $0) })
                            .onMove(perform: coordinator.state.isRunning ? nil : { model.moveImages(from: $0, to: $1) })
                        }
                        .dropDestination(for: URL.self) { urls, _ in addDropped(urls) }
                    }
                } else {
                    thumbnailGrid
                }
            }
        }
        .padding(18)
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shared Print Settings").font(.title2.bold())
                Text(settingsDescription)
                    .font(.callout).foregroundStyle(.secondary)

                if model.queueContent == .images {
                    Picker("Print sides", selection: $model.imagePrintMode) {
                        ForEach(ImagePrintMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(coordinator.state.isRunning)
                }

                Picker("Installed printer", selection: $model.selectedPrinter) {
                    if model.printers.isEmpty { Text("No printers found").tag("") }
                    ForEach(model.printers) { printer in
                        Text(printer.displayName + (printer.isDefault ? " (Default)" : "")).tag(printer.queueName)
                    }
                }
                .onChange(of: model.selectedPrinter) { _, _ in model.printerChanged() }
                .disabled(coordinator.state.isRunning)

                Picker("Saved profile", selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectProfile(id: $0) }
                )) {
                    Text("New profile").tag(Optional<UUID>.none)
                    ForEach(model.matchingProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(model.selectedPrinter.isEmpty || coordinator.state.isRunning)

                GroupBox("Profile") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Profile name", text: $model.editableProfile.name)
                        Picker("Paper", selection: $model.editableProfile.paperSize) {
                            ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Color", selection: $model.editableProfile.colorMode) {
                            ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Odd pass order", selection: $model.editableProfile.oddOrder) {
                            ForEach(PageOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Even pass order", selection: $model.editableProfile.evenOrder) {
                            ForEach(PageOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Reinsert rotation", selection: $model.editableProfile.evenRotation) {
                            ForEach(PaperRotation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Binding edge", selection: $model.editableProfile.flipEdge) {
                            ForEach(FlipEdge.allCases) { Text($0.rawValue).tag($0) }
                        }
                        HStack {
                            Button("Save Profile") { model.saveProfile() }
                            Spacer()
                            Button("Calibrate…") { showCalibration = true }
                        }
                    }
                    .padding(4)
                }
                .disabled(model.selectedPrinter.isEmpty || coordinator.state.isRunning)

                if let date = model.editableProfile.lastCalibrated {
                    Label("Calibrated \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label("Profile not calibrated", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var progressPanel: some View {
        HStack(spacing: 16) {
            stateIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle).font(.headline)
                Text(stateDetail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            controls
        }
    }

    private var stateIcon: some View {
        Image(systemName: coordinator.state.isRunning ? "printer.fill" : "printer")
            .font(.title2).frame(width: 34)
    }

    private var stateTitle: String {
        switch coordinator.state {
        case .idle: "Ready"
        case .preparing(let file): "Preparing \(file)"
        case .printing(let file, let phase, _): phase == .single
            ? "Printing one-sided — \(file)"
            : "Printing \(phase.rawValue.lowercased()) — \(file)"
        case .waitingForFlip(let file, _): "Flip paper for \(file)"
        case .pausedOnError(let file, _): "Printing paused — \(file)"
        case .completed: "Batch completed"
        case .cancelled: "Batch cancelled"
        }
    }

    private var stateDetail: String {
        switch coordinator.state {
        case .idle: idleDetail
        case .preparing: "Creating a temporary print pass."
        case .printing(_, _, let jobID): jobID.map { "CUPS job \($0)" } ?? "Submitting to CUPS…"
        case .waitingForFlip(_, let instruction): instruction
        case .pausedOnError(_, let message): message
        case .completed: "Every non-skipped file has completed both passes."
        case .cancelled: "No additional print passes will be submitted."
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch coordinator.state {
        case .waitingForFlip:
            Button("Paper Reinserted — Print Even") { coordinator.confirmPaperFlipped() }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { coordinator.cancel() }
        case .pausedOnError:
            Button("Retry") { coordinator.resolveError(.retry) }.buttonStyle(.borderedProminent)
            Button("Skip File") { coordinator.resolveError(.skip) }
            Button("Cancel") { coordinator.resolveError(.cancel) }
        case .preparing, .printing:
            ProgressView().controlSize(.small)
            Button("Cancel") { coordinator.cancel() }
        default:
            Button("Start Batch Print") { startBatch() }
                .buttonStyle(.borderedProminent)
                .disabled(activeQueueIsEmpty || model.selectedPrinter.isEmpty || model.hasMissingFiles)
        }
    }

    private func startBatch() {
        var profile = model.editableProfile
        profile.printerQueue = model.selectedPrinter
        let box = BindingBox<[PDFQueueItem]>(get: { model.queue }, set: { model.queue = $0 })
        if model.queueContent == .pdfs {
            coordinator.start(queue: box, profile: profile)
        } else {
            let imageBox = BindingBox<[ImageQueueItem]>(get: { model.imageQueue }, set: { model.imageQueue = $0 })
            coordinator.startImages(queue: imageBox, mode: model.imagePrintMode, profile: profile)
        }
    }

    private var importTypes: [UTType] { model.queueContent == .pdfs ? [.pdf] : [.image] }

    private var activeQueueIsEmpty: Bool {
        model.queueContent == .pdfs ? model.queue.isEmpty : model.imageQueue.isEmpty
    }

    private var queueSummary: String {
        switch model.queueContent {
        case .pdfs: "\(model.queue.count) files · \(model.queue.reduce(0) { $0 + $1.pageCount }) pages"
        case .images: "\(model.imageQueue.count) images · \(model.imageQueue.count) pages"
        }
    }

    private var settingsDescription: String {
        if model.queueContent == .images && model.imagePrintMode == .singleSided {
            return "Images print in list order, one image per sheet, using one shared printer profile."
        }
        return "One printer and profile are applied to every odd and even pass in this batch."
    }

    private var idleDetail: String {
        if model.queueContent == .images && model.imagePrintMode == .singleSided {
            return "Images print in list order, one one-sided job per image, so each row updates as it completes."
        }
        return model.queueContent == .images
            ? "The image list is treated as pages: odd pages → flip → even pages."
            : "Files are processed one at a time: odd pages → flip → even pages → next file."
    }

    private func clearActiveQueue() {
        if model.queueContent == .pdfs { model.queue.removeAll() }
        else { model.imageQueue.removeAll() }
    }

    private func addDropped(_ urls: [URL]) -> Bool {
        guard !coordinator.state.isRunning else { return false }
        if model.queueContent == .pdfs { model.add(urls: urls) }
        else { model.addImages(urls: urls) }
        return true
    }

    private func showPreview(index: Int) {
        let items: [PreviewItem]
        switch model.queueContent {
        case .pdfs:
            items = model.queue.map { PreviewItem(url: $0.url, title: $0.name) }
        case .images:
            items = model.imageQueue.map { PreviewItem(url: $0.url, title: $0.name) }
        }
        guard items.indices.contains(index) else { return }
        previewSelection = PreviewSelection(items: items, initialIndex: index)
    }

    private var thumbnailGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 12)], spacing: 12) {
                if model.queueContent == .pdfs {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                        QueueThumbnailCard(
                            url: item.url,
                            title: item.name,
                            detail: "\(item.pageCount) pages · \(statusText(item.status))",
                            detailColor: statusColor(item.status),
                            index: index,
                            count: model.queue.count,
                            isLocked: coordinator.state.isRunning,
                            preview: { showPreview(index: index) },
                            move: { model.moveItem(item.id, direction: $0) },
                            remove: { model.queue.removeAll { $0.id == item.id } }
                        )
                    }
                } else {
                    ForEach(Array(model.imageQueue.enumerated()), id: \.element.id) { index, item in
                        QueueThumbnailCard(
                            url: item.url,
                            title: item.name,
                            detail: "Page \(index + 1) · \(statusText(item.status))",
                            detailColor: statusColor(item.status),
                            index: index,
                            count: model.imageQueue.count,
                            isLocked: coordinator.state.isRunning,
                            preview: { showPreview(index: index) },
                            move: { model.moveImage(item.id, direction: $0) },
                            remove: { model.imageQueue.removeAll { $0.id == item.id } }
                        )
                    }
                }
            }
            .padding(4)
        }
        .dropDestination(for: URL.self) { urls, _ in addDropped(urls) }
    }
}

private struct FlipAlertContext: Identifiable {
    let id = UUID()
    let file: String
    let instruction: String
}

private struct PDFQueueRow: View {
    let item: PDFQueueItem
    let index: Int
    let count: Int
    let isLocked: Bool
    let preview: () -> Void
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            Image(systemName: "doc.richtext.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("\(item.pageCount) pages · \(statusText)").font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
            Button(action: preview) { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("Preview")
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0 || isLocked)
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1 || isLocked)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch item.status {
        case .ready: "Ready"
        case .printingOdd: "Printing odd pages"
        case .waitingForFlip: "Waiting for paper flip"
        case .printingEven: "Printing even pages"
        case .completed: "Completed"
        case .skipped: "Skipped"
        case .failed: "Error"
        case .missing: "Original file not found"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .failed, .missing: .red
        case .waitingForFlip: .orange
        default: .secondary
        }
    }
}

private struct ImageQueueRow: View {
    let item: ImageQueueItem
    let index: Int
    let count: Int
    let isLocked: Bool
    let preview: () -> Void
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            Image(systemName: "photo.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("Page \(index + 1) · \(statusText(item.status))")
                    .font(.caption)
                    .foregroundStyle(statusColor(item.status))
            }
            Spacer()
            Button(action: preview) { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("Preview")
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0 || isLocked)
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1 || isLocked)
        }
        .padding(.vertical, 4)
    }
}

private func statusText(_ status: QueueItemStatus) -> String {
    switch status {
    case .ready: "Ready"
    case .printingOdd: "Printing"
    case .waitingForFlip: "Waiting for paper flip"
    case .printingEven: "Printing even pages"
    case .completed: "Completed"
    case .skipped: "Skipped"
    case .failed: "Error"
    case .missing: "Original file not found"
    }
}

private func statusColor(_ status: QueueItemStatus) -> Color {
    switch status {
    case .completed: .green
    case .failed, .missing: .red
    case .waitingForFlip: .orange
    default: .secondary
    }
}

private struct QueueThumbnailCard: View {
    let url: URL
    let title: String
    let detail: String
    let detailColor: Color
    let index: Int
    let count: Int
    let isLocked: Bool
    let preview: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                FileThumbnailView(url: url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: preview)

                Text("\(index + 1)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(7)
            }

            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(detail)
                .font(.caption)
                .foregroundStyle(detailColor)
                .lineLimit(1)

            HStack(spacing: 12) {
                Button(action: preview) { Image(systemName: "eye") }
                    .help("Preview")
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.left") }
                    .disabled(index == 0 || isLocked)
                    .help("Move earlier")
                Button { move(1) } label: { Image(systemName: "arrow.right") }
                    .disabled(index == count - 1 || isLocked)
                    .help("Move later")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .disabled(isLocked)
                    .help("Remove")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct FileThumbnailView: View {
    let url: URL

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnail: NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.page(at: 0)?.thumbnail(
                of: NSSize(width: 360, height: 360),
                for: .mediaBox
            )
        }
        return NSImage(contentsOf: url)
    }
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private struct PreviewSelection: Identifiable {
    let id = UUID()
    let items: [PreviewItem]
    let initialIndex: Int
}

private struct QueuePreviewSheet: View {
    let selection: PreviewSelection
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(selection: PreviewSelection) {
        self.selection = selection
        _index = State(initialValue: selection.initialIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.items[index].title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(index + 1) of \(selection.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { index -= 1 } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(index == 0)
                Button { index += 1 } label: { Label("Next", systemImage: "chevron.right") }
                    .disabled(index == selection.items.count - 1)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            FilePreviewView(url: selection.items[index].url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 620)
    }
}

private struct FilePreviewView: View {
    let url: URL

    var body: some View {
        if url.pathExtension.lowercased() == "pdf" {
            PDFDocumentPreview(url: url)
        } else if let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Cannot preview file", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct PDFDocumentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
