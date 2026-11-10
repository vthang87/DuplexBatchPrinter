import AppKit
import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var generatedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Manual Duplex Calibration").font(.title.bold())
            Text("Calibration records how this printer outputs and accepts the paper stack. Do it once per printer/profile, then use that profile for every PDF in the batch.")
                .foregroundStyle(.secondary)

            GroupBox("1. Create the marked test document") {
                HStack {
                    Text("The four pages are marked FRONT/BACK and show the top edge.")
                    Spacer()
                    Button("Create & Open Test PDF") { createCalibrationPDF() }
                }.padding(6)
            }

            GroupBox("2. Print and reinsert the test stack") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Print odd pages first with one-sided printing. Reinsert the stack, then print even pages. Adjust the settings below until page 2 is behind page 1 and page 4 is behind page 3, both upright.")
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
                }.padding(6)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Save Calibrated Profile") {
                    model.editableProfile.lastCalibrated = Date()
                    model.saveProfile()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 650)
    }

    private func createCalibrationPDF() {
        do {
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            generatedURL = try PDFService().createCalibrationPDF(in: directory)
            if let generatedURL { NSWorkspace.shared.open(generatedURL) }
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}
