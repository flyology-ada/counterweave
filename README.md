# Counterweave

Constraint-guided generative testing for whole systems.

Counterweave combines replayable random choices with constraint solving. The
choice layer selects a testing intent and meaningful scenario parameters; a
MiniZinc model completes those decisions into a coherent, materialized case.
An isolated adapter process can then execute that case against an Ada, Rust, or
other system under test.

Counterweave is experimental. The current repository establishes the first
vertical slice: named choice forks, one-solution MiniZinc completion, durable
case and run artifacts, and a bounded process adapter protocol. It does not yet
provide campaigns, semantic counterexample reduction, or an oracle protocol.

## Why constraint-guided generation

Ordinary value generators establish local shape. Counterweave is intended for
relationships that span a system: ownership, generations, topology, capacity,
time, operation history, and deliberately rejected actions. MiniZinc is the
constraint-preserving completion engine, not Counterweave's source of
randomness.

Randomness comes from a recorded tree of named and indexed choice forks. A
fork derives only from the root seed and its complete path, so consuming one
actor's stream does not shift another actor's choices. Artifacts retain the
actual consumed values as well as the seed.

## Current flow

```text
choice forks + JSON parameters
             |
             v
       MiniZinc model
             |
             v
      materialized .cwcase
             |
             v
       adapter subprocess
             |
             v
          .cwrun
```

The `.cwcase` is authoritative for execution replay. Running a saved case does
not invoke MiniZinc. Regenerating a case additionally depends on the recorded
choices, model, MiniZinc version, and selected solver.

## Build and test

Counterweave currently requires Rust and, for generation, MiniZinc with a
selected backend solver.

```sh
cargo build
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-targets --all-features
```

## Generate a case

The bundled model assigns distinct capacity slots to a generated number of
actors. `--draw` selects semantic MiniZinc input through a named replayable
fork; MiniZinc fills in the constrained allocation.

```sh
cargo run -- generate \
  --model examples/simple/model.mzn \
  --data examples/simple/data.json \
  --draw actors=2..5 \
  --seed 42 \
  --pack simple \
  --intent reach \
  --target distinct-allocation \
  --output /tmp/simple.cwcase
```

Inspect the resulting envelope and opaque model-pack payload:

```sh
cargo run -- inspect /tmp/simple.cwcase --payload
```

Counterweave asks MiniZinc for one solution. The backend seed is a diversity
mechanism and does not imply uniform sampling over satisfying assignments.

## Execute a case

An adapter reads one case JSON value from standard input and writes one
canonical observation JSON value to standard output. It runs in a separate
process under a deadline.

```sh
chmod +x examples/simple/adapter.sh
cargo run -- execute \
  --case /tmp/simple.cwcase \
  --adapter examples/simple/adapter.sh \
  --output /tmp/simple.cwrun
```

A real Flyology adapter will be an Ada test executable linked against the exact
Flyology library and test runtime under examination. It will decode the opaque
payload, call public operations, capture narrow canonical observations, and
exit. Counterweave classifies successful observations, nonzero exits, timeouts,
and malformed protocol output separately.

See [`docs/design.md`](docs/design.md) for the architecture and the boundaries
that later campaign, oracle, and reducer work must preserve.

## Agent setup

Counterweave copies Flyology's APM-managed agent-resource workflow. Install the
validated APM release and reproduce the pinned dependency graph:

```sh
pip install apm-cli==0.28.0
apm install --frozen
apm compile --target codex
apm audit --ci
```

The generated `AGENTS.md` remains committed. Local Claude rules and installed
skill directories are generated from the same graph and ignored. Update the
shared `flyology-ada/agents` dependency explicitly and commit the reviewed
lockfile and generated instructions together.

## License

Counterweave is distributed under the terms of either the Apache License 2.0
or the MIT License, at your option.
