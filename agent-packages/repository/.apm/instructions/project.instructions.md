---
description: Preserve Counterweave's architecture, terminology, replay guarantees, and verification workflow.
---

# Counterweave agent guide

This file records durable project rules for coding agents. Keep it concise and
update it when the architecture, artifact formats, or verification workflow
changes. `README.md` is the user-facing introduction; executable tests and
commands remain authoritative.

## Project identity and language

- The project is **Counterweave**: constraint-guided generative testing for
  whole systems.
- A **choice tape** records consumed random decisions. A named, indexed
  **fork** is an independently derived choice stream whose consumption does not
  shift sibling streams.
- An **intent** selects the kind of scenario to seek. A constraint **model**
  completes that intent into a materialized **case**. An **adapter** executes
  the case against a system under test and emits canonical **observations**.
- Exact replay uses a materialized case. Generation replay additionally
  depends on the recorded choice tape, model, MiniZinc version, and solver.
- Write modest, factual prose. Do not claim uniform sampling, exhaustive
  exploration, deterministic kernel scheduling, or proof beyond checked
  bounds.

## Before changing anything

- Run `git status --short --branch`. Preserve unrelated user changes.
- Read the relevant `README.md` or design section and the implementation.
- Use `rg` and `rg --files` for discovery and `apply_patch` for hand edits.
- Keep changes focused. Do not introduce another backend, protocol, service,
  or abstraction before an implemented use requires it.
- Run `gh` outside the sandbox. Repository: `flyology-ada/counterweave`.

## Architecture boundaries

- Random choices select semantic intent, scenario shape, solver diversity,
  fault injection, and controlled execution schedules. MiniZinc is a
  constraint-preserving completion engine, not the source of randomness.
- Named forks must derive only from the root seed and complete fork path.
  Adding or consuming a sibling must not change another fork's stream.
- Replay artifacts record consumed values, not only an RNG seed. Replay fails
  closed on missing, exhausted, duplicate, unused, or unsupported tape data.
- A materialized case is authoritative for execution replay and must not need
  MiniZinc. Solver-backed regeneration is diagnostic and may vary when pinned
  tool versions change.
- Keep the artifact envelope generic and the model-pack payload opaque. Do not
  invent a universal system-operation language without evidence from several
  independent model packs.
- Keep generation, execution, and judgment separate. Adapters translate and
  observe; they should not duplicate an external reference oracle.
- Execute adapters out of process with bounded deadlines. Treat nonzero exits,
  signals, timeouts, and malformed protocol output as distinct outcomes.
- Counterweave may provide controlled application checkpoints, but must not
  claim control over uninstrumented native scheduling or kernel events.

## Rust implementation

- Keep the initial implementation a modular monolith. Split crates only when
  an independently versioned consumer or dependency boundary exists.
- Forbid unsafe Rust unless a reviewed requirement makes it unavoidable.
- Serialize durable formats with explicit identifiers such as
  `counterweave.case/1`; reject unknown versions rather than guessing.
- Use stable hashing or derivation algorithms where persisted behavior depends
  on them. Do not use Rust's unspecified `DefaultHasher` for fork derivation.
- Avoid ambient randomness. Route every test-relevant random decision through
  a recorded choice fork.
- Run `cargo fmt --check`, `cargo clippy --all-targets --all-features --
  -D warnings`, and `cargo test --all-targets --all-features` after Rust edits.

## MiniZinc models

- Distinguish structural assumptions, state invariants, transitions, targets,
  and observations. Do not describe a valid snapshot as reachable unless the
  model includes the required transition history.
- Ask for one completion per sampled intent. Do not enumerate all solutions as
  a substitute for random exploration.
- Treat solver seeds, randomized objectives, and hash partitions as diversity
  mechanisms, not evidence of uniform solution sampling.
- Preserve model and solver diagnostics in failure evidence. Pin the validated
  MiniZinc and solver versions in CI once the first model pack is added.

## Ada adapters

- Ada adapters are test executables linked against the exact library and, when
  applicable, runtime under test. Prefer a process protocol over a Rust/Ada FFI
  boundary so crashes and hangs remain isolated.
- Keep adapter dispatch mechanical: decode, initialize, call public operations,
  capture canonical observations, and clean up.
- Test-only observers expose narrow semantic snapshots rather than new public
  production APIs. Production code must not retain random decisions or enabled
  fault behavior.
- Keep handwritten Ada to 110 columns and use the owning GPR project's
  GNATformat configuration.

## Verification and commits

- Unit-test fork independence, exact replay, fail-closed replay, artifact
  round-trips, process timeouts, and protocol classification.
- Integration-test MiniZinc completion separately so the Rust unit suite can
  still explain a missing external solver clearly.
- A counterexample is not minimized unless the reduced case preserves the same
  stable failure fingerprint.
- Follow the repository Problem/Solution commit format and keep each commit
  focused on one independently understandable problem.
