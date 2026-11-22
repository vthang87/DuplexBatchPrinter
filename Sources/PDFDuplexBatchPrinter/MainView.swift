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
                    Label(L10n.tr(model.queueContent == .pdfs ? "toolbar.addPDFs" : "toolbar.addImages"), systemImage: "plus")
                }
                    .disabled(coordinator.state.isRunning)
                Button { Task { await model.reloadPrinters() } } label: {
                    Label(L10n.tr("toolbar.refreshPrinters"), systemImage: "arrow.clockwise")
                }
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            model.language = language
                        } label: {
                            if model.language == language {
                                Label(language.title, systemImage: "checkmark")
                            } else {
                                Text(language.title)
                            }
                        }
                    }
                } label: {
                    Label(model.language.toolbarTitle, systemImage: "globe")
                }
                .labelStyle(.titleAndIcon)
                .help(L10n.tr("toolbar.language"))
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
        .alert(L10n.tr("app.name"), isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button(L10n.tr("common.ok")) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(item: $flipAlert) { context in
            Alert(
                title: Text(L10n.tr("flip.title")),
                message: Text("\(context.file)\n\n\(context.instruction)"),
                primaryButton: .default(Text(L10n.tr("flip.alert.confirm"))) {
                    coordinator.confirmPaperFlipped()
                },
                secondaryButton: .cancel(Text(L10n.tr("flip.alert.later")))
            )
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr(model.queueContent == .pdfs ? "queue.title.pdfs" : "queue.title.images")).font(.title2.bold())
                    Text(queueSummary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showPreview(index: 0) } label: {
                    Label(L10n.tr("queue.preview"), systemImage: "eye")
                }
                .disabled(activeQueueIsEmpty)
                Button(L10n.tr("queue.clear")) { clearActiveQueue() }
                    .disabled(activeQueueIsEmpty || coordinator.state.isRunning)
            }

            HStack {
                Picker(L10n.tr("queue.type"), selection: $model.queueContent) {
                    ForEach(QueueContent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Picker(L10n.tr("queue.view"), selection: $queueViewMode) {
                    ForEach(QueueViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .accessibilityLabel(mode.title)
                            .help(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
                .help(L10n.tr("queue.view"))
            }
            .disabled(coordinator.state.isRunning)

            if activeQueueIsEmpty {
                ContentUnavailableView(
                    L10n.tr(model.queueContent == .pdfs ? "queue.empty.pdfs.title" : "queue.empty.images.title"),
                    systemImage: model.queueContent == .pdfs ? "doc.richtext" : "photo.on.rectangle.angled",
                    description: Text(L10n.tr(model.queueContent == .pdfs ? "queue.empty.pdfs.detail" : "queue.empty.images.detail"))
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
                                QueueRow(
                                    title: item.name,
                                    detail: "\(L10n.tr("queue.pageCount", item.pageCount)) · \(statusText(item.status, isPDF: true))",
                                    status: item.status,
                                    systemImage: "doc.richtext.fill",
                                    tint: .red,
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
                                QueueRow(
                                    title: item.name,
                                    detail: "\(L10n.tr("queue.pageNumber", index + 1)) · \(statusText(item.status, isPDF: false))",
                                    status: item.status,
                                    systemImage: "photo.fill",
                                    tint: .blue,
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
                Text(L10n.tr("settings.title")).font(.title2.bold())
                Text(settingsDescription)
                    .font(.callout).foregroundStyle(.secondary)

                if model.queueContent == .pdfs {
                    Picker(L10n.tr("settings.pdfBatchMode"), selection: $model.pdfBatchMode) {
                        ForEach(PDFBatchMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(coordinator.state.isRunning)
                } else {
                    Picker(L10n.tr("settings.printSides"), selection: $model.imagePrintMode) {
                        ForEach(ImagePrintMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(coordinator.state.isRunning)
                }

                Picker(L10n.tr("settings.printer"), selection: $model.selectedPrinter) {
                    if model.printers.isEmpty { Text(L10n.tr("settings.noPrinters")).tag("") }
                    ForEach(model.printers) { printer in
                        Text(printer.isDefault ? L10n.tr("settings.defaultPrinter", printer.displayName) : printer.displayName)
                            .tag(printer.queueName)
                    }
                }
                .onChange(of: model.selectedPrinter) { _, _ in model.printerChanged() }
                .disabled(coordinator.state.isRunning)

                Picker(L10n.tr("settings.savedProfile"), selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectProfile(id: $0) }
                )) {
                    Text(L10n.tr("settings.newProfile")).tag(Optional<UUID>.none)
                    ForEach(model.matchingProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(model.selectedPrinter.isEmpty || coordinator.state.isRunning)

                GroupBox(L10n.tr("profile.title")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L10n.tr("profile.name"), text: $model.editableProfile.name)
                        Picker(L10n.tr("profile.paper"), selection: $model.editableProfile.paperSize) {
                            ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                        }
                        Picker(L10n.tr("profile.color"), selection: $model.editableProfile.colorMode) {
                            ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                        }
                        ProfileOrderPickers(profile: $model.editableProfile)
                        HStack {
                            Button(L10n.tr("profile.save")) { model.saveProfile() }
                            Spacer()
                            Button(L10n.tr("profile.calibrate")) { showCalibration = true }
                        }
                    }
                    .padding(4)
                }
                .disabled(model.selectedPrinter.isEmpty || coordinator.state.isRunning)

                if let date = model.editableProfile.lastCalibrated {
                    Label(
                        L10n.tr("profile.calibratedAt", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))),
                        systemImage: "checkmark.seal.fill"
                    )
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label(L10n.tr("profile.notCalibrated"), systemImage: "exclamationmark.triangle.fill")
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
                Text(stateDetail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
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
        case .idle: L10n.tr("state.ready")
        case .preparing(let file): L10n.tr("state.preparing", file)
        case .printing(let file, let phase, _):
            switch phase {
            case .single: L10n.tr("state.printing.single", file)
            case .odd: L10n.tr("state.printing.odd", file)
            case .even: L10n.tr("state.printing.even", file)
            }
        case .waitingForFlip(let file, _): L10n.tr("state.flip", file)
        case .pausedOnError(let file, _): L10n.tr("state.paused", file)
        case .completed: L10n.tr("state.completed")
        case .cancelled: L10n.tr("state.cancelled")
        }
    }

    private var stateDetail: String {
        switch coordinator.state {
        case .idle: idleDetail
        case .preparing: L10n.tr("state.preparing.detail")
        case .printing(_, _, let jobID): jobID.map { L10n.tr("state.printing.job", $0) } ?? L10n.tr("state.printing.submitting")
        case .waitingForFlip(_, let instruction): instruction
        case .pausedOnError(_, let message): message
        case .completed: L10n.tr("state.completed.detail")
        case .cancelled: L10n.tr("state.cancelled.detail")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch coordinator.state {
        case .waitingForFlip:
            Button(L10n.tr("controls.printEven")) { coordinator.confirmPaperFlipped() }
                .buttonStyle(.borderedProminent)
            Button(L10n.tr("common.cancel")) { coordinator.cancel() }
        case .pausedOnError:
            Button(L10n.tr("controls.retry")) { coordinator.resolveError(.retry) }.buttonStyle(.borderedProminent)
            Button(L10n.tr("controls.skip")) { coordinator.resolveError(.skip) }
            Button(L10n.tr("common.cancel")) { coordinator.resolveError(.cancel) }
        case .preparing, .printing:
            ProgressView().controlSize(.small)
            Button(L10n.tr("common.cancel")) { coordinator.cancel() }
        default:
            Button(L10n.tr("controls.start")) { startBatch() }
                .buttonStyle(.borderedProminent)
                .disabled(activeQueueIsEmpty || model.selectedPrinter.isEmpty || model.hasMissingFiles)
        }
    }

    private func startBatch() {
        var profile = model.editableProfile
        profile.printerQueue = model.selectedPrinter
        let box = BindingBox<[PDFQueueItem]>(get: { model.queue }, set: { model.queue = $0 })
        if model.queueContent == .pdfs {
            coordinator.start(queue: box, mode: model.pdfBatchMode, profile: profile)
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
        case .pdfs: L10n.tr("queue.summary.pdfs", model.queue.count, model.queue.reduce(0) { $0 + $1.pageCount })
        case .images: L10n.tr("queue.summary.images", model.imageQueue.count, model.imageQueue.count)
        }
    }

    private var settingsDescription: String {
        if model.queueContent == .images && model.imagePrintMode == .singleSided {
            return L10n.tr("settings.description.imagesSingle")
        }
        return L10n.tr("settings.description.shared")
    }

    private var idleDetail: String {
        switch model.queueContent {
        case .pdfs:
            return L10n.tr(model.pdfBatchMode == .combined ? "idle.pdfs.combined" : "idle.pdfs.perFile")
        case .images:
            return L10n.tr(model.imagePrintMode == .singleSided ? "idle.images.single" : "idle.images.double")
        }
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
                            detail: "\(L10n.tr("queue.pageCount", item.pageCount)) · \(statusText(item.status, isPDF: true))",
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
                            detail: "\(L10n.tr("queue.pageNumber", index + 1)) · \(statusText(item.status, isPDF: false))",
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

/// Odd/even order, reinsertion rotation, and binding edge, shared by the profile editor and calibration.
struct ProfileOrderPickers: View {
    @Binding var profile: PrinterProfile

    var body: some View {
        Picker(L10n.tr("profile.oddOrder"), selection: $profile.oddOrder) {
            ForEach(PageOrder.allCases) { Text($0.title).tag($0) }
        }
        Picker(L10n.tr("profile.evenOrder"), selection: $profile.evenOrder) {
            ForEach(PageOrder.allCases) { Text($0.title).tag($0) }
        }
        Picker(L10n.tr("profile.rotation"), selection: $profile.evenRotation) {
            ForEach(PaperRotation.allCases) { Text($0.title).tag($0) }
        }
        Picker(L10n.tr("profile.bindingEdge"), selection: $profile.flipEdge) {
            ForEach(FlipEdge.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct FlipAlertContext: Identifiable {
    let id = UUID()
    let file: String
    let instruction: String
}

private struct QueueRow: View {
    let title: String
    let detail: String
    let status: QueueItemStatus
    let systemImage: String
    let tint: Color
    let index: Int
    let count: Int
    let isLocked: Bool
    let preview: () -> Void
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(statusColor(status))
            }
            Spacer()
            Button(action: preview) { Image(systemName: "eye") }
                .buttonStyle(.borderless).help(L10n.tr("queue.preview"))
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0 || isLocked)
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1 || isLocked)
        }
        .padding(.vertical, 4)
    }
}

private func statusText(_ status: QueueItemStatus, isPDF: Bool) -> String {
    switch status {
    case .ready: L10n.tr("status.ready")
    case .printingOdd: L10n.tr(isPDF ? "status.printingOdd" : "status.printing")
    case .waitingForFlip: L10n.tr("status.waitingForFlip")
    case .printingEven: L10n.tr("status.printingEven")
    case .completed: L10n.tr("status.completed")
    case .skipped: L10n.tr("status.skipped")
    case .failed: L10n.tr("status.failed")
    case .missing: L10n.tr("status.missing")
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
                    .help(L10n.tr("queue.preview"))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.left") }
                    .disabled(index == 0 || isLocked)
                    .help(L10n.tr("queue.moveEarlier"))
                Button { move(1) } label: { Image(systemName: "arrow.right") }
                    .disabled(index == count - 1 || isLocked)
                    .help(L10n.tr("queue.moveLater"))
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .disabled(isLocked)
                    .help(L10n.tr("queue.remove"))
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
                    Text(L10n.tr("preview.position", index + 1, selection.items.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { index -= 1 } label: { Label(L10n.tr("preview.previous"), systemImage: "chevron.left") }
                    .disabled(index == 0)
                Button { index += 1 } label: { Label(L10n.tr("preview.next"), systemImage: "chevron.right") }
                    .disabled(index == selection.items.count - 1)
                Button(L10n.tr("common.done")) { dismiss() }
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
            ContentUnavailableView(L10n.tr("preview.unavailable"), systemImage: "exclamationmark.triangle")
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
