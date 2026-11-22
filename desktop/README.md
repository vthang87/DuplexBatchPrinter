# PDF Duplex Batch Printer (Tauri)

Cross-platform desktop app (macOS, Windows, Linux) built with Tauri 2, Rust, and React.

The Swift macOS app under `../Sources` remains available as a frozen reference until this app fully replaces it.

## Requirements

- Node.js 20+
- Rust stable
- macOS 12+ / Windows 10+ / Linux with WebKitGTK 4.1 and CUPS
- At least one system printer

### Linux packages (Debian/Ubuntu)

```sh
sudo apt-get install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf libcups2-dev cups
```

### Windows SumatraPDF

Silent PDF printing on Windows needs SumatraPDF:

```sh
bash scripts/download-sumatra.sh
```

See `src-tauri/resources/windows/THIRD_PARTY.md` for licensing.

## Develop

```sh
npm install
npm run tauri dev
```

## Test

```sh
cd src-tauri && cargo test
```

## Build

```sh
npm run tauri build
```

Bundles land under `src-tauri/target/release/bundle/`.

## Architecture

- Rust core: duplex planner, PDF pass/merge/image/calibration, batch coordinator, profile/queue stores
- Print backends: CUPS (`lp`/`lpstat`/`cancel`) on macOS & Linux; SumatraPDF + spooler on Windows
- React UI: queue, profiles, flip modal, EN/VI i18n
