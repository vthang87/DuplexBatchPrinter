mod batch_coordinator;
mod duplex_planner;
mod models;
mod pdf_service;
mod print;
mod stores;

use std::path::PathBuf;
use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::Mutex;
use uuid::Uuid;

use batch_coordinator::BatchCoordinator;
use models::{
    AppSettings, BatchState, ErrorDecision, ImageQueueItem, Localized, PdfQueueItem,
    PrinterDescriptor, PrinterProfile, QueueContent, QueueItemStatus,
};
use pdf_service::PdfService;
use print::PrintService;
use stores::{
    load_image_queue, load_pdf_queue, load_settings, save_image_queue, save_pdf_queue,
    save_settings, DataPaths, ProfileStore,
};

pub struct AppState {
    pub paths: DataPaths,
    pub profiles: Mutex<ProfileStore>,
    pub settings: Mutex<AppSettings>,
    pub pdf_queue: Mutex<Vec<PdfQueueItem>>,
    pub image_queue: Mutex<Vec<ImageQueueItem>>,
    pub printers: Mutex<Vec<PrinterDescriptor>>,
    pub batch: Arc<BatchCoordinator>,
    pub running: Mutex<bool>,
}

impl AppState {
    pub fn new() -> Self {
        let paths = DataPaths::resolve();
        let mut profiles = ProfileStore::load(&paths);
        let mut settings = load_settings(&paths);
        if !settings.did_migrate_default_page_order_v3
            && profiles.migrate_default_page_order_once(false)
        {
            settings.did_migrate_default_page_order_v3 = true;
            let _ = save_settings(&paths, &settings);
        }
        let pdf_queue = load_pdf_queue(&paths).unwrap_or_default();
        let image_queue = load_image_queue(&paths).unwrap_or_default();
        let batch = BatchCoordinator::new(paths.clone_paths());
        Self {
            paths,
            profiles: Mutex::new(profiles),
            settings: Mutex::new(settings),
            pdf_queue: Mutex::new(pdf_queue),
            image_queue: Mutex::new(image_queue),
            printers: Mutex::new(Vec::new()),
            batch,
            running: Mutex::new(false),
        }
    }
}

trait ClonePaths {
    fn clone_paths(&self) -> DataPaths;
}

impl ClonePaths for DataPaths {
    fn clone_paths(&self) -> DataPaths {
        DataPaths {
            root: self.root.clone(),
        }
    }
}

#[tauri::command]
async fn get_snapshot(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let settings = state.settings.lock().await.clone();
    let profiles = state.profiles.lock().await.profiles.clone();
    let pdf_queue = state.pdf_queue.lock().await.clone();
    let image_queue = state.image_queue.lock().await.clone();
    let printers = state.printers.lock().await.clone();
    let batch_state = state.batch.state().await;
    Ok(serde_json::json!({
        "settings": settings,
        "profiles": profiles,
        "pdfQueue": pdf_queue,
        "imageQueue": image_queue,
        "printers": printers,
        "batchState": batch_state,
    }))
}

#[tauri::command]
async fn list_printers(state: State<'_, AppState>) -> Result<Vec<PrinterDescriptor>, String> {
    let service = PrintService::create();
    let printers = service
        .list_printers()
        .await
        .map_err(|e| e.to_string())?;
    let mut settings = state.settings.lock().await;
    if !printers
        .iter()
        .any(|p| p.queue_name == settings.selected_printer)
    {
        settings.selected_printer = printers
            .iter()
            .find(|p| p.is_default)
            .or_else(|| printers.first())
            .map(|p| p.queue_name.clone())
            .unwrap_or_default();
        let _ = save_settings(&state.paths, &settings);
    }
    *state.printers.lock().await = printers.clone();
    Ok(printers)
}

#[tauri::command]
async fn update_settings(
    state: State<'_, AppState>,
    settings: AppSettings,
) -> Result<AppSettings, String> {
    save_settings(&state.paths, &settings)?;
    *state.settings.lock().await = settings.clone();
    Ok(settings)
}

#[tauri::command]
async fn save_profile(
    state: State<'_, AppState>,
    mut profile: PrinterProfile,
) -> Result<PrinterProfile, String> {
    let settings = state.settings.lock().await.clone();
    profile.printer_queue = settings.selected_printer.clone();
    state.profiles.lock().await.save(profile.clone())?;
    let mut settings = state.settings.lock().await;
    settings.selected_profile_id = Some(profile.id);
    save_settings(&state.paths, &settings)?;
    Ok(profile)
}

#[tauri::command]
async fn delete_profile(state: State<'_, AppState>, id: Uuid) -> Result<(), String> {
    state.profiles.lock().await.delete(id)?;
    let mut settings = state.settings.lock().await;
    if settings.selected_profile_id == Some(id) {
        settings.selected_profile_id = None;
        save_settings(&state.paths, &settings)?;
    }
    Ok(())
}

/// Result of adding files: the updated queue plus one message per file that
/// could not be added. Like the Swift app, a bad file does not stop the rest.
#[derive(serde::Serialize)]
struct AddResult<T> {
    queue: Vec<T>,
    errors: Vec<Localized>,
}

#[tauri::command]
async fn add_pdfs(
    state: State<'_, AppState>,
    paths: Vec<String>,
) -> Result<AddResult<PdfQueueItem>, Localized> {
    if *state.running.lock().await {
        return Err(Localized::new("error.batch.running"));
    }
    let existing = state.pdf_queue.lock().await.clone();
    let data_paths = state.paths.clone_paths();
    let result = tokio::task::spawn_blocking(move || {
        let mut queue = existing;
        let mut errors = Vec::new();
        for path in paths {
            let path_buf = PathBuf::from(&path);
            let is_pdf = path_buf
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("pdf"))
                == Some(true);
            if !is_pdf || queue.iter().any(|item| item.path == path) {
                continue;
            }
            match PdfService::page_count(&path_buf) {
                Ok(count) => queue.push(PdfQueueItem::new(path, count)),
                Err(err) => errors.push(err.localized()),
            }
        }
        save_pdf_queue(&data_paths, &queue).map_err(Localized::raw)?;
        Ok::<_, Localized>(AddResult { queue, errors })
    })
    .await
    .map_err(Localized::raw)??;
    *state.pdf_queue.lock().await = result.queue.clone();
    Ok(result)
}

#[tauri::command]
async fn add_images(
    state: State<'_, AppState>,
    paths: Vec<String>,
) -> Result<AddResult<ImageQueueItem>, Localized> {
    if *state.running.lock().await {
        return Err(Localized::new("error.batch.running"));
    }
    let existing = state.image_queue.lock().await.clone();
    let data_paths = state.paths.clone_paths();
    let result = tokio::task::spawn_blocking(move || {
        let mut queue = existing;
        let mut errors = Vec::new();
        for path in paths {
            if queue.iter().any(|item| item.path == path) {
                continue;
            }
            match PdfService::validate_image(PathBuf::from(&path).as_path()) {
                Ok(()) => queue.push(ImageQueueItem::new(path)),
                Err(err) => errors.push(err.localized()),
            }
        }
        save_image_queue(&data_paths, &queue).map_err(Localized::raw)?;
        Ok::<_, Localized>(AddResult { queue, errors })
    })
    .await
    .map_err(Localized::raw)??;
    *state.image_queue.lock().await = result.queue.clone();
    Ok(result)
}

#[tauri::command]
async fn set_pdf_queue(
    state: State<'_, AppState>,
    queue: Vec<PdfQueueItem>,
) -> Result<Vec<PdfQueueItem>, String> {
    save_pdf_queue(&state.paths, &queue)?;
    *state.pdf_queue.lock().await = queue.clone();
    Ok(queue)
}

#[tauri::command]
async fn set_image_queue(
    state: State<'_, AppState>,
    queue: Vec<ImageQueueItem>,
) -> Result<Vec<ImageQueueItem>, String> {
    save_image_queue(&state.paths, &queue)?;
    *state.image_queue.lock().await = queue.clone();
    Ok(queue)
}

/// Starts a batch with the profile currently shown in the editor, saved or
/// not, like the Swift app (which prints with `editableProfile`).
#[tauri::command]
async fn start_batch(
    app: AppHandle,
    state: State<'_, AppState>,
    profile: PrinterProfile,
) -> Result<(), Localized> {
    let mut running = state.running.lock().await;
    if *running {
        // A cancelled batch keeps the flag until its task has fully stopped.
        let key = if state.batch.state().await == BatchState::Cancelled {
            "error.batch.stopping"
        } else {
            "error.batch.running"
        };
        return Err(Localized::new(key));
    }

    let settings = state.settings.lock().await.clone();
    let mut profile = profile;
    profile.printer_queue = settings.selected_printer.clone();
    if profile.printer_queue.is_empty() {
        return Err(Localized::new("error.batch.noPrinter"));
    }

    let has_missing = match settings.queue_content {
        QueueContent::Pdfs => {
            let queue = state.pdf_queue.lock().await;
            if queue.is_empty() {
                return Err(Localized::new("error.batch.emptyQueue"));
            }
            queue.iter().any(|item| item.status == QueueItemStatus::Missing)
        }
        QueueContent::Images => {
            let queue = state.image_queue.lock().await;
            if queue.is_empty() {
                return Err(Localized::new("error.batch.emptyQueue"));
            }
            queue.iter().any(|item| item.status == QueueItemStatus::Missing)
        }
    };
    if has_missing {
        return Err(Localized::new("error.batch.missingFiles"));
    }
    *running = true;
    drop(running);

    let batch = state.batch.clone();
    let paths = state.paths.clone_paths();

    match settings.queue_content {
        QueueContent::Pdfs => {
            let queue = state.pdf_queue.lock().await.clone();
            let mode = settings.pdf_batch_mode;
            let app_handle = app.clone();
            tauri::async_runtime::spawn(async move {
                let updated = batch
                    .clone()
                    .run_pdfs(queue, mode, profile, {
                        let app = app_handle.clone();
                        move |queue, batch_state| {
                            let _ = app.emit(
                                "batch-update",
                                serde_json::json!({
                                    "kind": "pdf",
                                    "queue": queue,
                                    "batchState": batch_state,
                                }),
                            );
                        }
                    })
                    .await;
                let _ = save_pdf_queue(&paths, &updated);
                if let Some(state) = app_handle.try_state::<AppState>() {
                    *state.pdf_queue.lock().await = updated;
                    *state.running.lock().await = false;
                }
            });
        }
        QueueContent::Images => {
            let queue = state.image_queue.lock().await.clone();
            let mode = settings.image_print_mode;
            let app_handle = app.clone();
            tauri::async_runtime::spawn(async move {
                let updated = batch
                    .clone()
                    .run_images(queue, mode, profile, {
                        let app = app_handle.clone();
                        move |queue, batch_state| {
                            let _ = app.emit(
                                "batch-update",
                                serde_json::json!({
                                    "kind": "image",
                                    "queue": queue,
                                    "batchState": batch_state,
                                }),
                            );
                        }
                    })
                    .await;
                let _ = save_image_queue(&paths, &updated);
                if let Some(state) = app_handle.try_state::<AppState>() {
                    *state.image_queue.lock().await = updated;
                    *state.running.lock().await = false;
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
async fn confirm_flip(state: State<'_, AppState>) -> Result<(), String> {
    state.batch.confirm_paper_flipped().await;
    Ok(())
}

#[tauri::command]
async fn resolve_error(state: State<'_, AppState>, decision: ErrorDecision) -> Result<(), String> {
    state.batch.resolve_error(decision).await;
    Ok(())
}

#[tauri::command]
async fn cancel_batch(state: State<'_, AppState>) -> Result<(), String> {
    // `running` is cleared by the batch task itself once it has stopped, so a
    // new batch cannot start while the old one is still winding down.
    state.batch.cancel().await;
    Ok(())
}

#[tauri::command]
async fn create_calibration_pdf(state: State<'_, AppState>) -> Result<String, String> {
    // Downloads, like the Swift app; fall back to the temp folder.
    let directory = dirs::download_dir()
        .filter(|dir| dir.is_dir())
        .unwrap_or_else(|| state.paths.temp_dir());
    let path = tokio::task::spawn_blocking(move || PdfService::create_calibration_pdf(&directory))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())?;
    Ok(path.display().to_string())
}

#[tauri::command]
async fn get_batch_state(state: State<'_, AppState>) -> Result<BatchState, String> {
    Ok(state.batch.state().await)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_fs::init())
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            list_printers,
            update_settings,
            save_profile,
            delete_profile,
            add_pdfs,
            add_images,
            set_pdf_queue,
            set_image_queue,
            start_batch,
            confirm_flip,
            resolve_error,
            cancel_batch,
            create_calibration_pdf,
            get_batch_state,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
