use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::models::{PrinterDescriptor, PrinterProfile, SubmittedPrintJob};
use crate::print::PrintError;

/// Windows print backend using bundled SumatraPDF for silent PDF printing
/// and PowerShell for printer discovery / spooler job polling.
#[derive(Debug, Clone)]
pub struct WindowsBackend {
    poll_interval: Duration,
    sumatra_path: Option<PathBuf>,
}

impl Default for WindowsBackend {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(2),
            sumatra_path: find_sumatra(),
        }
    }
}

impl WindowsBackend {
    pub async fn list_printers(&self) -> Result<Vec<PrinterDescriptor>, PrintError> {
        let script = r#"
$ErrorActionPreference = 'Stop'
$default = (Get-CimInstance Win32_Printer | Where-Object { $_.Default }).Name
Get-CimInstance Win32_Printer | ForEach-Object {
  $isDefault = if ($_.Name -eq $default) { '1' } else { '0' }
  Write-Output ("{0}`t{1}`t{2}" -f $_.Name, $_.Name, $isDefault)
}
"#;
        let output = run_powershell(script)?;
        let printers = output
            .lines()
            .filter_map(|line| {
                let mut parts = line.splitn(3, '\t');
                let queue = parts.next()?.trim().to_string();
                if queue.is_empty() {
                    return None;
                }
                let display = parts.next().unwrap_or(&queue).trim().to_string();
                let is_default = parts.next().unwrap_or("0").trim() == "1";
                Some(PrinterDescriptor {
                    queue_name: queue,
                    display_name: display,
                    is_default,
                })
            })
            .collect();
        Ok(printers)
    }

    pub async fn submit(
        &self,
        pdf_path: &Path,
        printer: &str,
        title: &str,
        profile: &PrinterProfile,
    ) -> Result<SubmittedPrintJob, PrintError> {
        let sumatra = self
            .sumatra_path
            .as_ref()
            .ok_or(PrintError::SumatraMissing)?;

        // Snapshot job ids before submit so we can discover the new job.
        let before = list_job_ids(printer)?;

        let status = Command::new(sumatra)
            .args([
                "-print-to",
                printer,
                "-silent",
                "-print-settings",
                &super::sumatra_print_settings(profile),
                pdf_path
                    .to_str()
                    .ok_or_else(|| PrintError::Message("Invalid PDF path".into()))?,
            ])
            .status()
            .map_err(|err| PrintError::Message(format!("SumatraPDF failed: {err}")))?;
        if !status.success() {
            return Err(PrintError::Message(format!(
                "SumatraPDF exited with status {status}"
            )));
        }

        let job_id = wait_for_new_job_id(printer, &before, self.poll_interval)
            .await
            .unwrap_or_else(|| format!("sumatra-{}", uuid::Uuid::new_v4()));

        Ok(SubmittedPrintJob {
            id: job_id,
            printer: printer.to_string(),
            title: title.to_string(),
        })
    }

    pub async fn wait_until_finished(&self, job: &SubmittedPrintJob) -> Result<(), PrintError> {
        // If the id is a synthetic sumatra-* token, wait until the printer queue is idle.
        if job.id.starts_with("sumatra-") {
            loop {
                let ids = list_job_ids(&job.printer)?;
                if ids.is_empty() {
                    return Ok(());
                }
                tokio::time::sleep(self.poll_interval).await;
            }
        }

        let mut missing = 0u8;
        loop {
            let ids = list_job_ids(&job.printer)?;
            if ids.iter().any(|id| id == &job.id) {
                missing = 0;
                tokio::time::sleep(self.poll_interval).await;
                continue;
            }
            missing += 1;
            if missing >= 2 {
                return Ok(());
            }
            tokio::time::sleep(self.poll_interval).await;
        }
    }

    pub async fn cancel(&self, job: &SubmittedPrintJob) {
        if job.id.starts_with("sumatra-") {
            let _ = run_powershell(&format!(
                "Get-PrintJob -PrinterName '{}' | Remove-PrintJob -ErrorAction SilentlyContinue",
                escape_ps(&job.printer)
            ));
            return;
        }
        let _ = run_powershell(&format!(
            "Remove-PrintJob -PrinterName '{}' -ID {} -ErrorAction SilentlyContinue",
            escape_ps(&job.printer),
            escape_ps(&job.id)
        ));
    }
}

fn find_sumatra() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("SUMATRA_PDF") {
        let candidate = PathBuf::from(path);
        if candidate.exists() {
            return Some(candidate);
        }
    }
    // Installed app: Tauri places bundled resources next to the executable,
    // keeping their relative path. Dev builds run from src-tauri/.
    let mut resource_candidates = Vec::new();
    if let Some(exe_dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
        resource_candidates.push(exe_dir.join("resources/windows/SumatraPDF.exe"));
        resource_candidates.push(exe_dir.join("SumatraPDF.exe"));
    }
    resource_candidates.push(PathBuf::from("resources/windows/SumatraPDF.exe"));
    resource_candidates.push(PathBuf::from("../resources/windows/SumatraPDF.exe"));
    for candidate in resource_candidates {
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

fn list_job_ids(printer: &str) -> Result<Vec<String>, PrintError> {
    let script = format!(
        "Get-PrintJob -PrinterName '{}' -ErrorAction SilentlyContinue | ForEach-Object {{ $_.Id }}",
        escape_ps(printer)
    );
    let output = run_powershell(&script)?;
    Ok(output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

async fn wait_for_new_job_id(
    printer: &str,
    before: &[String],
    poll: Duration,
) -> Option<String> {
    for _ in 0..10 {
        if let Ok(after) = list_job_ids(printer) {
            if let Some(id) = after.into_iter().find(|id| !before.contains(id)) {
                return Some(id);
            }
        }
        tokio::time::sleep(poll).await;
    }
    None
}

fn run_powershell(script: &str) -> Result<String, PrintError> {
    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(PrintError::Message(format!(
            "PowerShell failed: {}",
            stderr.trim()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn escape_ps(value: &str) -> String {
    value.replace('\'', "''")
}
