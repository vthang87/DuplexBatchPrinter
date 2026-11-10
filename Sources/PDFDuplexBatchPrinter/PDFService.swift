import AppKit
import Foundation
import PDFKit

enum PDFServiceError: LocalizedError {
    case cannotOpen(URL)
    case cannotOpenImage(URL)
    case emptyImageList
    case emptyDocument(URL)
    case cannotCreatePage
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): "Cannot open \(url.lastPathComponent)."
        case .cannotOpenImage(let url): "Cannot open image \(url.lastPathComponent)."
        case .emptyImageList: "Add at least one image before printing."
        case .emptyDocument(let url): "\(url.lastPathComponent) has no pages."
        case .cannotCreatePage: "Cannot create a blank PDF page."
        case .cannotWrite(let url): "Cannot write temporary PDF at \(url.path)."
        }
    }
}

struct PDFService {
    func validateImage(at url: URL) throws {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw PDFServiceError.cannotOpenImage(url)
        }
    }

    func pageCount(at url: URL) throws -> Int {
        guard let document = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen(url) }
        guard document.pageCount > 0 else { throw PDFServiceError.emptyDocument(url) }
        return document.pageCount
    }

    func makePass(
        sourceURL: URL,
        pages: [PlannedPage],
        rotation: PaperRotation,
        temporaryDirectory: URL,
        label: String
    ) throws -> URL {
        guard let source = PDFDocument(url: sourceURL) else { throw PDFServiceError.cannotOpen(sourceURL) }
        guard source.pageCount > 0 else { throw PDFServiceError.emptyDocument(sourceURL) }

        let output = PDFDocument()
        let referenceBounds = source.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)

        for (index, planned) in pages.enumerated() {
            let page: PDFPage
            if let number = planned.sourcePage, let sourcePage = source.page(at: number - 1) {
                // Flatten visible annotations into the page content. Some printer
                // drivers omit PDF annotation layers even when their Print flag is
                // set, which makes a marked solution sheet print like its blank exam.
                page = try flattenedPage(from: sourcePage)
            } else {
                page = try blankPage(size: referenceBounds.size)
            }
            if rotation == .rotate180 { page.rotation = (page.rotation + 180) % 360 }
            output.insert(page, at: index)
        }

        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let destination = temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeLabel).pdf")
        guard output.write(to: destination) else { throw PDFServiceError.cannotWrite(destination) }
        return destination
    }

    func makeImageDocument(
        sourceURLs: [URL],
        paperSize: PaperSize,
        temporaryDirectory: URL,
        label: String = "images"
    ) throws -> URL {
        guard !sourceURLs.isEmpty else { throw PDFServiceError.emptyImageList }
        let output = PDFDocument()
        let pageSize = paperSize.pdfPageSize

        for (index, url) in sourceURLs.enumerated() {
            guard let sourceImage = NSImage(contentsOf: url),
                  sourceImage.size.width > 0, sourceImage.size.height > 0 else {
                throw PDFServiceError.cannotOpenImage(url)
            }
            let pageImage = NSImage(size: pageSize)
            pageImage.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: pageSize).fill()
            let available = NSRect(origin: .zero, size: pageSize).insetBy(dx: 18, dy: 18)
            let scale = min(available.width / sourceImage.size.width, available.height / sourceImage.size.height)
            let fittedSize = NSSize(width: sourceImage.size.width * scale, height: sourceImage.size.height * scale)
            let destination = NSRect(
                x: available.midX - fittedSize.width / 2,
                y: available.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            sourceImage.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            pageImage.unlockFocus()
            guard let page = PDFPage(image: pageImage) else { throw PDFServiceError.cannotCreatePage }
            output.insert(page, at: index)
        }

        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let destination = temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeLabel).pdf")
        guard output.write(to: destination) else { throw PDFServiceError.cannotWrite(destination) }
        return destination
    }

    func createCalibrationPDF(in directory: URL) throws -> URL {
        let document = PDFDocument()
        for number in 1...4 {
            let image = NSImage(size: NSSize(width: 595, height: 842))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            let title = number.isMultiple(of: 2) ? "BACK \(number)" : "FRONT \(number)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            title.draw(at: NSPoint(x: 150, y: 410), withAttributes: attributes)
            "TOP OF SHEET ↑".draw(at: NSPoint(x: 190, y: 770), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.systemRed
            ])
            "Calibration page \(number) of 4".draw(at: NSPoint(x: 190, y: 60), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.darkGray
            ])
            image.unlockFocus()
            guard let page = PDFPage(image: image) else { throw PDFServiceError.cannotCreatePage }
            document.insert(page, at: number - 1)
        }
        let destination = directory.appendingPathComponent("Duplex-Calibration.pdf")
        guard document.write(to: destination) else { throw PDFServiceError.cannotWrite(destination) }
        return destination
    }

    private func blankPage(size: CGSize) throws -> PDFPage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        // A near-white 1pt feed marker prevents CUPS/printer pipelines from
        // optimizing away this intentional padding page. It sits inside the
        // unprintable edge and is visually imperceptible on paper.
        NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
        NSRect(x: 4, y: 4, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw PDFServiceError.cannotCreatePage }
        return page
    }

    private func flattenedPage(from sourcePage: PDFPage) throws -> PDFPage {
        let sourceBounds = sourcePage.bounds(for: .mediaBox)
        var mediaBox = CGRect(origin: .zero, size: sourceBounds.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFServiceError.cannotCreatePage
        }

        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)
        sourcePage.draw(with: .mediaBox, to: context)
        for annotation in sourcePage.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: context)
        }
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data),
              let page = document.page(at: 0) else {
            throw PDFServiceError.cannotCreatePage
        }
        return page
    }
}

private extension PaperSize {
    var pdfPageSize: NSSize {
        switch self {
        case .a4: NSSize(width: 595, height: 842)
        case .letter: NSSize(width: 612, height: 792)
        }
    }
}
