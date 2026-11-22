import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow, UserAttentionType } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { openPath } from "@tauri-apps/plugin-opener";
import {
  isPermissionGranted,
  requestPermission,
  sendNotification,
} from "@tauri-apps/plugin-notification";
import { resolveLanguage } from "./i18n";
import { QueueList } from "./QueueList";
import {
  PreviewModal,
  ProfileOrderFields,
  ThumbnailGrid,
  useTr,
} from "./Components";
import {
  AddResult,
  AppSettings,
  BatchState,
  ImageQueueItem,
  Localized,
  newProfile,
  PdfQueueItem,
  PrinterDescriptor,
  PrinterProfile,
  Snapshot,
} from "./types";
import "./App.css";

function statusKey(status: string): string {
  return `status.${status}`;
}

function isRunning(state: BatchState): boolean {
  return (
    state.kind === "preparing" ||
    state.kind === "printing" ||
    state.kind === "waitingForFlip" ||
    state.kind === "pausedOnError"
  );
}

export default function App() {
  const { t, i18n } = useTranslation();
  const { tr, errText } = useTr();
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [profiles, setProfiles] = useState<PrinterProfile[]>([]);
  const [pdfQueue, setPdfQueue] = useState<PdfQueueItem[]>([]);
  const [imageQueue, setImageQueue] = useState<ImageQueueItem[]>([]);
  const [printers, setPrinters] = useState<PrinterDescriptor[]>([]);
  const [batchState, setBatchState] = useState<BatchState>({ kind: "idle" });
  const [editable, setEditable] = useState<PrinterProfile>(newProfile(""));
  const [viewMode, setViewMode] = useState<"list" | "thumbnails">("list");
  const [showCalibration, setShowCalibration] = useState(false);
  const [calibrationNote, setCalibrationNote] = useState<string | null>(null);
  const [showFlipAlert, setShowFlipAlert] = useState(false);
  const [previewIndex, setPreviewIndex] = useState<number | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const queueContentRef = useRef<"pdfs" | "images">("pdfs");
  const runningRef = useRef(false);
  // The event listeners below are registered once; read translations through
  // a ref so they follow language changes.
  const trRef = useRef(tr);
  trRef.current = tr;
  const errTextRef = useRef(errText);
  errTextRef.current = errText;

  const applyLanguage = useCallback(
    (preference: string) => {
      void i18n.changeLanguage(resolveLanguage(preference));
    },
    [i18n],
  );

  const refresh = useCallback(async () => {
    const snap = await invoke<Snapshot>("get_snapshot");
    setSettings(snap.settings);
    setProfiles(snap.profiles);
    setPdfQueue(snap.pdfQueue);
    setImageQueue(snap.imageQueue);
    setPrinters(snap.printers);
    setBatchState(snap.batchState);
    applyLanguage(snap.settings.language);
    const matching = snap.profiles.filter(
      (p) => p.printerQueue === snap.settings.selectedPrinter,
    );
    const selected =
      matching.find((p) => p.id === snap.settings.selectedProfileId) ??
      matching[0] ??
      newProfile(snap.settings.selectedPrinter);
    setEditable(selected);
  }, [applyLanguage]);

  useEffect(() => {
    if (settings) queueContentRef.current = settings.queueContent;
  }, [settings]);

  useEffect(() => {
    runningRef.current = isRunning(batchState);
  }, [batchState]);

  /** Shows one message per file that could not be added. */
  const reportAddErrors = useCallback((errors: Localized[]) => {
    if (errors.length) {
      setError(errors.map((e) => trRef.current(e)).join("\n"));
    }
  }, []);

  useEffect(() => {
    // Vite may load the page outside the Tauri webview briefly; skip IPC then.
    if (typeof window === "undefined" || !("__TAURI_INTERNALS__" in window)) {
      return;
    }
    let cancelled = false;
    const unlisteners: Array<() => void> = [];

    void (async () => {
      try {
        setBusy("…");
        await refresh();
        const listed = await invoke<PrinterDescriptor[]>("list_printers");
        if (!cancelled) setPrinters(listed);
        // Ask once up front, like the Swift app, so the flip reminder can show.
        if (!(await isPermissionGranted())) await requestPermission();
      } catch (err) {
        if (!cancelled) setError(errTextRef.current(err));
      } finally {
        if (!cancelled) setBusy(null);
      }
    })();

    void listen<{
      kind: string;
      queue: PdfQueueItem[] | ImageQueueItem[];
      batchState: BatchState;
    }>("batch-update", (event) => {
      const next = event.payload.batchState;
      setBatchState(next);
      if (event.payload.kind === "pdf") {
        setPdfQueue(event.payload.queue as PdfQueueItem[]);
      } else {
        setImageQueue(event.payload.queue as ImageQueueItem[]);
      }
      if (next.kind === "waitingForFlip") {
        setShowFlipAlert(true);
        void getCurrentWindow().requestUserAttention(UserAttentionType.Critical);
        void (async () => {
          if (await isPermissionGranted()) {
            sendNotification({
              title: i18n.t("flip.title"),
              body: `${trRef.current(next.file)}\n${i18n.t("notification.flip.body")}`,
            });
          }
        })();
      } else if (
        next.kind === "idle" ||
        next.kind === "completed" ||
        next.kind === "cancelled"
      ) {
        setShowFlipAlert(false);
      }
    }).then((fn) => {
      if (cancelled) fn();
      else unlisteners.push(fn);
    });

    // Drag-drop files from Finder onto the window. Ignored while printing.
    void getCurrentWindow()
      .onDragDropEvent(async (event) => {
        if (event.payload.type !== "drop") return;
        const paths = event.payload.paths;
        if (!paths.length || runningRef.current) return;
        try {
          setBusy("…");
          if (queueContentRef.current === "images") {
            const result = await invoke<AddResult<ImageQueueItem>>("add_images", { paths });
            setImageQueue(result.queue);
            reportAddErrors(result.errors);
          } else {
            const result = await invoke<AddResult<PdfQueueItem>>("add_pdfs", { paths });
            setPdfQueue(result.queue);
            reportAddErrors(result.errors);
          }
        } catch (err) {
          setError(errTextRef.current(err));
        } finally {
          setBusy(null);
        }
      })
      .then((fn) => {
        if (cancelled) fn();
        else unlisteners.push(fn);
      });

    return () => {
      cancelled = true;
      for (const fn of unlisteners) fn();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const persistSettings = async (next: AppSettings) => {
    const saved = await invoke<AppSettings>("update_settings", { settings: next });
    setSettings(saved);
    applyLanguage(saved.language);
  };

  const matchingProfiles = useMemo(
    () =>
      profiles.filter((p) => p.printerQueue === (settings?.selectedPrinter ?? "")),
    [profiles, settings],
  );

  if (!settings) {
    return <div className="loading">Loading…</div>;
  }

  const isImages = settings.queueContent === "images";
  const activeQueue: Array<PdfQueueItem | ImageQueueItem> = isImages ? imageQueue : pdfQueue;
  const pageTotal = isImages
    ? imageQueue.length
    : pdfQueue.reduce((sum, item) => sum + item.pageCount, 0);
  const running = isRunning(batchState);
  const hasMissingFiles = activeQueue.some((item) => item.status === "missing");
  const profileLocked = !settings.selectedPrinter || running;

  const idleHint = isImages
    ? settings.imagePrintMode === "singleSided"
      ? t("idle.images.single")
      : t("idle.images.double")
    : settings.pdfBatchMode === "combined"
      ? t("idle.pdfs.combined")
      : t("idle.pdfs.perFile");

  const languageLabel =
    settings.language === "vi"
      ? t("language.vi")
      : settings.language === "en"
        ? t("language.en")
        : t("language.system.short");

  async function addPaths(paths: string[], images: boolean) {
    try {
      setBusy(images ? t("toolbar.addImages") : t("toolbar.addPDFs"));
      if (images) {
        const result = await invoke<AddResult<ImageQueueItem>>("add_images", { paths });
        setImageQueue(result.queue);
        reportAddErrors(result.errors);
      } else {
        const result = await invoke<AddResult<PdfQueueItem>>("add_pdfs", { paths });
        setPdfQueue(result.queue);
        reportAddErrors(result.errors);
      }
    } catch (err) {
      setError(errText(err));
    } finally {
      setBusy(null);
    }
  }

  async function addFiles() {
    const selected = await open({
      multiple: true,
      filters: isImages
        ? [
            {
              name: "Images",
              extensions: ["png", "jpg", "jpeg", "gif", "bmp", "webp", "tif", "tiff"],
            },
          ]
        : [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (!selected) return;
    await addPaths(Array.isArray(selected) ? selected : [selected], isImages);
  }

  async function setActiveQueue(next: Array<PdfQueueItem | ImageQueueItem>) {
    try {
      if (isImages) {
        setImageQueue(
          await invoke("set_image_queue", { queue: next as ImageQueueItem[] }),
        );
      } else {
        setPdfQueue(await invoke("set_pdf_queue", { queue: next as PdfQueueItem[] }));
      }
    } catch (err) {
      setError(errText(err));
    }
  }

  function removeItem(index: number) {
    void setActiveQueue(activeQueue.filter((_, i) => i !== index));
  }

  function moveItem(index: number, direction: -1 | 1) {
    const target = index + direction;
    if (target < 0 || target >= activeQueue.length) return;
    const next = [...activeQueue];
    [next[index], next[target]] = [next[target], next[index]];
    void setActiveQueue(next);
  }

  async function saveProfile(profile: PrinterProfile) {
    try {
      const saved = await invoke<PrinterProfile>("save_profile", { profile });
      setEditable(saved);
      await refresh();
    } catch (err) {
      setError(errText(err));
    }
  }

  async function startBatch() {
    try {
      setBusy(t("controls.start"));
      setShowFlipAlert(false);
      // Prints with the profile as shown, saved or not, like the Swift app.
      await invoke("start_batch", { profile: editable });
      setBatchState({ kind: "preparing", file: { key: "raw", params: { text: "…" } } });
    } catch (err) {
      setError(errText(err));
    } finally {
      setBusy(null);
    }
  }

  async function createCalibrationPdf() {
    try {
      const path = await invoke<string>("create_calibration_pdf");
      await openPath(path);
      const result = await invoke<AddResult<PdfQueueItem>>("add_pdfs", { paths: [path] });
      setPdfQueue(result.queue);
      reportAddErrors(result.errors);
      if (settings && settings.queueContent !== "pdfs") {
        await persistSettings({ ...settings, queueContent: "pdfs" });
      }
      setCalibrationNote(t("calibration.created", { path }));
    } catch (err) {
      setError(errText(err));
    }
  }

  return (
    <div className="app">
      <header className="toolbar">
        <div className="toolbar-title">{t("app.name")}</div>
        <div className="toolbar-actions">
          <button className="toolbar-btn" disabled={running} onClick={() => void addFiles()}>
            <span className="glyph">+</span>
            {isImages ? t("toolbar.addImages") : t("toolbar.addPDFs")}
          </button>
          <button
            className="toolbar-btn"
            onClick={async () => {
              try {
                setPrinters(await invoke("list_printers"));
                await refresh();
              } catch (err) {
                setError(errText(err));
              }
            }}
          >
            <span className="glyph">↻</span>
            {t("toolbar.refreshPrinters")}
          </button>
          <label className="lang-menu" title={t("toolbar.language")}>
            <span className="glyph">🌐</span>
            <select
              value={settings.language}
              aria-label={languageLabel}
              onChange={(e) =>
                void persistSettings({ ...settings, language: e.target.value })
              }
            >
              <option value="system">{t("language.system.short")}</option>
              <option value="en">{t("language.en")}</option>
              <option value="vi">{t("language.vi")}</option>
            </select>
          </label>
        </div>
      </header>

      {busy && (
        <div className="banner busy">
          <div className="spinner" aria-hidden />
          <span>{busy}</span>
        </div>
      )}
      {error && (
        <div className="banner error">
          <span style={{ whiteSpace: "pre-line" }}>{error}</span>
          <button className="btn-plain" onClick={() => setError(null)}>
            {t("common.ok")}
          </button>
        </div>
      )}

      <div className="layout">
        <section className="queue-panel">
          <div className="panel-title-row">
            <div>
              <h2>{isImages ? t("queue.title.images") : t("queue.title.pdfs")}</h2>
              <p className="panel-subtitle">
                {isImages
                  ? t("queue.summary.images", {
                      count: imageQueue.length,
                      pages: pageTotal,
                    })
                  : t("queue.summary.pdfs", {
                      count: pdfQueue.length,
                      pages: pageTotal,
                    })}
              </p>
            </div>
            <div className="header-actions">
              <button
                className="btn"
                disabled={activeQueue.length === 0}
                onClick={() => setPreviewIndex(0)}
              >
                <span className="glyph">👁</span>
                {t("queue.preview")}
              </button>
              <button
                className="btn"
                disabled={activeQueue.length === 0 || running}
                onClick={() => void setActiveQueue([])}
              >
                {t("queue.clear")}
              </button>
            </div>
          </div>

          <div className="controls-row">
            <div className="segmented" role="group" aria-label={t("queue.type")}>
              <button
                className={!isImages ? "active" : ""}
                disabled={running}
                onClick={() =>
                  void persistSettings({ ...settings, queueContent: "pdfs" })
                }
              >
                {t("queueContent.pdfs")}
              </button>
              <button
                className={isImages ? "active" : ""}
                disabled={running}
                onClick={() =>
                  void persistSettings({ ...settings, queueContent: "images" })
                }
              >
                {t("queueContent.images")}
              </button>
            </div>
            <div className="segmented compact" role="group" aria-label={t("queue.view")}>
              <button
                className={viewMode === "list" ? "active" : ""}
                title={t("viewMode.list")}
                disabled={running}
                onClick={() => setViewMode("list")}
              >
                ☰
              </button>
              <button
                className={viewMode === "thumbnails" ? "active" : ""}
                title={t("viewMode.thumbnails")}
                disabled={running}
                onClick={() => setViewMode("thumbnails")}
              >
                ▦
              </button>
            </div>
          </div>

          {hasMissingFiles && !running && (
            <div className="banner error inline">{t("queue.missingHint")}</div>
          )}

          {activeQueue.length === 0 ? (
            <button
              type="button"
              className="empty"
              disabled={running}
              onClick={() => void addFiles()}
            >
              <span className="empty-icon">{isImages ? "🖼" : "📄"}</span>
              <strong>
                {isImages
                  ? t("queue.empty.images.title")
                  : t("queue.empty.pdfs.title")}
              </strong>
              <span className="empty-text">
                {isImages
                  ? t("queue.empty.images.detail")
                  : t("queue.empty.pdfs.detail")}
              </span>
              <span className="empty-action">{t("queue.empty.clickHint")}</span>
              <span className="empty-text panel-subtitle">{t("queue.dropHint")}</span>
            </button>
          ) : viewMode === "list" ? (
            <QueueList
              items={activeQueue}
              isImages={isImages}
              locked={running || !!busy}
              onReorder={(next) => void setActiveQueue(next)}
              onRemove={removeItem}
              onPreview={(path) =>
                setPreviewIndex(
                  Math.max(
                    0,
                    activeQueue.findIndex((item) => item.path === path),
                  ),
                )
              }
            />
          ) : (
            <ThumbnailGrid
              items={activeQueue}
              isImages={isImages}
              locked={running || !!busy}
              statusText={(status) => t(statusKey(status))}
              onPreview={setPreviewIndex}
              onMove={moveItem}
              onRemove={removeItem}
            />
          )}
        </section>

        <div className="split-rule" aria-hidden />

        <aside className="settings-panel">
          <h2>{t("settings.title")}</h2>
          <p className="panel-subtitle" style={{ marginBottom: 14 }}>
            {isImages && settings.imagePrintMode === "singleSided"
              ? t("settings.description.imagesSingle")
              : t("settings.description.shared")}
          </p>

          {!isImages ? (
            <label className="field">
              <span>{t("settings.pdfBatchMode")}</span>
              <div className="segmented">
                <button
                  type="button"
                  className={settings.pdfBatchMode === "perFile" ? "active" : ""}
                  disabled={running}
                  onClick={() =>
                    void persistSettings({ ...settings, pdfBatchMode: "perFile" })
                  }
                >
                  {t("pdfBatchMode.perFile")}
                </button>
                <button
                  type="button"
                  className={settings.pdfBatchMode === "combined" ? "active" : ""}
                  disabled={running}
                  onClick={() =>
                    void persistSettings({ ...settings, pdfBatchMode: "combined" })
                  }
                >
                  {t("pdfBatchMode.combined")}
                </button>
              </div>
            </label>
          ) : (
            <label className="field">
              <span>{t("settings.printSides")}</span>
              <div className="segmented">
                <button
                  type="button"
                  className={settings.imagePrintMode === "singleSided" ? "active" : ""}
                  disabled={running}
                  onClick={() =>
                    void persistSettings({
                      ...settings,
                      imagePrintMode: "singleSided",
                    })
                  }
                >
                  {t("imagePrintMode.singleSided")}
                </button>
                <button
                  type="button"
                  className={settings.imagePrintMode === "doubleSided" ? "active" : ""}
                  disabled={running}
                  onClick={() =>
                    void persistSettings({
                      ...settings,
                      imagePrintMode: "doubleSided",
                    })
                  }
                >
                  {t("imagePrintMode.doubleSided")}
                </button>
              </div>
            </label>
          )}

          <label className="field">
            <span>{t("settings.printer")}</span>
            <select
              className="form-control"
              value={settings.selectedPrinter}
              disabled={running}
              onChange={async (e) => {
                const selectedPrinter = e.target.value;
                const next = {
                  ...settings,
                  selectedPrinter,
                  selectedProfileId: null,
                };
                await persistSettings(next);
                const match = profiles.find((p) => p.printerQueue === selectedPrinter);
                setEditable(match ?? newProfile(selectedPrinter));
              }}
            >
              {printers.length === 0 && (
                <option value="">{t("settings.noPrinters")}</option>
              )}
              {printers.map((printer) => (
                <option key={printer.queueName} value={printer.queueName}>
                  {printer.isDefault
                    ? t("settings.defaultPrinter", { name: printer.displayName })
                    : printer.displayName}
                </option>
              ))}
            </select>
          </label>

          <label className="field">
            <span>{t("settings.savedProfile")}</span>
            <select
              className="form-control"
              value={
                matchingProfiles.some((p) => p.id === editable.id)
                  ? editable.id
                  : "new"
              }
              disabled={profileLocked}
              onChange={(e) => {
                if (e.target.value === "new") {
                  setEditable(newProfile(settings.selectedPrinter));
                  return;
                }
                const found = matchingProfiles.find((p) => p.id === e.target.value);
                if (found) {
                  setEditable(found);
                  void persistSettings({
                    ...settings,
                    selectedProfileId: found.id,
                  });
                }
              }}
            >
              <option value="new">{t("settings.newProfile")}</option>
              {matchingProfiles.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>

          <div className="group-box">
            <div className="group-title">{t("profile.title")}</div>
            <label className="field">
              <span>{t("profile.name")}</span>
              <input
                value={editable.name}
                disabled={profileLocked}
                onChange={(e) => setEditable({ ...editable, name: e.target.value })}
              />
            </label>
            <label className="field">
              <span>{t("profile.paper")}</span>
              <select
                value={editable.paperSize}
                disabled={profileLocked}
                onChange={(e) =>
                  setEditable({
                    ...editable,
                    paperSize: e.target.value as PrinterProfile["paperSize"],
                  })
                }
              >
                <option value="a4">A4</option>
                <option value="letter">Letter</option>
              </select>
            </label>
            <label className="field">
              <span>{t("profile.color")}</span>
              <select
                value={editable.colorMode}
                disabled={profileLocked}
                onChange={(e) =>
                  setEditable({
                    ...editable,
                    colorMode: e.target.value as PrinterProfile["colorMode"],
                  })
                }
              >
                <option value="automatic">{t("colorMode.automatic")}</option>
                <option value="grayscale">{t("colorMode.grayscale")}</option>
                <option value="color">{t("colorMode.color")}</option>
              </select>
            </label>
            <ProfileOrderFields
              profile={editable}
              disabled={profileLocked}
              onChange={setEditable}
            />
            <div className="profile-actions">
              <button
                className="btn"
                disabled={profileLocked}
                onClick={() => void saveProfile(editable)}
              >
                {t("profile.save")}
              </button>
              <button
                className="btn"
                disabled={profileLocked}
                onClick={() => {
                  setCalibrationNote(null);
                  setShowCalibration(true);
                }}
              >
                {t("profile.calibrate")}
              </button>
            </div>
          </div>

          <div
            className={`calib-status ${editable.lastCalibrated ? "ok" : "warn"}`}
          >
            <span>{editable.lastCalibrated ? "✓" : "⚠"}</span>
            <span>
              {editable.lastCalibrated
                ? t("profile.calibratedAt", {
                    date: new Date(editable.lastCalibrated).toLocaleString(i18n.language),
                  })
                : t("profile.notCalibrated")}
            </span>
          </div>
        </aside>
      </div>

      <footer className="status-bar">
        <div className="status-icon" aria-hidden>
          🖨
        </div>
        <div className="status-text">
          <StatusText state={batchState} idleHint={idleHint} />
        </div>
        <div className="status-actions">
          {batchState.kind === "waitingForFlip" && (
            <>
              <button
                className="btn btn-primary"
                onClick={() => {
                  setShowFlipAlert(false);
                  void invoke("confirm_flip");
                }}
              >
                {t("controls.printEven")}
              </button>
              <button className="btn" onClick={() => void invoke("cancel_batch")}>
                {t("common.cancel")}
              </button>
            </>
          )}
          {batchState.kind === "pausedOnError" && (
            <>
              <button
                className="btn btn-primary"
                onClick={() => void invoke("resolve_error", { decision: "retry" })}
              >
                {t("controls.retry")}
              </button>
              <button
                className="btn"
                onClick={() => void invoke("resolve_error", { decision: "skip" })}
              >
                {t("controls.skip")}
              </button>
              <button
                className="btn"
                onClick={() => void invoke("resolve_error", { decision: "cancel" })}
              >
                {t("common.cancel")}
              </button>
            </>
          )}
          {(batchState.kind === "preparing" || batchState.kind === "printing") && (
            <>
              <div className="spinner" aria-hidden />
              <button className="btn" onClick={() => void invoke("cancel_batch")}>
                {t("common.cancel")}
              </button>
            </>
          )}
          {!running && (
            <button
              className="btn btn-primary"
              title={hasMissingFiles ? t("queue.missingHint") : undefined}
              disabled={
                activeQueue.length === 0 ||
                !settings.selectedPrinter ||
                hasMissingFiles ||
                !!busy
              }
              onClick={() => void startBatch()}
            >
              {t("controls.start")}
            </button>
          )}
        </div>
      </footer>

      {showFlipAlert && batchState.kind === "waitingForFlip" && (
        <div className="modal-backdrop">
          <div className="modal" role="alertdialog" aria-modal="true">
            <h2>{t("flip.title")}</h2>
            <p>
              <strong>{tr(batchState.file)}</strong>
            </p>
            <p>{batchState.instruction.map(tr).join(" ")}</p>
            <div className="modal-actions">
              <button className="btn" onClick={() => setShowFlipAlert(false)}>
                {t("flip.alert.later")}
              </button>
              <button
                className="btn btn-primary"
                onClick={() => {
                  setShowFlipAlert(false);
                  void invoke("confirm_flip");
                }}
              >
                {t("flip.alert.confirm")}
              </button>
            </div>
          </div>
        </div>
      )}

      {previewIndex !== null && activeQueue.length > 0 && (
        <PreviewModal
          paths={activeQueue.map((item) => item.path)}
          initialIndex={Math.min(previewIndex, activeQueue.length - 1)}
          onClose={() => setPreviewIndex(null)}
        />
      )}

      {showCalibration && (
        <div className="modal-backdrop">
          <div className="modal calibration-modal" role="dialog" aria-modal="true">
            <h2>{t("calibration.title")}</h2>
            <p>{t("calibration.intro")}</p>

            <div className="group-box">
              <div className="group-title">{t("calibration.step1")}</div>
              <div className="calibration-row">
                <span>{t("calibration.step1.detail")}</span>
                <button className="btn" onClick={() => void createCalibrationPdf()}>
                  {t("calibration.createPDF")}
                </button>
              </div>
              {calibrationNote && <p className="panel-subtitle">{calibrationNote}</p>}
            </div>

            <div className="group-box">
              <div className="group-title">{t("calibration.step2")}</div>
              <p className="panel-subtitle">{t("calibration.step2.detail")}</p>
              <ProfileOrderFields
                profile={editable}
                disabled={false}
                onChange={setEditable}
              />
            </div>

            <div className="modal-actions">
              <button className="btn" onClick={() => setShowCalibration(false)}>
                {t("common.cancel")}
              </button>
              <button
                className="btn btn-primary"
                onClick={async () => {
                  await saveProfile({
                    ...editable,
                    lastCalibrated: new Date().toISOString(),
                  });
                  setShowCalibration(false);
                }}
              >
                {t("calibration.save")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function StatusText({
  state,
  idleHint,
}: {
  state: BatchState;
  idleHint: string;
}) {
  const { t } = useTranslation();
  const { tr } = useTr();
  switch (state.kind) {
    case "idle":
      return (
        <>
          <strong>{t("state.ready")}</strong>
          <span>{idleHint}</span>
        </>
      );
    case "preparing":
      return (
        <>
          <strong>{t("state.preparing", { file: tr(state.file) })}</strong>
          <span>{t("state.preparing.detail")}</span>
        </>
      );
    case "printing": {
      const key =
        state.phase === "single"
          ? "state.printing.single"
          : state.phase === "odd"
            ? "state.printing.odd"
            : "state.printing.even";
      return (
        <>
          <strong>{t(key, { file: tr(state.file) })}</strong>
          <span>
            {state.jobId
              ? t("state.printing.job", { id: state.jobId })
              : t("state.printing.submitting")}
          </span>
        </>
      );
    }
    case "waitingForFlip":
      return (
        <>
          <strong>{t("state.flip", { file: tr(state.file) })}</strong>
          <span>{state.instruction.map(tr).join(" ")}</span>
        </>
      );
    case "pausedOnError":
      return (
        <>
          <strong>{t("state.paused", { file: tr(state.file) })}</strong>
          <span>{tr(state.message)}</span>
        </>
      );
    case "completed":
      return (
        <>
          <strong>{t("state.completed")}</strong>
          <span>{t("state.completed.detail")}</span>
        </>
      );
    case "cancelled":
      return (
        <>
          <strong>{t("state.cancelled")}</strong>
          <span>{t("state.cancelled.detail")}</span>
        </>
      );
  }
}
