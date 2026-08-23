//! Constraint-guided generative testing for whole systems.
//!
//! Counterweave separates replayable random choices from constraint solving.
//! Choices select the kind and shape of a scenario. A solver completes those
//! choices into a coherent case, which can then be executed through an
//! isolated system adapter.

pub mod adapter;
pub mod artifact;
pub mod choice;
pub mod minizinc;

pub use adapter::AdapterRunner;
pub use artifact::{CaseArtifact, Intent, PackIdentity, RunArtifact};
pub use choice::{ChoiceError, ChoiceSession, ChoiceTape, ForkPath};
pub use minizinc::{MiniZinc, MiniZincError, MiniZincSolution};
