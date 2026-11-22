import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { convertFileSrc } from "@tauri-apps/api/core";
import { openPath } from "@tauri-apps/plugin-opener";
import { loadPdf, pdfThumbnail, renderPage } from "./pdf";
import type { ImageQueueItem, Localized, PdfQueueItem, PrinterProfile } from "./types";

export function fileName(path: string): string {
  return path.split(/[/\\]/).pop() ?? path;
}

export function isPdfPath(path: string): boolean {
  return /\.pdf$/i.test(path);
}

/** Translates backend `Localized` values and arbitrary thrown errors. */
export function useTr() {
  const { t } = useTranslation();
  const tr = useCallback(
    (value: Localized): string =>
      value.key === "raw"
        ? (value.params.text ?? "")
        : t(value.key, { ...value.params, defaultValue: value.key }),
    [t],
  );
  const errText = useCallback(
    (err: unknown): string => {
      if (err && typeof err === "object" && "key" in err && "params" in err) {
        return tr(err as Localized);
      }
      return String(err);
    },
    [tr],
  );
  return { tr, errText };
}

/** Odd/even order, reinsertion rotation and binding edge, shared by the profile editor and calibration. */
export function ProfileOrderFields({
  profile,
  disabled,
  onChange,
}: {
  profile: PrinterProfile;
  disabled: boolean;
  onChange: (next: PrinterProfile) => void;
}) {
  const { t } = useTranslation();
  return (
    <>
      <label className="field">
        <span>{t("profile.oddOrder")}</span>
        <select
          value={profile.oddOrder}
          disabled={disabled}
          onChange={(e) =>
            onChange({ ...profile, oddOrder: e.target.value as PrinterProfile["oddOrder"] })
          }
        >
          <option value="normal">{t("pageOrder.normal")}</option>
          <option value="reversed">{t("pageOrder.reversed")}</option>
        </select>
      </label>
      <label className="field">
        <span>{t("profile.evenOrder")}</span>
        <select
          value={profile.evenOrder}
          disabled={disabled}
          onChange={(e) =>
            onChange({ ...profile, evenOrder: e.target.value as PrinterProfile["evenOrder"] })
          }
        >
          <option value="normal">{t("pageOrder.normal")}</option>
          <option value="reversed">{t("pageOrder.reversed")}</option>
        </select>
      </label>
      <label className="field">
        <span>{t("profile.rotation")}</span>
        <select
          value={profile.evenRotation}
          disabled={disabled}
          onChange={(e) =>
            onChange({
              ...profile,
              evenRotation: e.target.value as PrinterProfile["evenRotation"],
            })
          }
        >
          <option value="none">{t("rotation.none")}</option>
          <option value="rotate180">{t("rotation.rotate180")}</option>
        </select>
      </label>
      <label className="field">
        <span>{t("profile.bindingEdge")}</span>
        <select
          value={profile.flipEdge}
          disabled={disabled}
          onChange={(e) =>
            onChange({ ...profile, flipEdge: e.target.value as PrinterProfile["flipEdge"] })
          }
        >
          <option value="longEdge">{t("flipEdge.long")}</option>
          <option value="shortEdge">{t("flipEdge.short")}</option>
        </select>
      </label>
    </>
  );
}

/** Thumbnail of a queue item: first PDF page via pdf.js, or the image itself. */
function FileThumbnail({ path, label }: { path: string; label: string }) {
  const [src, setSrc] = useState<string | null>(isPdfPath(path) ? null : convertFileSrc(path));
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!isPdfPath(path)) {
      setSrc(convertFileSrc(path));
      return;
    }
    let cancelled = false;
    setSrc(null);
    setFailed(false);
    pdfThumbnail(path)
      .then((url) => !cancelled && setSrc(url))
      .catch(() => !cancelled && setFailed(true));
    return () => {
      cancelled = true;
    };
  }, [path]);

  if (failed || !src) {
    return <div className="thumb-placeholder">{failed ? "📄" : "…"}</div>;
  }
  return (
    <img
      className="thumb-image"
      src={src}
      alt={label}
      loading="lazy"
      onError={() => setFailed(true)}
    />
  );
}

export function ThumbnailGrid({
  items,
  isImages,
  locked,
  statusText,
  onPreview,
  onMove,
  onRemove,
}: {
  items: Array<PdfQueueItem | ImageQueueItem>;
  isImages: boolean;
  locked: boolean;
  statusText: (status: string) => string;
  onPreview: (index: number) => void;
  onMove: (index: number, direction: -1 | 1) => void;
  onRemove: (index: number) => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="thumb-grid">
      {items.map((item, index) => {
        const name = fileName(item.path);
        const detail = [
          isImages
            ? t("queue.pageNumber", { count: index + 1 })
            : t("queue.pageCount", { count: (item as PdfQueueItem).pageCount }),
          statusText(item.status),
        ].join(" · ");
        return (
          <div key={item.id} className="thumb-card">
            <button
              type="button"
              className="thumb-visual"
              title={t("queue.preview")}
              onClick={() => onPreview(index)}
            >
              <FileThumbnail path={item.path} label={name} />
              <span className="thumb-index">{index + 1}</span>
            </button>
            <span title={name}>{name}</span>
            <small className={item.status}>{detail}</small>
            <div className="thumb-actions">
              <button
                type="button"
                className="btn btn-icon"
                title={t("queue.preview")}
                aria-label={t("queue.preview")}
                onClick={() => onPreview(index)}
              >
                👁
              </button>
              <span className="spacer" />
              <button
                type="button"
                className="btn btn-icon"
                title={t("queue.moveEarlier")}
                aria-label={t("queue.moveEarlier")}
                disabled={locked || index === 0}
                onClick={() => onMove(index, -1)}
              >
                ←
              </button>
              <button
                type="button"
                className="btn btn-icon"
                title={t("queue.moveLater")}
                aria-label={t("queue.moveLater")}
                disabled={locked || index === items.length - 1}
                onClick={() => onMove(index, 1)}
              >
                →
              </button>
              <button
                type="button"
                className="btn btn-icon danger"
                title={t("queue.remove")}
                aria-label={t("queue.remove")}
                disabled={locked}
                onClick={() => onRemove(index)}
              >
                🗑
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}

/** Renders every page of a PDF with pdf.js, one canvas per page. */
function PdfPages({ path }: { path: string }) {
  const { t } = useTranslation();
  const container = useRef<HTMLDivElement>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "failed">("loading");

  useEffect(() => {
    let cancelled = false;
    const host = container.current;
    if (!host) return;
    host.replaceChildren();
    setStatus("loading");
    void (async () => {
      try {
        const doc = await loadPdf(path);
        if (cancelled) return void doc.destroy();
        const width = Math.min(host.clientWidth - 32, 900);
        setStatus("ready");
        for (let page = 1; page <= doc.numPages && !cancelled; page += 1) {
          const canvas = document.createElement("canvas");
          canvas.className = "preview-page";
          host.appendChild(canvas);
          await renderPage(doc, page, canvas, width);
        }
        void doc.destroy();
      } catch {
        if (!cancelled) setStatus("failed");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [path]);

  return (
    <div className="preview-scroll">
      {status === "loading" && <p className="preview-note">{t("preview.loading")}</p>}
      {status === "failed" && <p className="preview-note">{t("preview.unavailable")}</p>}
      <div ref={container} className="preview-pages" />
    </div>
  );
}

export function PreviewModal({
  paths,
  initialIndex,
  onClose,
}: {
  paths: string[];
  initialIndex: number;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [index, setIndex] = useState(initialIndex);
  const [imageFailed, setImageFailed] = useState(false);
  const path = paths[Math.min(index, paths.length - 1)];

  useEffect(() => setImageFailed(false), [path]);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape" || event.key === "Enter") onClose();
      if (event.key === "ArrowLeft") setIndex((i) => Math.max(0, i - 1));
      if (event.key === "ArrowRight") setIndex((i) => Math.min(paths.length - 1, i + 1));
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, paths.length]);

  if (!path) return null;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div
        className="modal preview-modal"
        role="dialog"
        aria-modal="true"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="preview-bar">
          <div className="preview-title">
            <strong>{fileName(path)}</strong>
            <small>
              {t("preview.position", { index: index + 1, total: paths.length })}
            </small>
          </div>
          <button className="btn" disabled={index === 0} onClick={() => setIndex(index - 1)}>
            ‹ {t("preview.previous")}
          </button>
          <button
            className="btn"
            disabled={index === paths.length - 1}
            onClick={() => setIndex(index + 1)}
          >
            {t("preview.next")} ›
          </button>
          <button className="btn" onClick={() => void openPath(path)}>
            {t("preview.openExternal")}
          </button>
          <button className="btn btn-primary" onClick={onClose}>
            {t("common.done")}
          </button>
        </div>
        {isPdfPath(path) ? (
          <PdfPages path={path} />
        ) : imageFailed ? (
          <div className="preview-scroll">
            <p className="preview-note">{t("preview.unavailable")}</p>
          </div>
        ) : (
          <div className="preview-scroll">
            <img
              className="preview-image"
              src={convertFileSrc(path)}
              alt={fileName(path)}
              onError={() => setImageFailed(true)}
            />
          </div>
        )}
      </div>
    </div>
  );
}
