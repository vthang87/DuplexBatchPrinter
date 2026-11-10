# Build and Install

## Requirements

- macOS 14 or later.
- Xcode 16 or later with the Xcode license accepted.
- A printer configured in **System Settings → Printers & Scanners**.
- The app runs without App Sandbox because it submits and monitors jobs through CUPS.

## Build in Terminal

From the project directory:

```sh
swift test
./scripts/build-app.sh release
open "dist/PDF Duplex Batch Printer.app"
```

The release script creates and ad-hoc signs the complete app bundle at:

```text
dist/PDF Duplex Batch Printer.app
```

## Build in Xcode

1. Open `Package.swift` in Xcode.
2. Select the `PDFDuplexBatchPrinter` scheme and **My Mac**.
3. Build and run with `Command-R`.

## Source Layout

- `Sources/PDFDuplexBatchPrinter/` — SwiftUI application, PDFKit processing, CUPS integration, cache, and print coordinator.
- `Tests/PDFDuplexBatchPrinterTests/` — planner, PDF/image generation, CUPS, cache, notification, and coordinator tests.
- `Resources/` — app icon and `Info.plist`.
- `scripts/build-app.sh` — release app bundle builder.
- `docs/` — handoff documentation.

## Clean Rebuild

Build artifacts are not required in the source copy. Swift Package Manager recreates `.build/` automatically when running `swift build` or `swift test`.
