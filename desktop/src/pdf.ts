import { convertFileSrc } from "@tauri-apps/api/core";
// The legacy build carries polyfills for older WebKit (macOS 12 webviews).
import {
  getDocument,
  GlobalWorkerOptions,
  type PDFDocumentProxy,
} from "pdfjs-dist/legacy/build/pdf.mjs";
import workerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";

GlobalWorkerOptions.workerSrc = workerUrl;

/**
 * Loads a local PDF through Tauri's asset protocol. pdf.js renders in every
 * webview, including WebKitGTK on Linux, which cannot show PDFs in an iframe.
 */
export async function loadPdf(path: string): Promise<PDFDocumentProxy> {
  const response = await fetch(convertFileSrc(path));
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const data = new Uint8Array(await response.arrayBuffer());
  return getDocument({ data }).promise;
}

/** Renders one page into a canvas, fitting `maxWidth` CSS pixels. */
export async function renderPage(
  doc: PDFDocumentProxy,
  pageNumber: number,
  canvas: HTMLCanvasElement,
  maxWidth: number,
): Promise<void> {
  const page = await doc.getPage(pageNumber);
  const base = page.getViewport({ scale: 1 });
  const ratio = window.devicePixelRatio || 1;
  const scale = (maxWidth / base.width) * ratio;
  const viewport = page.getViewport({ scale });
  canvas.width = Math.floor(viewport.width);
  canvas.height = Math.floor(viewport.height);
  canvas.style.width = `${Math.floor(viewport.width / ratio)}px`;
  canvas.style.height = `${Math.floor(viewport.height / ratio)}px`;
  await page.render({ canvas, viewport }).promise;
}

const thumbnailCache = new Map<string, Promise<string>>();

/** First-page thumbnail as a data URL, cached per path. */
export function pdfThumbnail(path: string, width = 360): Promise<string> {
  let cached = thumbnailCache.get(path);
  if (!cached) {
    cached = (async () => {
      const doc = await loadPdf(path);
      try {
        const canvas = document.createElement("canvas");
        await renderPage(doc, 1, canvas, width);
        return canvas.toDataURL("image/png");
      } finally {
        void doc.destroy();
      }
    })();
    cached.catch(() => thumbnailCache.delete(path));
    thumbnailCache.set(path, cached);
  }
  return cached;
}
