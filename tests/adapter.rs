#![cfg(unix)]

use std::time::Duration;

use counterweave::adapter::AdapterRunner;
use counterweave::artifact::{
    CaseArtifact, GenerationProvenance, Intent, ModelProvenance, PackIdentity, RunOutcome,
};
use counterweave::choice::ChoiceSession;

fn case() -> CaseArtifact {
    CaseArtifact::new(
        PackIdentity {
            name: "adapter-test".to_owned(),
            version: "1".to_owned(),
        },
        Intent {
            kind: "satisfy".to_owned(),
            target: "adapter-protocol".to_owned(),
        },
        GenerationProvenance {
            choices: ChoiceSession::recording(42).finish().unwrap(),
            model: ModelProvenance {
                backend: "test".to_owned(),
                solver: "test".to_owned(),
                minizinc_version: "test".to_owned(),
                model_hash: "test".to_owned(),
                solver_seed: None,
            },
        },
        serde_json::json!({"input": 3}),
    )
}

#[test]
fn captures_json_observations() {
    let runner = AdapterRunner::new("/bin/sh").arguments(vec![
        "-c".to_owned(),
        "sed -n '$p' >/dev/null; printf '{\"observed\":3}'".to_owned(),
    ]);
    let run = runner.execute(&case()).unwrap();
    assert_eq!(run.outcome, RunOutcome::Completed);
    assert_eq!(run.observations, Some(serde_json::json!({"observed": 3})));
}

#[test]
fn classifies_invalid_adapter_output() {
    let runner = AdapterRunner::new("/bin/sh").arguments(vec![
        "-c".to_owned(),
        "sed -n '$p' >/dev/null; printf 'not-json'".to_owned(),
    ]);
    let run = runner.execute(&case()).unwrap();
    assert_eq!(run.outcome, RunOutcome::ProtocolError);
    assert_eq!(run.raw_stdout.as_deref(), Some("not-json"));
}

#[test]
fn classifies_a_nonzero_adapter_exit() {
    let runner = AdapterRunner::new("/bin/sh").arguments(vec![
        "-c".to_owned(),
        "sed -n '$p' >/dev/null; printf 'partial'; printf 'failed' >&2; exit 7".to_owned(),
    ]);
    let run = runner.execute(&case()).unwrap();
    assert_eq!(run.outcome, RunOutcome::Failed);
    assert_eq!(run.exit_code, Some(7));
    assert_eq!(run.raw_stdout.as_deref(), Some("partial"));
    assert_eq!(run.stderr, "failed");
}

#[test]
fn kills_an_adapter_after_its_deadline() {
    let runner = AdapterRunner::new("/bin/sh")
        .arguments(vec!["-c".to_owned(), "sleep 2".to_owned()])
        .timeout(Duration::from_millis(20));
    let run = runner.execute(&case()).unwrap();
    assert_eq!(run.outcome, RunOutcome::Timeout);
}
