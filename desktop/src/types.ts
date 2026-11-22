export type QueueItemStatus =
  | "ready"
  | "printingOdd"
  | "waitingForFlip"
  | "printingEven"
  | "completed"
  | "skipped"
  | "failed"
  | "missing";

export interface PdfQueueItem {
  id: string;
  path: string;
  pageCount: number;
  status: QueueItemStatus;
}

export interface ImageQueueItem {
  id: string;
  path: string;
  status: QueueItemStatus;
}

export interface PrinterDescriptor {
  queueName: string;
  displayName: string;
  isDefault: boolean;
}

export interface PrinterProfile {
  id: string;
  name: string;
  printerQueue: string;
  paperSize: "a4" | "letter";
  colorMode: "automatic" | "grayscale" | "color";
  oddOrder: "normal" | "reversed";
  evenOrder: "normal" | "reversed";
  evenRotation: "none" | "rotate180";
  flipEdge: "longEdge" | "shortEdge";
  cupsOptions: Record<string, string>;
  lastCalibrated: string | null;
}

export interface AppSettings {
  selectedPrinter: string;
  selectedProfileId: string | null;
  queueContent: "pdfs" | "images";
  imagePrintMode: "singleSided" | "doubleSided";
  pdfBatchMode: "perFile" | "combined";
  language: string;
  didMigrateDefaultPageOrderV3?: boolean;
}

/** A backend message to translate: `key` is an i18n key, `params` fill it. */
export interface Localized {
  key: string;
  params: Record<string, string>;
}

export type BatchState =
  | { kind: "idle" }
  | { kind: "preparing"; file: Localized }
  | {
      kind: "printing";
      file: Localized;
      phase: "single" | "odd" | "even";
      jobId?: string | null;
    }
  | { kind: "waitingForFlip"; file: Localized; instruction: Localized[] }
  | { kind: "pausedOnError"; file: Localized; message: Localized }
  | { kind: "completed" }
  | { kind: "cancelled" };

export interface AddResult<T> {
  queue: T[];
  errors: Localized[];
}

export interface Snapshot {
  settings: AppSettings;
  profiles: PrinterProfile[];
  pdfQueue: PdfQueueItem[];
  imageQueue: ImageQueueItem[];
  printers: PrinterDescriptor[];
  batchState: BatchState;
}

export function newProfile(printerQueue: string): PrinterProfile {
  return {
    id: crypto.randomUUID(),
    name: "Default profile",
    printerQueue,
    paperSize: "a4",
    colorMode: "automatic",
    oddOrder: "reversed",
    evenOrder: "reversed",
    evenRotation: "none",
    flipEdge: "longEdge",
    cupsOptions: {},
    lastCalibrated: null,
  };
}
