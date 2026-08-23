//! Durable case and execution artifacts.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::choice::ChoiceTape;

const CASE_FORMAT: &str = "counterweave.case/1";
const RUN_FORMAT: &str = "counterweave.run/1";

/// Identity and compatibility version of a model pack.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PackIdentity {
    /// Stable pack name.
    pub name: String,
    /// Pack-defined compatibility version.
    pub version: String,
}

/// Named generation intention.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    /// Intent family such as `satisfy`, `reach`, `reject`, or `violate`.
    pub kind: String,
    /// Pack-defined target name.
    pub target: String,
}

/// Constraint model and solver provenance.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ModelProvenance {
    /// Backend family.
    pub backend: String,
    /// Selected backend solver.
    pub solver: String,
    /// Observed `MiniZinc` version string.
    pub minizinc_version: String,
    /// BLAKE3 digest of the model entry point.
    pub model_hash: String,
    /// Random seed supplied to the solver when its interface supports one.
    pub solver_seed: Option<u64>,
}

/// Generation provenance required to explain or regenerate a case.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct GenerationProvenance {
    /// Replayable semantic and solver-diversity choices.
    pub choices: ChoiceTape,
    /// Model and solver identity.
    pub model: ModelProvenance,
}

/// A materialized scenario, authoritative for execution replay.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CaseArtifact {
    /// Artifact format identifier.
    pub format: String,
    /// Model pack that owns the opaque payload.
    pub pack: PackIdentity,
    /// Intention that led to this scenario.
    pub intent: Intent,
    /// Generation provenance.
    pub provenance: GenerationProvenance,
    /// Pack-specific scenario data.
    pub payload: Value,
}

impl CaseArtifact {
    /// Construct a version-one case.
    #[must_use]
    pub fn new(
        pack: PackIdentity,
        intent: Intent,
        provenance: GenerationProvenance,
        payload: Value,
    ) -> Self {
        Self {
            format: CASE_FORMAT.to_owned(),
            pack,
            intent,
            provenance,
            payload,
        }
    }

    /// Read and validate a case artifact.
    ///
    /// # Errors
    ///
    /// Returns an I/O, JSON, or format error.
    pub fn read(path: &Path) -> Result<Self, ArtifactError> {
        let case: Self = serde_json::from_slice(&fs::read(path)?)?;
        if case.format != CASE_FORMAT {
            return Err(ArtifactError::UnsupportedFormat(case.format));
        }
        Ok(case)
    }

    /// Write a human-readable case artifact atomically.
    ///
    /// # Errors
    ///
    /// Returns an I/O or JSON encoding error.
    pub fn write(&self, path: &Path) -> Result<(), ArtifactError> {
        write_json_atomically(path, self)
    }

    /// Return a digest of the canonical compact JSON representation.
    ///
    /// # Errors
    ///
    /// Returns a JSON encoding error.
    pub fn digest(&self) -> Result<String, ArtifactError> {
        Ok(blake3::hash(&serde_json::to_vec(self)?)
            .to_hex()
            .to_string())
    }
}

/// Result class of one adapter process.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RunOutcome {
    /// Adapter exited successfully and returned JSON observations.
    Completed,
    /// Adapter exited unsuccessfully.
    Failed,
    /// Adapter exceeded its deadline.
    Timeout,
    /// Adapter returned invalid protocol output.
    ProtocolError,
}

/// Durable observation record for one case execution.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunArtifact {
    /// Artifact format identifier.
    pub format: String,
    /// Digest of the exact case that was executed.
    pub case_hash: String,
    /// Adapter executable as invoked.
    pub adapter: String,
    /// Process-level outcome.
    pub outcome: RunOutcome,
    /// Parsed adapter observations, when available.
    pub observations: Option<Value>,
    /// Captured standard error.
    pub stderr: String,
    /// Captured standard output when it was not valid observation JSON.
    pub raw_stdout: Option<String>,
    /// Process exit code when one was available.
    pub exit_code: Option<i32>,
    /// Elapsed execution time in milliseconds.
    pub duration_ms: u128,
}

impl RunArtifact {
    /// Construct an empty run envelope.
    #[must_use]
    pub fn new(case_hash: String, adapter: String) -> Self {
        Self {
            format: RUN_FORMAT.to_owned(),
            case_hash,
            adapter,
            outcome: RunOutcome::Failed,
            observations: None,
            stderr: String::new(),
            raw_stdout: None,
            exit_code: None,
            duration_ms: 0,
        }
    }

    /// Write a human-readable run artifact atomically.
    ///
    /// # Errors
    ///
    /// Returns an I/O or JSON encoding error.
    pub fn write(&self, path: &Path) -> Result<(), ArtifactError> {
        write_json_atomically(path, self)
    }
}

/// Artifact read, validation, or write failure.
#[derive(Debug, Error)]
pub enum ArtifactError {
    /// Filesystem error.
    #[error(transparent)]
    Io(#[from] io::Error),
    /// JSON encoding or decoding error.
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    /// Unsupported artifact version.
    #[error("unsupported artifact format `{0}`")]
    UnsupportedFormat(String),
}

fn write_json_atomically<T: Serialize>(path: &Path, value: &T) -> Result<(), ArtifactError> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("artifact");
    let temporary = path.with_file_name(format!(".{file_name}.tmp-{}", std::process::id()));
    fs::write(&temporary, serde_json::to_vec_pretty(value)?)?;
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::choice::ChoiceSession;

    #[test]
    fn case_round_trip_preserves_payload_and_tape() {
        let tape = ChoiceSession::recording(42).finish().unwrap();
        let case = CaseArtifact::new(
            PackIdentity {
                name: "demo".to_owned(),
                version: "1".to_owned(),
            },
            Intent {
                kind: "reach".to_owned(),
                target: "boundary".to_owned(),
            },
            GenerationProvenance {
                choices: tape,
                model: ModelProvenance {
                    backend: "minizinc".to_owned(),
                    solver: "cp-sat".to_owned(),
                    minizinc_version: "test".to_owned(),
                    model_hash: "abc".to_owned(),
                    solver_seed: Some(7),
                },
            },
            serde_json::json!({"value": 3}),
        );

        let encoded = serde_json::to_vec(&case).unwrap();
        let decoded: CaseArtifact = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(case, decoded);
        assert_eq!(case.digest().unwrap(), decoded.digest().unwrap());
    }
}
