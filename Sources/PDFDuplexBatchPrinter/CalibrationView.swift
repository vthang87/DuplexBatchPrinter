import AppKit
import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var generatedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("calibration.title")).font(.title.bold())
            Text(L10n.tr("calibration.intro"))
                .foregroundStyle(.secondary)

            GroupBox(L10n.tr("calibration.step1")) {
                HStack {
                    Text(L10n.tr("calibration.step1.detail"))
                    Spacer()
                    Button(L10n.tr("calibration.createPDF")) { createCalibrationPDF() }
                }.padding(6)
            }

            GroupBox(L10n.tr("calibration.step2")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("calibration.step2.detail"))
                    ProfileOrderPickers(profile: $model.editableProfile)
                }.padding(6)
            }

            HStack {
                Button(L10n.tr("common.cancel")) { isPresented = false }
                Spacer()
                Button(L10n.tr("calibration.save")) {
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
