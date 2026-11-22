# User Guide

This guide applies to the Tauri desktop app (`desktop/`) on macOS, Windows, and Linux, and to the legacy Swift macOS app. Print submission uses CUPS on macOS/Linux and SumatraPDF on Windows; the Odd → flip → Even workflow is the same.

## PDF Queue

1. Select **PDFs**.
2. Add or drag multiple PDF files into the queue.
3. Arrange the files with the arrow controls.
4. Select the installed printer and saved profile.
5. Start the batch. Each PDF runs Odd → paper flip confirmation → Even before the next PDF begins.

The default profile prints both passes in reverse order. For a nine-page PDF, the order is Odd `9, 7, 5, 3, 1`, then Even `10, 8, 6, 4, 2`, where page 10 is intentional blank padding. After the Odd pass, turn the whole stack over and put it back in the tray without re-sorting: the sheet with page 9 feeds first and receives page 10, and the sheet with page 1 feeds last and receives page 2.

### Combined Mode: Flip Once

Set **PDF batch mode** to **All files, flip once** to print every PDF in the queue with a single paper flip:

1. The Odd pages of all files print as one job.
2. Turn the whole stack over once and reinsert it without re-sorting.
3. The Even pages of all files print as one job.

Each file is padded to an even page count, so every file starts on the front of a new sheet and the finished stack separates cleanly into one set per file, in queue order. No separator sheet is added. If every file has only one page, the batch finishes without a flip. Retry, Skip, and Cancel apply to the whole combined batch.

## Image Queue

1. Select **Images**.
2. Add or drag images into the queue. Each image is one printed page.
3. Choose **1 mặt** or **2 mặt**.
4. Arrange images with the arrow controls. In one-sided mode, each image is submitted sequentially so every row updates from Ready → Printing → Completed in real time.
5. Start the batch.

Images are aspect-fitted and centered on the selected A4 or Letter paper without cropping.

## Preview and Ordering

- Switch between **List** and **Thumbnails** above the queue.
- Press **Preview** at the top to start from the first item.
- Press the eye button on a row or thumbnail to preview that item directly.
- Use **Previous** and **Next** in the preview window to verify the full order.
- Thumbnail cards show the queue position number, filename, status (plus page count for PDFs or page number for images), move controls, and remove control.

## Manual Duplex

When the Odd pass finishes, the app displays an alert and macOS notification. Reinsert the stack using the saved profile instruction, then confirm **Paper Reinserted — Print Even**.

A one-page PDF or one-image duplex list completes without asking for a paper flip. Odd-length jobs with three or more pages include a forced blank page so the final sheet passes through the Even run. With the default order this blank is printed first, on the back of the last page, and the flip instruction reminds you to keep that sheet in the stack. If it is removed, every remaining back page shifts onto the wrong sheet.

## Language

Use the globe menu in the toolbar to choose **System language**, **English**, or **Tiếng Việt**. The interface switches immediately and the choice is remembered. Paper-flip notifications and error messages follow the same setting. CUPS job titles stay in English.

## Saved Data

The app restores queues after relaunch using macOS file bookmarks. Data is stored under:

```text
~/Library/Application Support/PDFDuplexBatchPrinter/
```

- `pdf-queue.json` — PDF queue and order.
- `image-queue.json` — image queue and order.
- `printer-profiles.json` — saved printer profiles.

If an original file is missing, its row remains visible and printing is disabled until the queue is corrected.

## Error Recovery

- **Retry** retries the failed file or image.
- **Skip File** skips the failed item and continues.
- **Cancel** stops the batch and asks CUPS to cancel the active job.

For one-sided images, retry resumes at the failed image and does not reprint images already marked Completed.

For a PDF, or a two-sided image list, retry restarts that file (or the whole image list) from the Odd pass, even if the error happened during the Even pass. Remove any partially printed sheets before retrying.
