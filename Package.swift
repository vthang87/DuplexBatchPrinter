// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFDuplexBatchPrinter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PDFDuplexBatchPrinter", targets: ["PDFDuplexBatchPrinter"])
    ],
    targets: [
        .executableTarget(
            name: "PDFDuplexBatchPrinter",
            path: "Sources/PDFDuplexBatchPrinter",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PDFDuplexBatchPrinterTests",
            dependencies: ["PDFDuplexBatchPrinter"],
            path: "Tests/PDFDuplexBatchPrinterTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
