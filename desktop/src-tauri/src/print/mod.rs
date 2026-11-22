use std::path::Path;

use thiserror::Error;

use crate::models::{ColorMode, Localized, PaperSize, PrinterDescriptor, PrinterProfile, SubmittedPrintJob};

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod cups;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use cups::CupsBackend;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows::WindowsBackend;

#[derive(Debug, Error)]
pub enum PrintError {
    #[error("{0}")]
    Message(String),
    #[error("Command {command} failed: {message}")]
    CommandFailed { command: String, message: String },
    #[error("CUPS did not return a job ID: {0}")]
    NoJobId(String),
    #[error("SumatraPDF not found")]
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    SumatraMissing,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl PrintError {
    pub fn localized(&self) -> Localized {
        match self {
            Self::Message(text) => Localized::raw(text),
            Self::CommandFailed { command, message } => Localized::new("error.cups.commandFailed")
                .with("command", command)
                .with("message", message.trim()),
            Self::NoJobId(response) => Localized::new("error.cups.noJobID").with("response", response.trim()),
            Self::SumatraMissing => Localized::new("error.windows.sumatraMissing"),
            Self::Io(err) => Localized::raw(err),
        }
    }
}

pub enum PrintService {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    Cups(CupsBackend),
    #[cfg(target_os = "windows")]
    Windows(WindowsBackend),
}

impl PrintService {
    pub fn create() -> Self {
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            Self::Cups(CupsBackend::default())
        }
        #[cfg(target_os = "windows")]
        {
            Self::Windows(WindowsBackend::default())
        }
    }

    pub async fn list_printers(&self) -> Result<Vec<PrinterDescriptor>, PrintError> {
        match self {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            Self::Cups(backend) => backend.list_printers().await,
            #[cfg(target_os = "windows")]
            Self::Windows(backend) => backend.list_printers().await,
        }
    }

    pub async fn submit(
        &self,
        pdf_path: &Path,
        printer: &str,
        title: &str,
        profile: &PrinterProfile,
    ) -> Result<SubmittedPrintJob, PrintError> {
        match self {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            Self::Cups(backend) => backend.submit(pdf_path, printer, title, profile).await,
            #[cfg(target_os = "windows")]
            Self::Windows(backend) => backend.submit(pdf_path, printer, title, profile).await,
        }
    }

    pub async fn wait_until_finished(&self, job: &SubmittedPrintJob) -> Result<(), PrintError> {
        match self {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            Self::Cups(backend) => backend.wait_until_finished(job).await,
            #[cfg(target_os = "windows")]
            Self::Windows(backend) => backend.wait_until_finished(job).await,
        }
    }

    pub async fn cancel(&self, job: &SubmittedPrintJob) {
        match self {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            Self::Cups(backend) => backend.cancel(job).await,
            #[cfg(target_os = "windows")]
            Self::Windows(backend) => backend.cancel(job).await,
        }
    }
}

/// SumatraPDF `-print-settings` for one pass. `simplex` matters most: a
/// printer that defaults to automatic duplex would otherwise print both
/// sides itself and break the manual flip.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn sumatra_print_settings(profile: &PrinterProfile) -> String {
    let paper = match profile.paper_size {
        PaperSize::A4 => "A4",
        PaperSize::Letter => "letter",
    };
    let mut settings = vec!["noscale".to_string(), "simplex".into(), format!("paper={paper}")];
    match profile.color_mode {
        ColorMode::Automatic => {}
        ColorMode::Grayscale => settings.push("monochrome".into()),
        ColorMode::Color => settings.push("color".into()),
    }
    settings.join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sumatra_settings_force_simplex_and_follow_profile() {
        let mut profile = PrinterProfile::new("P".into());
        assert_eq!(sumatra_print_settings(&profile), "noscale,simplex,paper=A4");
        profile.paper_size = PaperSize::Letter;
        profile.color_mode = ColorMode::Grayscale;
        assert_eq!(sumatra_print_settings(&profile), "noscale,simplex,paper=letter,monochrome");
    }
}
