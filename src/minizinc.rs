//! MiniZinc-backed one-solution completion.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;
use thiserror::Error;

/// One completed `MiniZinc` solution and its diagnostic output.
#[derive(Clone, Debug, PartialEq)]
pub struct MiniZincSolution {
    /// JSON solution emitted by `MiniZinc`.
    pub value: Value,
    /// `MiniZinc` standard error, including non-fatal warnings.
    pub diagnostics: String,
    /// Whether the configured solver interface accepted the requested seed.
    pub random_seed_applied: bool,
}

/// `MiniZinc` process configuration.
#[derive(Clone, Debug)]
pub struct MiniZinc {
    executable: PathBuf,
    solver: String,
}

impl MiniZinc {
    /// Use `minizinc` from `PATH` with the selected solver.
    #[must_use]
    pub fn new(solver: impl Into<String>) -> Self {
        Self {
            executable: PathBuf::from("minizinc"),
            solver: solver.into(),
        }
    }

    /// Override the `MiniZinc` executable.
    #[must_use]
    pub fn executable(mut self, executable: impl Into<PathBuf>) -> Self {
        self.executable = executable.into();
        self
    }

    /// Return the selected solver identifier.
    #[must_use]
    pub fn solver(&self) -> &str {
        &self.solver
    }

    /// Query the installed `MiniZinc` version.
    ///
    /// # Errors
    ///
    /// Returns an error when `MiniZinc` cannot be launched or exits unsuccessfully.
    pub fn version(&self) -> Result<String, MiniZincError> {
        let output = Command::new(&self.executable).arg("--version").output()?;
        if !output.status.success() {
            return Err(MiniZincError::Process {
                status: output.status.code(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            });
        }
        Ok(String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned())
    }

    /// Solve one satisfying assignment and return `MiniZinc`'s JSON output.
    ///
    /// # Errors
    ///
    /// Returns an error for process failures, unsatisfiable models, or malformed
    /// solution output.
    pub fn solve_one(
        &self,
        model: &Path,
        data: Option<&Path>,
        random_seed: u64,
    ) -> Result<MiniZincSolution, MiniZincError> {
        let solver_seed = random_seed % (i32::MAX as u64 + 1);
        let mut command = Command::new(&self.executable);
        command
            .arg("--solver")
            .arg(&self.solver)
            .arg("--output-mode")
            .arg("json");
        let random_seed_applied =
            matches!(self.solver.as_str(), "cp-sat" | "org.minizinc.or-tools");
        if random_seed_applied {
            command
                .arg("--fzn-flag")
                .arg(format!("--params=random_seed:{solver_seed}"));
        }
        command.arg(model);
        if let Some(data) = data {
            command.arg(data);
        }

        let output = command.output()?;
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        if !output.status.success() {
            return Err(MiniZincError::Process {
                status: output.status.code(),
                stderr,
            });
        }
        if stdout.contains("=====UNSATISFIABLE=====") {
            return Err(MiniZincError::Unsatisfiable);
        }

        let value = parse_first_json_value(&stdout)?;
        Ok(MiniZincSolution {
            value,
            diagnostics: stderr,
            random_seed_applied,
        })
    }
}

/// `MiniZinc` invocation or result failure.
#[derive(Debug, Error)]
pub enum MiniZincError {
    /// `MiniZinc` could not be started.
    #[error("could not execute MiniZinc: {0}")]
    Io(#[from] std::io::Error),
    /// `MiniZinc` exited unsuccessfully.
    #[error("MiniZinc failed with status {status:?}: {stderr}")]
    Process {
        /// Process exit code, if reported.
        status: Option<i32>,
        /// Captured diagnostic output.
        stderr: String,
    },
    /// The selected model and data were unsatisfiable.
    #[error("MiniZinc model is unsatisfiable")]
    Unsatisfiable,
    /// `MiniZinc` did not emit a JSON solution.
    #[error("MiniZinc emitted no JSON solution")]
    MissingSolution,
    /// `MiniZinc` emitted malformed JSON.
    #[error("invalid MiniZinc JSON solution: {0}")]
    InvalidSolution(#[from] serde_json::Error),
}

fn parse_first_json_value(output: &str) -> Result<Value, MiniZincError> {
    let start = output
        .find(['{', '['])
        .ok_or(MiniZincError::MissingSolution)?;
    let mut values = serde_json::Deserializer::from_str(&output[start..]).into_iter::<Value>();
    values
        .next()
        .ok_or(MiniZincError::MissingSolution)?
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_first_solution_before_minizinc_delimiter() {
        let output = "{\n  \"x\": 3\n}\n----------\n";
        assert_eq!(
            parse_first_json_value(output).unwrap(),
            serde_json::json!({"x": 3})
        );
    }

    #[test]
    fn rejects_output_without_a_solution() {
        assert!(matches!(
            parse_first_json_value("==========\n"),
            Err(MiniZincError::MissingSolution)
        ));
    }
}
