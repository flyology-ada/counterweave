//! Isolated process adapter execution.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;
use thiserror::Error;
use wait_timeout::ChildExt;

use crate::artifact::{CaseArtifact, RunArtifact, RunOutcome};

/// Configuration for one process-isolated system adapter.
#[derive(Clone, Debug)]
pub struct AdapterRunner {
    executable: PathBuf,
    arguments: Vec<String>,
    timeout: Duration,
}

impl AdapterRunner {
    /// Create an adapter runner with a five-second deadline.
    #[must_use]
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            arguments: Vec::new(),
            timeout: Duration::from_secs(5),
        }
    }

    /// Supply fixed adapter arguments.
    #[must_use]
    pub fn arguments(mut self, arguments: Vec<String>) -> Self {
        self.arguments = arguments;
        self
    }

    /// Set the per-case execution deadline.
    #[must_use]
    pub const fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Execute one materialized case.
    ///
    /// The case is written to adapter standard input. Successful adapters must
    /// write exactly one JSON observation value to standard output.
    ///
    /// # Errors
    ///
    /// Returns an error when the case cannot be encoded or the adapter process
    /// cannot be managed. Product failures remain represented in the returned
    /// run artifact.
    pub fn execute(&self, case: &CaseArtifact) -> Result<RunArtifact, AdapterError> {
        let started = Instant::now();
        let adapter_name = self.executable.display().to_string();
        let mut run = RunArtifact::new(case.digest()?, adapter_name);
        let mut child = Command::new(&self.executable)
            .args(&self.arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or(AdapterError::MissingPipe("stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or(AdapterError::MissingPipe("stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or(AdapterError::MissingPipe("stderr"))?;

        let stdout_reader = thread::spawn(move || read_all(stdout));
        let stderr_reader = thread::spawn(move || read_all(stderr));
        serde_json::to_writer(&mut stdin, case)?;
        stdin.flush()?;
        drop(stdin);

        let status = if let Some(status) = child.wait_timeout(self.timeout)? {
            Some(status)
        } else {
            child.kill()?;
            let _ = child.wait()?;
            None
        };

        let stdout = stdout_reader
            .join()
            .map_err(|_| AdapterError::ReaderPanic("stdout"))??;
        let stderr = stderr_reader
            .join()
            .map_err(|_| AdapterError::ReaderPanic("stderr"))??;
        run.duration_ms = started.elapsed().as_millis();
        run.stderr = String::from_utf8_lossy(&stderr).into_owned();

        match status {
            None => run.outcome = RunOutcome::Timeout,
            Some(status) if !status.success() => {
                run.outcome = RunOutcome::Failed;
                run.exit_code = status.code();
                if !stdout.is_empty() {
                    run.raw_stdout = Some(String::from_utf8_lossy(&stdout).into_owned());
                }
            }
            Some(status) => {
                run.exit_code = status.code();
                if let Ok(observations) = serde_json::from_slice::<Value>(&stdout) {
                    run.outcome = RunOutcome::Completed;
                    run.observations = Some(observations);
                } else {
                    run.outcome = RunOutcome::ProtocolError;
                    run.raw_stdout = Some(String::from_utf8_lossy(&stdout).into_owned());
                }
            }
        }

        Ok(run)
    }

    /// Return the configured executable.
    #[must_use]
    pub fn executable(&self) -> &Path {
        &self.executable
    }
}

/// Adapter process-management failure.
#[derive(Debug, Error)]
pub enum AdapterError {
    /// Filesystem or process error.
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// Case encoding error.
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    /// Artifact digest error.
    #[error(transparent)]
    Artifact(#[from] crate::artifact::ArtifactError),
    /// A requested process pipe was unexpectedly absent.
    #[error("adapter {0} pipe was not available")]
    MissingPipe(&'static str),
    /// A pipe reader thread panicked.
    #[error("adapter {0} reader thread panicked")]
    ReaderPanic(&'static str),
}

fn read_all(mut reader: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;
    Ok(bytes)
}
