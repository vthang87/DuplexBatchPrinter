use std::path::Path;
use std::process::Command;
use std::time::Duration;

use regex::Regex;

use crate::models::{ColorMode, PrinterDescriptor, PrinterProfile, SubmittedPrintJob};
use crate::print::PrintError;

#[derive(Debug, Clone)]
pub struct CupsBackend {
    poll_interval: Duration,
}

impl Default for CupsBackend {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(1),
        }
    }
}

impl CupsBackend {
    pub async fn list_printers(&self) -> Result<Vec<PrinterDescriptor>, PrintError> {
        let queues = run_async("lpstat", &["-e"], &[0])
            .await?
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        let default_output = run_async("lpstat", &["-d"], &[0, 1])
            .await
            .unwrap_or_default();
        let default_queue = parse_default_printer(&default_output);
        Ok(queues
            .into_iter()
            .map(|queue| PrinterDescriptor {
                is_default: Some(queue.as_str()) == default_queue.as_deref(),
                display_name: queue.clone(),
                queue_name: queue,
            })
            .collect())
    }

    pub async fn submit(
        &self,
        pdf_path: &Path,
        printer: &str,
        title: &str,
        profile: &PrinterProfile,
    ) -> Result<SubmittedPrintJob, PrintError> {
        let mut arguments = vec![
            "-d".into(),
            printer.to_string(),
            "-t".into(),
            title.to_string(),
            "-o".into(),
            "sides=one-sided".into(),
            "-o".into(),
            "copies=1".into(),
            "-o".into(),
            "number-up=1".into(),
            "-o".into(),
            format!("media={}", profile.paper_size.cups_value()),
        ];
        match profile.color_mode {
            ColorMode::Automatic => {}
            ColorMode::Grayscale => {
                arguments.push("-o".into());
                arguments.push("ColorModel=Gray".into());
            }
            ColorMode::Color => {
                arguments.push("-o".into());
                arguments.push("ColorModel=RGB".into());
            }
        }
        for (key, value) in &profile.cups_options {
            arguments.push("-o".into());
            arguments.push(format!("{key}={value}"));
        }

        let printer_options = run_async("lpoptions", &["-p", printer, "-l"], &[0, 1])
            .await
            .unwrap_or_default();
        if supports_epson_skip_blank_control(&printer_options) {
            arguments.push("-o".into());
            arguments.push("EPIJ_BSSv=0".into());
        }
        arguments.push(pdf_path.display().to_string());

        let arg_refs: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let response = run_async("lp", &arg_refs, &[0]).await?;
        let id = parse_submitted_job_id(&response).ok_or(PrintError::NoJobId(response.clone()))?;
        Ok(SubmittedPrintJob {
            id,
            printer: printer.to_string(),
            title: title.to_string(),
        })
    }

    pub async fn wait_until_finished(&self, job: &SubmittedPrintJob) -> Result<(), PrintError> {
        let mut consecutive_missing = 0u8;
        loop {
            let active = run_async(
                "lpstat",
                &job_status_arguments(&job.printer, false),
                &[0, 1],
            )
            .await?;
            if contains_job(&active, &job.id) {
                consecutive_missing = 0;
                tokio::time::sleep(self.poll_interval).await;
                continue;
            }

            let completed = run_async(
                "lpstat",
                &job_status_arguments(&job.printer, true),
                &[0, 1],
            )
            .await?;
            if contains_job(&completed, &job.id) {
                return Ok(());
            }

            consecutive_missing += 1;
            if consecutive_missing >= 2 {
                return Ok(());
            }
            tokio::time::sleep(self.poll_interval).await;
        }
    }

    pub async fn cancel(&self, job: &SubmittedPrintJob) {
        let _ = run_async("cancel", &[&job.id], &[0, 1]).await;
    }
}

async fn run_async(
    executable: &str,
    arguments: &[&str],
    accepts: &[i32],
) -> Result<String, PrintError> {
    let executable = executable.to_string();
    let arguments: Vec<String> = arguments.iter().map(|s| (*s).to_string()).collect();
    let accepts = accepts.to_vec();
    tokio::task::spawn_blocking(move || run_blocking(&executable, &arguments, &accepts))
        .await
        .map_err(|err| PrintError::Message(format!("CUPS task join failed: {err}")))?
}

fn run_blocking(
    executable: &str,
    arguments: &[String],
    accepts: &[i32],
) -> Result<String, PrintError> {
    let output = Command::new(executable).args(arguments).output()?;
    let code = output.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !accepts.contains(&code) {
        let message = if stderr.trim().is_empty() {
            stdout
        } else {
            stderr
        };
        return Err(PrintError::CommandFailed {
            command: format!("{executable} {}", arguments.join(" ")),
            message,
        });
    }
    Ok(stdout)
}

fn parse_submitted_job_id(output: &str) -> Option<String> {
    let re = Regex::new(r"(?i)request id is\s+([^\s]+-\d+)").ok()?;
    re.captures(output)
        .and_then(|caps| caps.get(1).map(|m| m.as_str().to_string()))
}

fn parse_default_printer(output: &str) -> Option<String> {
    output
        .split_once(':')
        .map(|(_, rest)| rest.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn job_status_arguments(printer: &str, completed: bool) -> [&str; 4] {
    if completed {
        ["-W", "completed", "-o", printer]
    } else {
        ["-W", "not-completed", "-o", printer]
    }
}

fn contains_job(output: &str, id: &str) -> bool {
    output.lines().any(|line| {
        line.split_whitespace()
            .next()
            .map(|token| token == id)
            .unwrap_or(false)
    })
}

fn supports_epson_skip_blank_control(output: &str) -> bool {
    output
        .lines()
        .any(|line| line.starts_with("EPIJ_BSSv/Skip Blank Page:"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_job_id() {
        assert_eq!(
            parse_submitted_job_id("request id is EPSON_L3250-42 (1 file(s))"),
            Some("EPSON_L3250-42".into())
        );
    }

    #[test]
    fn parses_default_printer() {
        assert_eq!(
            parse_default_printer("system default destination: Office_Printer"),
            Some("Office_Printer".into())
        );
    }

    #[test]
    fn detects_epson_blank_skip() {
        assert!(supports_epson_skip_blank_control(
            "EPIJ_BSSv/Skip Blank Page: True\nmedia/Media Size: *A4"
        ));
        assert!(!supports_epson_skip_blank_control("media/Media Size: *A4"));
    }
}
