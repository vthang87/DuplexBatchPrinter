use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QueueItemStatus {
    Ready,
    PrintingOdd,
    WaitingForFlip,
    PrintingEven,
    Completed,
    Skipped,
    Failed,
    Missing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PdfQueueItem {
    pub id: Uuid,
    pub path: String,
    pub page_count: usize,
    pub status: QueueItemStatus,
}

impl PdfQueueItem {
    pub fn new(path: String, page_count: usize) -> Self {
        Self {
            id: Uuid::new_v4(),
            path,
            page_count,
            status: QueueItemStatus::Ready,
        }
    }

    pub fn name(&self) -> String {
        std::path::Path::new(&self.path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&self.path)
            .to_string()
    }

    pub fn refresh_file_reference(&mut self) {
        if std::path::Path::new(&self.path).exists() {
            if self.status == QueueItemStatus::Missing {
                self.status = QueueItemStatus::Ready;
            }
        } else {
            self.status = QueueItemStatus::Missing;
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageQueueItem {
    pub id: Uuid,
    pub path: String,
    pub status: QueueItemStatus,
}

impl ImageQueueItem {
    pub fn new(path: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            path,
            status: QueueItemStatus::Ready,
        }
    }

    pub fn name(&self) -> String {
        std::path::Path::new(&self.path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&self.path)
            .to_string()
    }

    pub fn refresh_file_reference(&mut self) {
        if std::path::Path::new(&self.path).exists() {
            if self.status == QueueItemStatus::Missing {
                self.status = QueueItemStatus::Ready;
            }
        } else {
            self.status = QueueItemStatus::Missing;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PdfBatchMode {
    PerFile,
    Combined,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ImagePrintMode {
    SingleSided,
    DoubleSided,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QueueContent {
    Pdfs,
    Images,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrinterDescriptor {
    pub queue_name: String,
    pub display_name: String,
    pub is_default: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageOrder {
    Normal,
    Reversed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaperRotation {
    None,
    Rotate180,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FlipEdge {
    LongEdge,
    ShortEdge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaperSize {
    A4,
    Letter,
}

impl PaperSize {
    pub fn cups_value(self) -> &'static str {
        match self {
            Self::A4 => "A4",
            Self::Letter => "Letter",
        }
    }

    pub fn pdf_page_size_points(self) -> (f32, f32) {
        match self {
            Self::A4 => (595.0, 842.0),
            Self::Letter => (612.0, 792.0),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorMode {
    Automatic,
    Grayscale,
    Color,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrinterProfile {
    pub id: Uuid,
    pub name: String,
    pub printer_queue: String,
    pub paper_size: PaperSize,
    pub color_mode: ColorMode,
    pub odd_order: PageOrder,
    pub even_order: PageOrder,
    pub even_rotation: PaperRotation,
    pub flip_edge: FlipEdge,
    pub cups_options: std::collections::BTreeMap<String, String>,
    pub last_calibrated: Option<DateTime<Utc>>,
}

impl PrinterProfile {
    pub fn new(printer_queue: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: "Default profile".into(),
            printer_queue,
            paper_size: PaperSize::A4,
            color_mode: ColorMode::Automatic,
            odd_order: PageOrder::Reversed,
            even_order: PageOrder::Reversed,
            even_rotation: PaperRotation::None,
            flip_edge: FlipEdge::LongEdge,
            cups_options: std::collections::BTreeMap::new(),
            last_calibrated: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrintPhase {
    Single,
    Odd,
    Even,
}

impl PrintPhase {
    pub fn title(self) -> &'static str {
        match self {
            Self::Single => "All pages",
            Self::Odd => "Odd pages",
            Self::Even => "Even pages",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmittedPrintJob {
    pub id: String,
    pub printer: String,
    pub title: String,
}

/// A user-facing string the frontend translates: `key` is an i18n key and
/// `params` fill its `{{name}}` placeholders. The key `raw` means
/// `params.text` is shown as is (file names, OS error output).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Localized {
    pub key: String,
    #[serde(default)]
    pub params: std::collections::BTreeMap<String, String>,
}

impl Localized {
    pub fn new(key: &str) -> Self {
        Self {
            key: key.to_string(),
            params: Default::default(),
        }
    }

    pub fn with(mut self, name: &str, value: impl ToString) -> Self {
        self.params.insert(name.to_string(), value.to_string());
        self
    }

    pub fn raw(text: impl ToString) -> Self {
        Self::new("raw").with("text", text)
    }
}

impl std::fmt::Display for Localized {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.params.get("text") {
            Some(text) if self.key == "raw" => write!(f, "{text}"),
            _ => write!(f, "{} {:?}", self.key, self.params),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum BatchState {
    Idle,
    Preparing { file: Localized },
    Printing {
        file: Localized,
        phase: PrintPhase,
        job_id: Option<String>,
    },
    /// `instruction` parts are translated and joined with a space.
    WaitingForFlip {
        file: Localized,
        instruction: Vec<Localized>,
    },
    PausedOnError { file: Localized, message: Localized },
    Completed,
    Cancelled,
}

impl BatchState {
    pub fn is_running(&self) -> bool {
        matches!(
            self,
            Self::Preparing { .. }
                | Self::Printing { .. }
                | Self::WaitingForFlip { .. }
                | Self::PausedOnError { .. }
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorDecision {
    Retry,
    Skip,
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedPage {
    pub source_page: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplexPlan {
    pub odd_pass: Vec<PlannedPage>,
    pub even_pass: Vec<PlannedPage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub selected_printer: String,
    pub selected_profile_id: Option<Uuid>,
    pub queue_content: QueueContent,
    pub image_print_mode: ImagePrintMode,
    pub pdf_batch_mode: PdfBatchMode,
    pub language: String,
    /// One-time profile page-order migration, mirroring the Swift app's
    /// `didMigrateDefaultPageOrderToReverseBothV3` flag.
    #[serde(default)]
    pub did_migrate_default_page_order_v3: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            selected_printer: String::new(),
            selected_profile_id: None,
            queue_content: QueueContent::Pdfs,
            image_print_mode: ImagePrintMode::DoubleSided,
            pdf_batch_mode: PdfBatchMode::PerFile,
            language: "system".into(),
            did_migrate_default_page_order_v3: false,
        }
    }
}
