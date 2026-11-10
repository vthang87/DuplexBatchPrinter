# User Guide

## PDF Queue

1. Select **PDFs**.
2. Add or drag multiple PDF files into the queue.
3. Arrange the files with the arrow controls.
4. Select the installed printer and saved profile.
5. Start the batch. Each PDF runs Odd → paper flip confirmation → Even before the next PDF begins.

The default profile prints Odd pages in reverse order and Even pages in normal order. For a nine-page PDF, the order is Odd `9, 7, 5, 3, 1`, then Even `2, 4, 6, 8, 10`, where page 10 is intentional blank padding.

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

A one-page PDF or one-image duplex list completes without asking for a paper flip. Odd-length jobs with three or more pages include a forced blank page so the final sheet passes through the Even run.

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
