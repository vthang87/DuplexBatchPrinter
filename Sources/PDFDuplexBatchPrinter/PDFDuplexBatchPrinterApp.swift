import SwiftUI

@main
struct PDFDuplexBatchPrinterApp: App {
    @StateObject private var model: AppModel
    @StateObject private var coordinator: BatchCoordinator

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _coordinator = StateObject(wrappedValue: BatchCoordinator(printService: model.printService))
    }

    var body: some Scene {
        WindowGroup("PDF Duplex Batch Printer") {
            MainView(model: model, coordinator: coordinator)
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowResizability(.contentMinSize)
    }
}
