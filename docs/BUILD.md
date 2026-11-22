# Build and Install

## Tauri app (macOS / Windows / Linux)

### Requirements

- Node.js 20+
- Rust stable toolchain
- Platform WebView / packaging deps (see [`desktop/README.md`](../desktop/README.md))
- A configured system printer
- Windows: run `desktop/scripts/download-sumatra.sh` before release builds

### Develop

```sh
cd desktop
npm install
npm run tauri dev
```

### Test

```sh
cd desktop/src-tauri
cargo test
```

### Release build

```sh
cd desktop
npm run tauri build
```

Artifacts appear under `desktop/src-tauri/target/release/bundle/`.

CI: [`.github/workflows/tauri.yml`](../.github/workflows/tauri.yml) builds on macOS, Ubuntu, and Windows.

## Legacy Swift macOS app

### Requirements

- macOS 14 or later
- Xcode 16 or later with the Xcode license accepted
- A printer configured in **System Settings → Printers & Scanners**
- No App Sandbox (CUPS + arbitrary PDF paths)

### Build

```sh
swift test
./scripts/build-app.sh release
open "dist/PDF Duplex Batch Printer.app"
```

Without `SIGN_IDENTITY`, the build script ad-hoc signs the bundle. Fixed signing:

```sh
SIGN_IDENTITY="DuplexBatchPrinter Signing" ./scripts/build-app.sh release
```

`.github/workflows/build.yml` still builds the Swift app for macOS reference releases.

### Source layout

- `desktop/` — Tauri 2 + React + Rust (cross-platform)
- `Sources/PDFDuplexBatchPrinter/` — SwiftUI reference app
- `Tests/PDFDuplexBatchPrinterTests/` — Swift tests
- `docs/` — product documentation
