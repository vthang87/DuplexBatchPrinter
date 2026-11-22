# PDF Duplex Batch Printer

Batch-print PDFs and image lists on a simplex printer with a controlled manual-duplex workflow:

`PDF 1 odd → wait for paper flip → PDF 1 even → PDF 2 odd → …`

## Cross-platform app (recommended)

The primary app is a **Tauri 2** desktop client under [`desktop/`](desktop/) (Rust + React). It targets **macOS, Windows, and Linux**.

```sh
cd desktop
npm install
npm run tauri dev
```

Tests: `cd desktop/src-tauri && cargo test`  
Full build notes: [`desktop/README.md`](desktop/README.md) and [`docs/BUILD.md`](docs/BUILD.md).

Print backends:

- macOS / Linux: CUPS (`lp`, `lpstat`, `cancel`)
- Windows: bundled SumatraPDF silent print + spooler polling

## Legacy macOS Swift app (reference)

The SwiftUI / PDFKit / CUPS app under `Sources/` is frozen as a behavioral reference until the Tauri app reaches full parity. It still builds:

### Requirements (Swift)

- macOS 14 or later
- Xcode 16 or later
- At least one printer configured in **System Settings → Printers & Scanners**
- No App Sandbox (CUPS + arbitrary PDF paths)

### Build (Swift)

```sh
swift build
swift run PDFDuplexBatchPrinter
./scripts/build-app.sh release
open "dist/PDF Duplex Batch Printer.app"
swift test
```

## First-use workflow

1. Add several PDFs with **Add PDFs** or drag them into the queue.
2. Arrange them with the arrow buttons or the list move command. The visible order is the print order.
3. Select a printer already installed in macOS.
4. Create a printer profile. Choose paper, color, odd/even output order, reinsertion rotation, and binding edge.
5. Open **Calibrate…**, create the four-page marked PDF, and test the physical paper path. Adjust the profile until pages 2/4 appear upright behind pages 1/3, then save it as calibrated.
6. Select the saved profile and press **Start Batch Print**.
7. After CUPS reports the odd pass complete, follow the reinsertion instruction and press **Paper Reinserted — Print Even**.

To print the whole queue with a single paper flip, set **PDF batch mode** to **All files, flip once**. All Odd pages print as one job, the stack is turned over once, then all Even pages print. Each file is padded to an even length, so every file starts on a new sheet and the output separates into one set per file.

### Printing an image list

1. Select **Images** above the queue, then use **Add Images** or drag images into the list.
2. Arrange the images; each row is one printed page and the visible row number is its page number.
3. Choose **1 mặt** to submit one one-sided job per image, sequentially in list order (each row turns Completed as its job finishes), or **2 mặt** to use the same Odd → flip → Even workflow as PDFs.
4. Images are aspect-fitted and centered on the selected A4 or Letter paper without cropping.

The image list and its order are cached separately in `~/Library/Application Support/PDFDuplexBatchPrinter/image-queue.json` and restored on launch.

When the odd pass completes, the app shows a modal paper-flip alert and sends a macOS notification with sound. Notification permission is requested once. Selecting the notification brings the app forward; printing the even pass still requires explicit confirmation in the app.

The queue is locked while printing. An error pauses the batch and offers **Retry**, **Skip File**, or **Cancel**. Cancel also asks CUPS to cancel the active job.

New profiles default to **Odd pass: Reverse** and **Even pass: Reverse**. Turning the whole odd stack over reverses the sheet order, so both passes must run in the same direction for the stack to go back in without re-sorting. Existing custom profiles keep their saved order; a saved profile named `Default profile` is migrated once from the former orders.

The PDF list and its order are cached automatically in `~/Library/Application Support/PDFDuplexBatchPrinter/pdf-queue.json`. The app restores the queue on launch and uses macOS file bookmarks to retain file references. If an original PDF is deleted or unavailable, the row stays visible as **Original file not found** instead of silently disappearing.

Before submission, each selected page is flattened so visible PDF annotations (ink, teacher markings, and solution overlays) become normal printable page content. This prevents printer drivers from silently dropping answer layers and printing only the underlying exercise sheet.

Odd-length documents with 3 or more pages include a forced blank padding page so every sheet passes through the Even run. A one-page document completes after Odd and does not prompt for a paper flip.

For an odd-length document, the app first pads the document to the next even page number, then applies the Odd and Even order independently. With the default profile, a 9-page file prints Odd as `9, 7, 5, 3, 1`, then Even as `10, 8, 6, 4, 2`; page 10 is the forced blank page and lands on the back of the page-9 sheet, which feeds first after the stack is turned over.

## Localization

The UI is available in English and Vietnamese. Strings live in `Sources/PDFDuplexBatchPrinter/Resources/{en,vi}.lproj/Localizable.strings` and are looked up through `L10n.tr(_:)` (`Localization.swift`), which honors the in-app language picker (System, English, Tiếng Việt) without relaunching. Persisted enum raw values and CUPS job titles stay in English. `LocalizationTests` checks that both languages define the same keys and format placeholders. To add a language, add a new `.lproj` folder, extend `AppLanguage` and `L10n.supportedLanguageCodes`, and list it in `CFBundleLocalizations` in `Resources/Info.plist`.

## Profiles and macOS presets

macOS does not expose every driver-owned Print dialog preset through a stable public API. For reliable unattended batches, this app stores its own per-printer profiles and applies the same profile to every file and both passes. It always forces these safety options:

- `sides=one-sided`
- `copies=1`
- `number-up=1`

The model supports additional CUPS key/value options in `PrinterProfile.cupsOptions`; these are submitted as `-o key=value`. Driver-specific options can be inspected on a Mac with `lpoptions -p PRINTER_NAME -l` and added by extending the profile editor.

## Safety notes

- Start with a small calibration document before using important paper.
- CUPS completion means the spooler considers the job complete; it cannot verify how the physical stack was placed back into the tray.
- Some printer drivers remove completed jobs from CUPS history immediately. The app confirms that a job is absent from the active queue twice before treating that removal as completion.
- Do not enable automatic duplex in the printer driver. The app deliberately forces one-sided output for each pass.
- Temporary odd/even PDFs are removed after each source file completes or fails.

## Source layout

- `Models.swift` — queue, printer profile, and batch state
- `DuplexPlanner.swift` — deterministic odd/even plan with forced blank-page padding so every sheet passes through the printer
- `PDFService.swift` — PDFKit pass generation, image-to-page conversion, and calibration document
- `CUPSService.swift` — printer discovery, submission, monitoring, cancellation
- `BatchCoordinator.swift` — sequential state machine and error recovery
- `Stores.swift` — app model, per-printer profile storage, and selected printer/profile persistence
- `QueueCacheStore.swift` / `ImageQueueCacheStore.swift` — JSON caches for the PDF and image queues
- `FlipNotificationService.swift` — macOS notification for the paper-flip step
- `PDFDuplexBatchPrinterApp.swift` — app entry point
- `Localization.swift` and `Resources/*.lproj` — in-app language selection and English/Vietnamese strings
- `MainView.swift` / `CalibrationView.swift` — SwiftUI user interface
- `Tests/` — planner, PDF/image generation, CUPS parsing, queue cache, profile store, notification, and batch coordinator tests
