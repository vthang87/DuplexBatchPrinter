use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::{oneshot, Mutex};

use crate::duplex_planner::DuplexPlanner;
use crate::models::{
    BatchState, ErrorDecision, FlipEdge, Localized, ImagePrintMode, ImageQueueItem, PaperRotation,
    PdfBatchMode, PdfQueueItem, PlannedPage, PrintPhase, PrinterProfile, QueueItemStatus,
    SubmittedPrintJob,
};
use crate::pdf_service::PdfService;
use crate::print::PrintService;
use crate::stores::DataPaths;

pub struct BatchCoordinator {
    print_service: PrintService,
    paths: DataPaths,
    state: Mutex<BatchState>,
    flip_tx: Mutex<Option<oneshot::Sender<()>>>,
    error_tx: Mutex<Option<oneshot::Sender<ErrorDecision>>>,
    active_job: Mutex<Option<SubmittedPrintJob>>,
    cancel_flag: Mutex<bool>,
}

impl BatchCoordinator {
    pub fn new(paths: DataPaths) -> Arc<Self> {
        Arc::new(Self {
            print_service: PrintService::create(),
            paths,
            state: Mutex::new(BatchState::Idle),
            flip_tx: Mutex::new(None),
            error_tx: Mutex::new(None),
            active_job: Mutex::new(None),
            cancel_flag: Mutex::new(false),
        })
    }

    pub async fn state(&self) -> BatchState {
        self.state.lock().await.clone()
    }

    pub async fn set_state(&self, state: BatchState) {
        *self.state.lock().await = state;
    }

    pub async fn confirm_paper_flipped(&self) {
        if let Some(tx) = self.flip_tx.lock().await.take() {
            let _ = tx.send(());
        }
    }

    pub async fn resolve_error(&self, decision: ErrorDecision) {
        if let Some(tx) = self.error_tx.lock().await.take() {
            let _ = tx.send(decision);
        }
    }

    pub async fn cancel(&self) {
        *self.cancel_flag.lock().await = true;
        if let Some(job) = self.active_job.lock().await.take() {
            self.print_service.cancel(&job).await;
        }
        if let Some(tx) = self.flip_tx.lock().await.take() {
            let _ = tx.send(());
        }
        if let Some(tx) = self.error_tx.lock().await.take() {
            let _ = tx.send(ErrorDecision::Cancel);
        }
        self.set_state(BatchState::Cancelled).await;
    }

    pub async fn run_pdfs(
        self: Arc<Self>,
        mut queue: Vec<PdfQueueItem>,
        mode: PdfBatchMode,
        profile: PrinterProfile,
        on_update: impl Fn(Vec<PdfQueueItem>, BatchState) + Send + Sync + 'static,
    ) -> Vec<PdfQueueItem> {
        *self.cancel_flag.lock().await = false;
        for item in &mut queue {
            if item.status != QueueItemStatus::Missing {
                item.status = QueueItemStatus::Ready;
            }
        }
        on_update(queue.clone(), BatchState::Idle);

        match mode {
            PdfBatchMode::PerFile => {
                for index in 0..queue.len() {
                    if *self.cancel_flag.lock().await {
                        self.set_state(BatchState::Cancelled).await;
                        on_update(queue.clone(), BatchState::Cancelled);
                        return queue;
                    }
                    loop {
                        match self
                            .print_file(&mut queue, index, &profile, &on_update)
                            .await
                        {
                            Ok(()) => {
                                on_update(queue.clone(), self.state().await);
                                break;
                            }
                            Err(BatchRunError::Cancelled) => {
                                self.set_state(BatchState::Cancelled).await;
                                on_update(queue.clone(), BatchState::Cancelled);
                                return queue;
                            }
                            Err(BatchRunError::Failed(message)) => {
                                queue[index].status = QueueItemStatus::Failed;
                                let file = Localized::raw(queue[index].name());
                                self.set_state(BatchState::PausedOnError {
                                    file: file.clone(),
                                    message: message.clone(),
                                })
                                .await;
                                on_update(
                                    queue.clone(),
                                    BatchState::PausedOnError {
                                        file: file.clone(),
                                        message,
                                    },
                                );
                                let decision = self.wait_for_error_decision().await;
                                match decision {
                                    ErrorDecision::Retry => {
                                        queue[index].status = QueueItemStatus::Ready;
                                        on_update(queue.clone(), self.state().await);
                                        continue;
                                    }
                                    ErrorDecision::Skip => {
                                        queue[index].status = QueueItemStatus::Skipped;
                                        on_update(queue.clone(), self.state().await);
                                        break;
                                    }
                                    ErrorDecision::Cancel => {
                                        self.set_state(BatchState::Cancelled).await;
                                        on_update(queue.clone(), BatchState::Cancelled);
                                        return queue;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            PdfBatchMode::Combined => loop {
                match self.print_combined(&mut queue, &profile, &on_update).await {
                    Ok(()) => {
                        self.set_state(BatchState::Completed).await;
                        on_update(queue.clone(), BatchState::Completed);
                        break;
                    }
                    Err(BatchRunError::Cancelled) => {
                        self.set_state(BatchState::Cancelled).await;
                        on_update(queue.clone(), BatchState::Cancelled);
                        return queue;
                    }
                    Err(BatchRunError::Failed(message)) => {
                        set_pdf_status(&mut queue, QueueItemStatus::Failed);
                        let file = combined_name(&queue);
                        self.set_state(BatchState::PausedOnError {
                            file: file.clone(),
                            message: message.clone(),
                        })
                        .await;
                        on_update(
                            queue.clone(),
                            BatchState::PausedOnError {
                                file: file.clone(),
                                message,
                            },
                        );
                        match self.wait_for_error_decision().await {
                            ErrorDecision::Retry => {
                                set_pdf_status(&mut queue, QueueItemStatus::Ready);
                                continue;
                            }
                            ErrorDecision::Skip => {
                                set_pdf_status(&mut queue, QueueItemStatus::Skipped);
                                self.set_state(BatchState::Completed).await;
                                on_update(queue.clone(), BatchState::Completed);
                                break;
                            }
                            ErrorDecision::Cancel => {
                                self.set_state(BatchState::Cancelled).await;
                                on_update(queue.clone(), BatchState::Cancelled);
                                return queue;
                            }
                        }
                    }
                }
            },
        }

        if !*self.cancel_flag.lock().await {
            self.set_state(BatchState::Completed).await;
            on_update(queue.clone(), BatchState::Completed);
        }
        queue
    }

    pub async fn run_images(
        self: Arc<Self>,
        mut queue: Vec<ImageQueueItem>,
        mode: ImagePrintMode,
        profile: PrinterProfile,
        on_update: impl Fn(Vec<ImageQueueItem>, BatchState) + Send + Sync + 'static,
    ) -> Vec<ImageQueueItem> {
        *self.cancel_flag.lock().await = false;
        for item in &mut queue {
            if item.status != QueueItemStatus::Missing {
                item.status = QueueItemStatus::Ready;
            }
        }

        match mode {
            ImagePrintMode::SingleSided => {
                for index in 0..queue.len() {
                    if *self.cancel_flag.lock().await {
                        self.set_state(BatchState::Cancelled).await;
                        on_update(queue.clone(), BatchState::Cancelled);
                        return queue;
                    }
                    loop {
                        match self
                            .print_single_image(&mut queue, index, &profile, &on_update)
                            .await
                        {
                            Ok(()) => {
                                on_update(queue.clone(), self.state().await);
                                break;
                            }
                            Err(BatchRunError::Cancelled) => {
                                self.set_state(BatchState::Cancelled).await;
                                on_update(queue.clone(), BatchState::Cancelled);
                                return queue;
                            }
                            Err(BatchRunError::Failed(message)) => {
                                queue[index].status = QueueItemStatus::Failed;
                                let file = Localized::raw(queue[index].name());
                                self.set_state(BatchState::PausedOnError {
                                    file: file.clone(),
                                    message: message.clone(),
                                })
                                .await;
                                on_update(
                                    queue.clone(),
                                    BatchState::PausedOnError { file, message },
                                );
                                match self.wait_for_error_decision().await {
                                    ErrorDecision::Retry => {
                                        queue[index].status = QueueItemStatus::Ready;
                                        continue;
                                    }
                                    ErrorDecision::Skip => {
                                        queue[index].status = QueueItemStatus::Skipped;
                                        break;
                                    }
                                    ErrorDecision::Cancel => {
                                        self.set_state(BatchState::Cancelled).await;
                                        on_update(queue.clone(), BatchState::Cancelled);
                                        return queue;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ImagePrintMode::DoubleSided => loop {
                match self.print_images(&mut queue, &profile, &on_update).await {
                    Ok(()) => break,
                    Err(BatchRunError::Cancelled) => {
                        self.set_state(BatchState::Cancelled).await;
                        on_update(queue.clone(), BatchState::Cancelled);
                        return queue;
                    }
                    Err(BatchRunError::Failed(message)) => {
                        set_image_status(&mut queue, QueueItemStatus::Failed);
                        self.set_state(BatchState::PausedOnError {
                            file: image_list_name(queue.len()),
                            message: message.clone(),
                        })
                        .await;
                        on_update(
                            queue.clone(),
                            BatchState::PausedOnError {
                                file: image_list_name(queue.len()),
                                message,
                            },
                        );
                        match self.wait_for_error_decision().await {
                            ErrorDecision::Retry => {
                                set_image_status(&mut queue, QueueItemStatus::Ready);
                                continue;
                            }
                            ErrorDecision::Skip => {
                                set_image_status(&mut queue, QueueItemStatus::Skipped);
                                break;
                            }
                            ErrorDecision::Cancel => {
                                self.set_state(BatchState::Cancelled).await;
                                on_update(queue.clone(), BatchState::Cancelled);
                                return queue;
                            }
                        }
                    }
                }
            },
        }

        if !*self.cancel_flag.lock().await {
            self.set_state(BatchState::Completed).await;
            on_update(queue.clone(), BatchState::Completed);
        }
        queue
    }

    async fn print_file(
        &self,
        queue: &mut [PdfQueueItem],
        index: usize,
        profile: &PrinterProfile,
        on_update: &impl Fn(Vec<PdfQueueItem>, BatchState),
    ) -> Result<(), BatchRunError> {
        let item = queue[index].clone();
        let file_name = Localized::raw(item.name());
        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        let plan = DuplexPlanner::plan(item.page_count, profile);
        let temp = self.paths.temp_dir();
        let mut temps = TempFiles::default();
        let source = PathBuf::from(&item.path);

        let odd_url = make_pass_async(
            source.clone(),
            plan.odd_pass.clone(),
            PaperRotation::None,
            temp.clone(),
            "odd",
        )
        .await?;
        temps.push(odd_url.clone());
        queue[index].status = QueueItemStatus::PrintingOdd;
        self.print_pass(&odd_url, &file_name, PrintPhase::Odd, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;

        if !plan.even_pass.iter().any(|p| p.source_page.is_some()) {
            queue[index].status = QueueItemStatus::Completed;
            return Ok(());
        }

        queue[index].status = QueueItemStatus::WaitingForFlip;
        let blank_note = plan
            .even_pass
            .iter()
            .any(|p| p.source_page.is_none())
            .then(|| Localized::new("flip.note.lastPageBlank").with("pages", item.page_count));
        let instruction = flip_instruction(profile, blank_note);
        self.set_state(BatchState::WaitingForFlip {
            file: file_name.clone(),
            instruction,
        })
        .await;
        // Must emit before blocking on flip confirmation — otherwise UI never shows the dialog.
        on_update(queue.to_vec(), self.state().await);
        self.wait_for_flip().await?;

        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);

        let even_url = make_pass_async(
            source,
            plan.even_pass.clone(),
            profile.even_rotation,
            temp,
            "even",
        )
        .await?;
        temps.push(even_url.clone());
        queue[index].status = QueueItemStatus::PrintingEven;
        self.print_pass(&even_url, &file_name, PrintPhase::Even, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;
        queue[index].status = QueueItemStatus::Completed;
        Ok(())
    }

    async fn print_combined(
        &self,
        queue: &mut [PdfQueueItem],
        profile: &PrinterProfile,
        on_update: &impl Fn(Vec<PdfQueueItem>, BatchState),
    ) -> Result<(), BatchRunError> {
        let file_name = combined_name(queue);
        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        let temp = self.paths.temp_dir();
        let mut temps = TempFiles::default();
        let sources: Vec<PathBuf> = queue
            .iter()
            .filter(|item| item.status != QueueItemStatus::Missing)
            .map(|item| PathBuf::from(&item.path))
            .collect();
        let temp_for_merge = temp.clone();
        let (merged, page_counts) = tokio::task::spawn_blocking(move || {
            PdfService::make_merged_document(&sources, &temp_for_merge)
        })
        .await
        .map_err(|e| BatchRunError::Failed(Localized::raw(e)))?
        .map_err(|e| BatchRunError::Failed(e.localized()))?;
        temps.push(merged.clone());

        let plan = DuplexPlanner::plan_counts(&page_counts, profile);
        let odd_url = make_pass_async(
            merged.clone(),
            plan.odd_pass.clone(),
            PaperRotation::None,
            temp.clone(),
            "combined-odd",
        )
        .await?;
        temps.push(odd_url.clone());
        set_pdf_status(queue, QueueItemStatus::PrintingOdd);
        self.print_pass(&odd_url, &file_name, PrintPhase::Odd, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;

        if !plan.even_pass.iter().any(|p| p.source_page.is_some()) {
            set_pdf_status(queue, QueueItemStatus::Completed);
            return Ok(());
        }

        set_pdf_status(queue, QueueItemStatus::WaitingForFlip);
        let blank_note = page_counts
            .iter()
            .any(|c| c % 2 != 0)
            .then(|| Localized::new("flip.note.combinedBlank"));
        let instruction = flip_instruction(profile, blank_note);
        self.set_state(BatchState::WaitingForFlip {
            file: file_name.clone(),
            instruction,
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        self.wait_for_flip().await?;

        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);

        let even_url = make_pass_async(
            merged,
            plan.even_pass.clone(),
            profile.even_rotation,
            temp,
            "combined-even",
        )
        .await?;
        temps.push(even_url.clone());
        set_pdf_status(queue, QueueItemStatus::PrintingEven);
        self.print_pass(&even_url, &file_name, PrintPhase::Even, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;
        set_pdf_status(queue, QueueItemStatus::Completed);
        Ok(())
    }

    async fn print_images(
        &self,
        queue: &mut [ImageQueueItem],
        profile: &PrinterProfile,
        on_update: &impl Fn(Vec<ImageQueueItem>, BatchState),
    ) -> Result<(), BatchRunError> {
        let file_name = image_list_name(queue.len());
        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        let temp = self.paths.temp_dir();
        let mut temps = TempFiles::default();
        let sources: Vec<PathBuf> = queue.iter().map(|item| PathBuf::from(&item.path)).collect();
        let paper_size = profile.paper_size;
        let temp_for_images = temp.clone();
        let source_url = tokio::task::spawn_blocking(move || {
            PdfService::make_image_document(&sources, paper_size, &temp_for_images, "images")
        })
        .await
        .map_err(|e| BatchRunError::Failed(Localized::raw(e)))?
        .map_err(|e| BatchRunError::Failed(e.localized()))?;
        temps.push(source_url.clone());

        let plan = DuplexPlanner::plan(queue.len(), profile);
        let odd_url = make_pass_async(
            source_url.clone(),
            plan.odd_pass.clone(),
            PaperRotation::None,
            temp.clone(),
            "image-odd",
        )
        .await?;
        temps.push(odd_url.clone());
        set_image_status(queue, QueueItemStatus::PrintingOdd);
        self.print_pass(&odd_url, &file_name, PrintPhase::Odd, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;

        if !plan.even_pass.iter().any(|p| p.source_page.is_some()) {
            set_image_status(queue, QueueItemStatus::Completed);
            return Ok(());
        }

        set_image_status(queue, QueueItemStatus::WaitingForFlip);
        let blank_note = plan
            .even_pass
            .iter()
            .any(|p| p.source_page.is_none())
            .then(|| Localized::new("flip.note.lastPageBlank").with("pages", queue.len()));
        let instruction = flip_instruction(profile, blank_note);
        self.set_state(BatchState::WaitingForFlip {
            file: file_name.clone(),
            instruction,
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        self.wait_for_flip().await?;

        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);

        let even_url = make_pass_async(
            source_url,
            plan.even_pass.clone(),
            profile.even_rotation,
            temp,
            "image-even",
        )
        .await?;
        temps.push(even_url.clone());
        set_image_status(queue, QueueItemStatus::PrintingEven);
        self.print_pass(&even_url, &file_name, PrintPhase::Even, profile, |state| {
            on_update(queue.to_vec(), state);
        })
        .await?;
        set_image_status(queue, QueueItemStatus::Completed);
        Ok(())
    }

    async fn print_single_image(
        &self,
        queue: &mut [ImageQueueItem],
        index: usize,
        profile: &PrinterProfile,
        on_update: &impl Fn(Vec<ImageQueueItem>, BatchState),
    ) -> Result<(), BatchRunError> {
        let item = queue[index].clone();
        let file_name = Localized::raw(item.name());
        self.set_state(BatchState::Preparing {
            file: file_name.clone(),
        })
        .await;
        on_update(queue.to_vec(), self.state().await);
        let temp = self.paths.temp_dir();
        let paper_size = profile.paper_size;
        let source = PathBuf::from(&item.path);
        let label = format!("image-page-{}", index + 1);
        let page_url = tokio::task::spawn_blocking(move || {
            PdfService::make_image_document(&[source], paper_size, &temp, &label)
        })
        .await
        .map_err(|e| BatchRunError::Failed(Localized::raw(e)))?
        .map_err(|e| BatchRunError::Failed(e.localized()))?;
        let mut page_guard = TempFiles::default();
        page_guard.push(page_url.clone());
        queue[index].status = QueueItemStatus::PrintingOdd;
        let result = self
            .print_pass(
                &page_url,
                &file_name,
                PrintPhase::Single,
                profile,
                |state| on_update(queue.to_vec(), state),
            )
            .await;
        drop(page_guard);
        result?;
        queue[index].status = QueueItemStatus::Completed;
        Ok(())
    }

    async fn print_pass(
        &self,
        url: &PathBuf,
        file_name: &Localized,
        phase: PrintPhase,
        profile: &PrinterProfile,
        on_state: impl Fn(BatchState),
    ) -> Result<(), BatchRunError> {
        if *self.cancel_flag.lock().await {
            return Err(BatchRunError::Cancelled);
        }
        let printing = BatchState::Printing {
            file: file_name.clone(),
            phase,
            job_id: None,
        };
        self.set_state(printing.clone()).await;
        on_state(printing);
        let title = format!("{} — {}", job_title_name(file_name), phase.title());
        let job = self
            .print_service
            .submit(url, &profile.printer_queue, &title, profile)
            .await
            .map_err(|e| BatchRunError::Failed(e.localized()))?;
        *self.active_job.lock().await = Some(job.clone());
        let printing = BatchState::Printing {
            file: file_name.clone(),
            phase,
            job_id: Some(job.id.clone()),
        };
        self.set_state(printing.clone()).await;
        on_state(printing);
        self.print_service
            .wait_until_finished(&job)
            .await
            .map_err(|e| BatchRunError::Failed(e.localized()))?;
        *self.active_job.lock().await = None;
        if *self.cancel_flag.lock().await {
            return Err(BatchRunError::Cancelled);
        }
        Ok(())
    }

    async fn wait_for_flip(&self) -> Result<(), BatchRunError> {
        if *self.cancel_flag.lock().await {
            return Err(BatchRunError::Cancelled);
        }
        let (tx, rx) = oneshot::channel();
        *self.flip_tx.lock().await = Some(tx);
        rx.await.map_err(|_| BatchRunError::Cancelled)?;
        if *self.cancel_flag.lock().await {
            return Err(BatchRunError::Cancelled);
        }
        Ok(())
    }

    async fn wait_for_error_decision(&self) -> ErrorDecision {
        let (tx, rx) = oneshot::channel();
        *self.error_tx.lock().await = Some(tx);
        rx.await.unwrap_or(ErrorDecision::Cancel)
    }
}

#[derive(Debug)]
enum BatchRunError {
    Cancelled,
    Failed(Localized),
}

/// Flip instruction parts; the frontend translates and joins them.
fn flip_instruction(profile: &PrinterProfile, blank_note: Option<Localized>) -> Vec<Localized> {
    let edge = match profile.flip_edge {
        FlipEdge::LongEdge => "long",
        FlipEdge::ShortEdge => "short",
    };
    let key = if profile.even_rotation == PaperRotation::Rotate180 {
        format!("flip.instruction.rotate.{edge}")
    } else {
        format!("flip.instruction.{edge}")
    };
    let mut parts = vec![Localized::new(&key)];
    parts.extend(blank_note);
    parts
}

fn combined_name(queue: &[PdfQueueItem]) -> Localized {
    let count = queue
        .iter()
        .filter(|item| item.status != QueueItemStatus::Missing)
        .count();
    Localized::new("batch.combinedName").with("count", count)
}

fn image_list_name(count: usize) -> Localized {
    Localized::new("batch.imageListName").with("count", count)
}

/// CUPS job titles stay in English, like the Swift app.
fn job_title_name(name: &Localized) -> String {
    let count = name.params.get("count").cloned().unwrap_or_default();
    match name.key.as_str() {
        "batch.combinedName" => format!("Combined batch ({count} files)"),
        "batch.imageListName" => format!("Image list ({count})"),
        _ => name.params.get("text").cloned().unwrap_or_else(|| name.key.clone()),
    }
}

/// Deletes its temporary files when dropped, so failed or cancelled passes
/// clean up like the Swift app's `defer`.
#[derive(Default)]
struct TempFiles(Vec<PathBuf>);

impl TempFiles {
    fn push(&mut self, path: PathBuf) {
        self.0.push(path);
    }
}

impl Drop for TempFiles {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn set_pdf_status(queue: &mut [PdfQueueItem], status: QueueItemStatus) {
    for item in queue.iter_mut() {
        if item.status != QueueItemStatus::Missing {
            item.status = status;
        }
    }
}

fn set_image_status(queue: &mut [ImageQueueItem], status: QueueItemStatus) {
    for item in queue.iter_mut() {
        if item.status != QueueItemStatus::Missing {
            item.status = status;
        }
    }
}

async fn make_pass_async(
    source: PathBuf,
    pages: Vec<PlannedPage>,
    rotation: PaperRotation,
    temporary_directory: PathBuf,
    label: &str,
) -> Result<PathBuf, BatchRunError> {
    let label = label.to_string();
    tokio::task::spawn_blocking(move || {
        PdfService::make_pass(&source, &pages, rotation, &temporary_directory, &label)
    })
    .await
    .map_err(|e| BatchRunError::Failed(Localized::raw(e)))?
    .map_err(|e| BatchRunError::Failed(e.localized()))
}
