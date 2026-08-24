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
- A semantic failure identity is the property name plus its stable failure
  fingerprint. Never compare or reduce by fingerprint alone.
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
- Persist both the readable fork path and its injective encoded key so a tape
  can be decoded and replayed in a later process.
- A materialized case is authoritative for execution replay and must not need
  MiniZinc. Solver-backed regeneration is diagnostic and may vary when pinned
  tool versions change.
- Keep the artifact envelope generic and the model-pack payload opaque. Do not
  invent a universal system-operation language without evidence from several
  independent model packs.
- A model pack may own a typed step schema. Its Ada adapter must iterate the
  materialized steps deterministically and compare modeled outcomes with actual
  returns or exceptions; it must not replace generated steps with handwritten
  calls.
- An adapter may attach `counterweave.trace/1` to its semantic result. Keep the
  trace in execution order and align every action with its model expectation,
  observed result, `match`/`divergence`/`violation` status, and stable model
  source. The trace is explanatory and must not become a second verdict or
  shrink-retention oracle.
- Trace model and observed values describe state after the transition; do not
  fill both columns with equivalent call-result words. The live failure path
  begins with one matched transition establishing relevant state before the
  first mismatch and ends at the first property violation. The durable artifact
  retains setup and later consequences outside that causal slice.
- Keep generation, execution, and judgment separate. Adapters translate and
  observe; they should not duplicate an external reference oracle.
- Search derives every trial from an indexed campaign fork, runs one MiniZinc
  completion and one adapter execution per case, and retains the first semantic
  failure. Infrastructure failures must not be reported as discovered bugs.
- `generate` and `search` use a fresh entropy-derived root seed when the caller
  omits `--seed`. Examples preserve that exploratory default and expose an
  explicit seed override for reproducible checks. Never draw fresh entropy when
  replaying a choice tape or campaign.
- A normal adapter process exits successfully and emits
  `counterweave.adapter-result/1`. Nonzero adapter exit is always
  infrastructure failure. Preserve process outcome separately from `pass`,
  `property-violation`, and `invalid-case`.
- Campaign artifacts record every indexed seed and semantic case identity.
  Campaign replay checks model, data, and adapter provenance before execution
  and verifies every attempt afterward.
- Semantic case identity canonicalizes JSON object order, whitespace, string
  escapes, and exact decimal spelling. Changing that persisted definition
  requires a new campaign and reduction artifact version.
- Reduction mutates recorded named-fork choices, normalizes each candidate to
  the choices consumed during replay, regenerates it through the model, and
  retains it only when the same property and failure fingerprint remain.
- Choice values descend numerically. Interesting boundaries are probes, not an
  alternate order that can strand reduction at a larger raw value. Apply the
  complete integer portfolio atomically to duplicates. Bound candidate
  evaluation with the configured attempt ceiling, retain and revalidate the
  best tape, and record whether reduction reached a fixed point or the ceiling.
- Execute adapters out of process with bounded deadlines and output. Preserve
  successful, failed, timed-out, output-limit, spawn-error, and
  malformed-protocol outcomes distinctly.
- Counterweave may provide controlled application checkpoints, but must not
  claim control over uninstrumented native scheduling or kernel events.

## Ada implementation

- Keep the initial implementation a modular monolith. Split crates only when
  an independently versioned consumer or dependency boundary exists.
- The engine and bundled adapters are Ada. Do not introduce a foreign-language
  runtime unless an implemented backend requires one and the boundary is
  independently justified.
- Serialize durable formats with explicit identifiers such as
  `counterweave.case/2`; reject unknown versions rather than guessing.
- Parse JSON structurally with scoped member access. Reject malformed values,
  duplicate members, trailing data, and type mismatches before execution.
- Use stable hashing or derivation algorithms where persisted behavior depends
  on them. Fork encoding must remain injective across path structures.
- Avoid ambient randomness. Route every test-relevant random decision through
  a recorded choice fork.
- Flyology TUI is a presentation layer selected only when standard input and
  output are usable terminals. Plain output remains authoritative for CI,
  redirection, and automation; UI selection must not affect artifacts.
- Resolve `flyology_tui` through Flyology's Alire index. Do not bypass index
  metadata with a direct manifest pin.
- TUI quit keys request bounded child cancellation and wait for owned cleanup
  before restoring the terminal; do not abandon a solver or adapter process.
- Interactive reduction completion remains in the full-terminal Flyology TUI
  until Enter, Escape, `q`, or Ctrl-C dismisses it. Lead with the causal failure
  path, keep it within the terminal height, and restore the shell by closing the
  existing backend once. Do not repaint through a second static renderer.
- Interactive search leaves a Flyology TUI final report in the normal terminal
  with the verdict, campaign root seed, distinct derived trial seed, evidence
  paths, and exact replay command. Plain output remains stable for redirected
  and automated execution.
- Trace views use Flyology TUI's table component with every column non-sortable
  so execution order cannot change. Keep shrink progress in its own activity
  section, retain non-color status markers, fit live panels to terminal height,
  and leave the shell cursor below final reports.
- Keep handwritten Ada to 110 columns. Run GNATformat with
  `-P counterweave.gpr`, then run `alr -n build` and `alr -n test` after Ada
  edits.

## MiniZinc models

- Distinguish structural assumptions, state invariants, transitions, targets,
  and observations. Do not describe a valid snapshot as reachable unless the
  model includes the required transition history.
- Ask for one completion per sampled intent. Do not enumerate all solutions as
  a substitute for random exploration.
- Treat solver seeds, randomized objectives, and hash partitions as diversity
  mechanisms, not evidence of uniform solution sampling.
- Every model declares the reserved `counterweave_diversity_seed` parameter.
  Use it only as a replayable partition or objective input over pack-owned
  decisions; do not draw ambient randomness inside a model or adapter.
- Preserve model and solver diagnostics in failure evidence. Pin the validated
  MiniZinc and solver versions in CI once the first model pack is added.

## Ada adapters

- Ada adapters are test executables linked against the exact library and, when
  applicable, runtime under test. Prefer the process protocol over an in-process
  boundary so crashes and hangs remain isolated.
- Keep adapter dispatch mechanical: decode, initialize, call public operations,
  capture canonical observations, and clean up.
- Test-only observers expose narrow semantic snapshots rather than new public
  production APIs. Production code must not retain random decisions or enabled
  fault behavior.
- Use the owning GPR project's GNATformat configuration.

## Verification and commits

- Unit-test fork independence, exact replay, fail-closed replay, artifact
  round-trips, process timeouts, and protocol classification.
- Integration-test MiniZinc completion separately so the Ada unit suite can
  still explain a missing external solver clearly.
- A counterexample is not minimized unless the reduced case preserves the same
  property and stable failure fingerprint.
- Follow the repository Problem/Solution commit format and keep each commit
  focused on one independently understandable problem.
