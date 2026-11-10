import AppKit
import PDFKit
import XCTest
@testable import PDFDuplexBatchPrinter

final class PDFServiceTests: XCTestCase {
    func testCreatesOneFittedPDFPagePerImageInListOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let redURL = try makePNG(named: "01-red.png", color: red, size: NSSize(width: 400, height: 200), in: directory)
        let blueURL = try makePNG(named: "02-blue.png", color: blue, size: NSSize(width: 200, height: 400), in: directory)
        let outputURL = try PDFService().makeImageDocument(
            sourceURLs: [redURL, blueURL],
            paperSize: .a4,
            temporaryDirectory: directory
        )

        let document = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size.width ?? 0, 595, accuracy: 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size.height ?? 0, 842, accuracy: 1)
        XCTAssertTrue(containsColor(red, in: try XCTUnwrap(document.page(at: 0))))
        XCTAssertTrue(containsColor(blue, in: try XCTUnwrap(document.page(at: 1))))
    }

    func testCreatesPassInPlannedOrderAndRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pdf")
        let source = PDFDocument()
        for index in 0..<3 {
            let image = NSImage(size: NSSize(width: 200, height: 300))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            "Page \(index + 1)".draw(at: NSPoint(x: 40, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            image.unlockFocus()
            source.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(source.write(to: sourceURL))

        let resultURL = try PDFService().makePass(
            sourceURL: sourceURL,
            pages: [PlannedPage(sourcePage: 3), PlannedPage(sourcePage: nil), PlannedPage(sourcePage: 1)],
            rotation: .rotate180,
            temporaryDirectory: directory,
            label: "test"
        )
        let result = try XCTUnwrap(PDFDocument(url: resultURL))
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.page(at: 0)?.rotation, 180)
        XCTAssertEqual(result.page(at: 1)?.rotation, 180)
    }

    func testFlattensVisibleInkAnnotationsIntoPrintablePageContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("annotated-solution.pdf")
        let image = NSImage(size: NSSize(width: 200, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))

        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 130, width: 160, height: 40),
            forType: .ink,
            withProperties: nil
        )
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5, y: 20))
        path.line(to: NSPoint(x: 155, y: 20))
        annotation.add(path)
        annotation.color = .red
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 12
        page.addAnnotation(annotation)

        let source = PDFDocument()
        source.insert(page, at: 0)
        XCTAssertTrue(containsRedPixel(in: page), "The test source annotation must be visible before flattening")
        XCTAssertTrue(source.write(to: sourceURL))

        let outputURL = try PDFService().makePass(
            sourceURL: sourceURL,
            pages: [PlannedPage(sourcePage: 1)],
            rotation: .none,
            temporaryDirectory: directory,
            label: "flattened"
        )
        let output = try XCTUnwrap(PDFDocument(url: outputURL))
        let outputPage = try XCTUnwrap(output.page(at: 0))
        XCTAssertTrue(outputPage.annotations.isEmpty)

        XCTAssertTrue(containsRedPixel(in: outputPage), "The visible solution annotation must remain in flattened printable content")
    }

    private func containsRedPixel(in page: PDFPage) -> Bool {
        let thumbnail = page.thumbnail(of: NSSize(width: 200, height: 300), for: .mediaBox)
        guard let data = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return false }
        var foundRedPixel = false
        for y in 0..<bitmap.pixelsHigh where !foundRedPixel {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                    foundRedPixel = true
                    break
                }
            }
        }
        return foundRedPixel
    }

    private func makePNG(named name: String, color: NSColor, size: NSSize, in directory: URL) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func containsColor(_ target: NSColor, in page: PDFPage) -> Bool {
        let thumbnail = page.thumbnail(of: NSSize(width: 160, height: 220), for: .mediaBox)
        guard let data = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let targetRGB = target.usingColorSpace(.deviceRGB) else { return false }
        var closest: (distance: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat) = (.greatestFiniteMagnitude, 0, 0, 0)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(color.redComponent - targetRGB.redComponent)
                    + abs(color.greenComponent - targetRGB.greenComponent)
                    + abs(color.blueComponent - targetRGB.blueComponent)
                if distance < closest.distance {
                    closest = (distance, color.redComponent, color.greenComponent, color.blueComponent)
                }
                if distance < 0.6 { return true }
            }
        }
        print("Closest rendered color: r=\(closest.red) g=\(closest.green) b=\(closest.blue), distance=\(closest.distance)")
        return false
    }
}
