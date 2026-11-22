use std::fs;
use std::path::PathBuf;

use uuid::Uuid;

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::models::{
    AppSettings, ColorMode, FlipEdge, ImageQueueItem, PageOrder, PaperRotation, PaperSize,
    PdfQueueItem, PrinterProfile, QueueItemStatus,
};

pub struct DataPaths {
    pub root: PathBuf,
}

impl DataPaths {
    pub fn resolve() -> Self {
        let root = dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("PDFDuplexBatchPrinter");
        let _ = fs::create_dir_all(&root);
        Self { root }
    }

    pub fn profiles(&self) -> PathBuf {
        self.root.join("printer-profiles.json")
    }

    pub fn pdf_queue(&self) -> PathBuf {
        self.root.join("pdf-queue.json")
    }

    pub fn image_queue(&self) -> PathBuf {
        self.root.join("image-queue.json")
    }

    pub fn settings(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    pub fn temp_dir(&self) -> PathBuf {
        let dir = std::env::temp_dir().join("PDFDuplexBatchPrinter");
        let _ = fs::create_dir_all(&dir);
        dir
    }
}

pub struct ProfileStore {
    path: PathBuf,
    pub profiles: Vec<PrinterProfile>,
}

impl ProfileStore {
    /// Reads `printer-profiles.json`, which the Swift app shares on macOS.
    /// Accepts both the Swift format and this app's earlier format. A file
    /// that cannot be read is moved aside rather than overwritten later.
    pub fn load(paths: &DataPaths) -> Self {
        let path = paths.profiles();
        let profiles = match fs::read(&path) {
            Ok(data) => match serde_json::from_slice::<Vec<DiskProfile>>(&data) {
                Ok(disk) => disk.into_iter().map(PrinterProfile::from).collect(),
                Err(_) => {
                    let backup = path.with_extension(format!(
                        "json.unreadable-{}",
                        chrono::Utc::now().format("%Y%m%d%H%M%S")
                    ));
                    let _ = fs::rename(&path, backup);
                    Vec::new()
                }
            },
            Err(_) => Vec::new(),
        };
        Self { path, profiles }
    }

    pub fn profiles_for(&self, printer: &str) -> Vec<PrinterProfile> {
        self.profiles
            .iter()
            .filter(|p| p.printer_queue == printer)
            .cloned()
            .collect()
    }

    pub fn save(&mut self, profile: PrinterProfile) -> Result<(), String> {
        if let Some(existing) = self.profiles.iter_mut().find(|p| p.id == profile.id) {
            *existing = profile;
        } else {
            self.profiles.push(profile);
        }
        self.persist()
    }

    pub fn delete(&mut self, id: Uuid) -> Result<(), String> {
        self.profiles.retain(|p| p.id != id);
        self.persist()
    }

    /// Runs the default page-order migration once, like the Swift app's
    /// `didMigrateDefaultPageOrderToReverseBothV3` flag. Returns true when
    /// the flag should now be stored as done.
    pub fn migrate_default_page_order_once(&mut self, already_done: bool) -> bool {
        if already_done {
            return true;
        }
        migrate_default_page_order(&mut self.profiles);
        // Leave the flag unset on a write failure so the next launch retries.
        self.persist().is_ok()
    }

    fn persist(&self) -> Result<(), String> {
        let disk: Vec<DiskProfile> = self.profiles.iter().cloned().map(DiskProfile::from).collect();
        write_json(&self.path, &disk)
    }
}

fn migrate_default_page_order(profiles: &mut [PrinterProfile]) -> bool {
    use crate::models::PageOrder;
    // Turning the whole odd stack over reverses the sheet order, so the even
    // pass must run in the same direction as the odd pass.
    let former = [
        (PageOrder::Normal, PageOrder::Reversed),
        (PageOrder::Reversed, PageOrder::Normal),
    ];
    let mut changed = false;
    for profile in profiles.iter_mut() {
        if profile.name == "Default profile"
            && former.contains(&(profile.odd_order, profile.even_order))
        {
            profile.odd_order = PageOrder::Reversed;
            profile.even_order = PageOrder::Reversed;
            changed = true;
        }
    }
    changed
}

/// On-disk profile in the Swift app's Codable format: enum raw values such as
/// "Reverse" and "Long edge", dates as seconds since 2001-01-01. Aliases also
/// accept the camelCase values this app wrote before.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiskProfile {
    id: Uuid,
    name: String,
    printer_queue: String,
    paper_size: DiskPaperSize,
    color_mode: DiskColorMode,
    odd_order: DiskPageOrder,
    even_order: DiskPageOrder,
    even_rotation: DiskRotation,
    flip_edge: DiskFlipEdge,
    #[serde(default)]
    cups_options: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "swift_date")]
    last_calibrated: Option<DateTime<Utc>>,
}

macro_rules! disk_enum {
    ($disk:ident, $model:ident, $( $variant:ident = $swift:literal / $legacy:literal ),+ $(,)?) => {
        #[derive(Serialize, Deserialize)]
        enum $disk {
            $( #[serde(rename = $swift, alias = $legacy)] $variant, )+
        }
        impl From<$disk> for $model {
            fn from(value: $disk) -> Self {
                match value { $( $disk::$variant => $model::$variant, )+ }
            }
        }
        impl From<$model> for $disk {
            fn from(value: $model) -> Self {
                match value { $( $model::$variant => $disk::$variant, )+ }
            }
        }
    };
}

disk_enum!(DiskPaperSize, PaperSize, A4 = "A4" / "a4", Letter = "Letter" / "letter");
disk_enum!(
    DiskColorMode,
    ColorMode,
    Automatic = "Automatic" / "automatic",
    Grayscale = "Grayscale" / "grayscale",
    Color = "Color" / "color",
);
disk_enum!(DiskPageOrder, PageOrder, Normal = "Normal" / "normal", Reversed = "Reverse" / "reversed");
disk_enum!(
    DiskRotation,
    PaperRotation,
    None = "Keep orientation" / "none",
    Rotate180 = "Rotate 180°" / "rotate180",
);
disk_enum!(DiskFlipEdge, FlipEdge, LongEdge = "Long edge" / "longEdge", ShortEdge = "Short edge" / "shortEdge");

impl From<DiskProfile> for PrinterProfile {
    fn from(d: DiskProfile) -> Self {
        Self {
            id: d.id,
            name: d.name,
            printer_queue: d.printer_queue,
            paper_size: d.paper_size.into(),
            color_mode: d.color_mode.into(),
            odd_order: d.odd_order.into(),
            even_order: d.even_order.into(),
            even_rotation: d.even_rotation.into(),
            flip_edge: d.flip_edge.into(),
            cups_options: d.cups_options,
            last_calibrated: d.last_calibrated,
        }
    }
}

impl From<PrinterProfile> for DiskProfile {
    fn from(p: PrinterProfile) -> Self {
        Self {
            id: p.id,
            name: p.name,
            printer_queue: p.printer_queue,
            paper_size: p.paper_size.into(),
            color_mode: p.color_mode.into(),
            odd_order: p.odd_order.into(),
            even_order: p.even_order.into(),
            even_rotation: p.even_rotation.into(),
            flip_edge: p.flip_edge.into(),
            cups_options: p.cups_options,
            last_calibrated: p.last_calibrated,
        }
    }
}

/// Swift's default `JSONEncoder` date strategy: a number of seconds since
/// 2001-01-01T00:00:00Z. Reading also accepts RFC 3339 strings.
mod swift_date {
    use chrono::{DateTime, TimeZone, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    const REFERENCE_UNIX: i64 = 978_307_200;

    pub fn serialize<S: Serializer>(value: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(date) => {
                let seconds = (date.timestamp() - REFERENCE_UNIX) as f64
                    + f64::from(date.timestamp_subsec_nanos()) / 1e9;
                s.serialize_f64(seconds)
            }
            None => s.serialize_none(),
        }
    }

    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        Seconds(f64),
        Text(String),
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        Ok(match Option::<Raw>::deserialize(d)? {
            None => None,
            Some(Raw::Seconds(seconds)) => {
                let whole = seconds.floor();
                let nanos = ((seconds - whole) * 1e9) as u32;
                Utc.timestamp_opt(REFERENCE_UNIX + whole as i64, nanos).single()
            }
            Some(Raw::Text(text)) => DateTime::parse_from_rfc3339(&text)
                .ok()
                .map(|d| d.with_timezone(&Utc)),
        })
    }
}

pub fn load_pdf_queue(paths: &DataPaths) -> Result<Vec<PdfQueueItem>, String> {
    let mut items: Vec<PdfQueueItem> = read_json(&paths.pdf_queue()).unwrap_or_default();
    for item in &mut items {
        item.refresh_file_reference();
    }
    Ok(items)
}

pub fn save_pdf_queue(paths: &DataPaths, items: &[PdfQueueItem]) -> Result<(), String> {
    let persistent: Vec<_> = items
        .iter()
        .map(|item| {
            let mut copy = item.clone();
            copy.status = QueueItemStatus::Ready;
            copy
        })
        .collect();
    write_json(&paths.pdf_queue(), &persistent)
}

pub fn load_image_queue(paths: &DataPaths) -> Result<Vec<ImageQueueItem>, String> {
    let mut items: Vec<ImageQueueItem> = read_json(&paths.image_queue()).unwrap_or_default();
    for item in &mut items {
        item.refresh_file_reference();
    }
    Ok(items)
}

pub fn save_image_queue(paths: &DataPaths, items: &[ImageQueueItem]) -> Result<(), String> {
    let persistent: Vec<_> = items
        .iter()
        .map(|item| {
            let mut copy = item.clone();
            copy.status = QueueItemStatus::Ready;
            copy
        })
        .collect();
    write_json(&paths.image_queue(), &persistent)
}

pub fn load_settings(paths: &DataPaths) -> AppSettings {
    read_json(&paths.settings()).unwrap_or_default()
}

pub fn save_settings(paths: &DataPaths, settings: &AppSettings) -> Result<(), String> {
    write_json(&paths.settings(), settings)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &PathBuf) -> Result<T, String> {
    let data = fs::read(path).map_err(|e| e.to_string())?;
    serde_json::from_slice(&data).map_err(|e| e.to_string())
}

fn write_json<T: serde::Serialize>(path: &PathBuf, value: &T) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    fs::write(path, data).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_paths() -> DataPaths {
        let root = std::env::temp_dir().join(format!("stores-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        DataPaths { root }
    }

    const SWIFT_JSON: &str = r#"[
      {
        "colorMode" : "Grayscale",
        "cupsOptions" : { "InputSlot" : "Rear" },
        "evenOrder" : "Reverse",
        "evenRotation" : "Rotate 180°",
        "flipEdge" : "Short edge",
        "id" : "0E6A4B8A-7C1B-4E54-9F62-2A9F4C3B5D11",
        "lastCalibrated" : 754012800.5,
        "name" : "Office",
        "oddOrder" : "Normal",
        "paperSize" : "Letter",
        "printerQueue" : "EPSON_L3250"
      }
    ]"#;

    #[test]
    fn reads_swift_profiles_and_writes_them_back_in_swift_format() {
        let paths = temp_paths();
        fs::write(paths.profiles(), SWIFT_JSON).unwrap();
        let mut store = ProfileStore::load(&paths);
        assert_eq!(store.profiles.len(), 1);
        let p = &store.profiles[0];
        assert_eq!(p.paper_size, PaperSize::Letter);
        assert_eq!(p.color_mode, ColorMode::Grayscale);
        assert_eq!(p.odd_order, PageOrder::Normal);
        assert_eq!(p.even_order, PageOrder::Reversed);
        assert_eq!(p.even_rotation, PaperRotation::Rotate180);
        assert_eq!(p.flip_edge, FlipEdge::ShortEdge);
        assert_eq!(p.cups_options.get("InputSlot").map(String::as_str), Some("Rear"));
        // 754012800.5 s after 2001-01-01 = 2024-11-23T00:00:00.5Z
        assert_eq!(p.last_calibrated.unwrap().to_rfc3339(), "2024-11-23T00:00:00.500+00:00");

        let profile = store.profiles[0].clone();
        store.save(profile).unwrap();
        let written: serde_json::Value =
            serde_json::from_slice(&fs::read(paths.profiles()).unwrap()).unwrap();
        let entry = &written[0];
        assert_eq!(entry["evenOrder"], "Reverse");
        assert_eq!(entry["oddOrder"], "Normal");
        assert_eq!(entry["evenRotation"], "Rotate 180°");
        assert_eq!(entry["flipEdge"], "Short edge");
        assert_eq!(entry["paperSize"], "Letter");
        assert_eq!(entry["colorMode"], "Grayscale");
        assert_eq!(entry["lastCalibrated"].as_f64(), Some(754012800.5));
        fs::remove_dir_all(paths.root).ok();
    }

    #[test]
    fn reads_profiles_written_by_earlier_tauri_builds() {
        let paths = temp_paths();
        let legacy = r#"[{"id":"0e6a4b8a-7c1b-4e54-9f62-2a9f4c3b5d11","name":"Old","printerQueue":"P",
            "paperSize":"a4","colorMode":"automatic","oddOrder":"reversed","evenOrder":"reversed",
            "evenRotation":"none","flipEdge":"longEdge","cupsOptions":{},
            "lastCalibrated":"2025-01-02T03:04:05Z"}]"#;
        fs::write(paths.profiles(), legacy).unwrap();
        let store = ProfileStore::load(&paths);
        assert_eq!(store.profiles.len(), 1);
        assert_eq!(store.profiles[0].paper_size, PaperSize::A4);
        assert!(store.profiles[0].last_calibrated.is_some());
        fs::remove_dir_all(paths.root).ok();
    }

    #[test]
    fn unreadable_profile_file_is_moved_aside_not_overwritten() {
        let paths = temp_paths();
        fs::write(paths.profiles(), "{ not json").unwrap();
        let mut store = ProfileStore::load(&paths);
        assert!(store.profiles.is_empty());
        store.save(PrinterProfile::new("P".into())).unwrap();
        let backups = fs::read_dir(&paths.root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("unreadable"))
            .count();
        assert_eq!(backups, 1);
        fs::remove_dir_all(paths.root).ok();
    }

    #[test]
    fn page_order_migration_runs_only_once() {
        let paths = temp_paths();
        let mut profile = PrinterProfile::new("P".into());
        profile.odd_order = PageOrder::Normal;
        let mut store = ProfileStore::load(&paths);
        store.save(profile.clone()).unwrap();

        assert!(store.migrate_default_page_order_once(false));
        assert_eq!(store.profiles[0].odd_order, PageOrder::Reversed);

        // The user deliberately sets Normal again; later launches keep it.
        store.save(profile).unwrap();
        assert!(store.migrate_default_page_order_once(true));
        assert_eq!(store.profiles[0].odd_order, PageOrder::Normal);
        fs::remove_dir_all(paths.root).ok();
    }
}
