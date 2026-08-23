# Counterweave design

## Contract

Given an intent and replayable Ada choices, Counterweave materializes a bounded
scenario satisfying a constraint model, executes it through an Ada-compatible
process adapter, and preserves evidence needed to reproduce the observation.

Counterweave does not claim uniform sampling, exhaustive exploration, proof
beyond model bounds, or deterministic control of native and kernel scheduling.

## Components

```text
Ada choice forks -> MiniZinc completion -> .cwcase
                                           |
                                           v
                                  Ada adapter process
                                           |
                                           v
                                         .cwrun

campaign seed -> indexed trial fork -> generate + execute -> pass -> next fork
                                                       |
                                                       +-> fail -> retain pair
```

- `Counterweave.Choices` owns structurally independent replay streams and the
  recorded choice tape.
- `Counterweave.MiniZinc` asks for one completion under a bounded deadline and
  records the seed actually supplied to supported solvers.
- `Counterweave.Artifacts` writes versioned JSON cases and runs with SHA-256
  provenance.
- `Counterweave.Processes` isolates solvers and adapters, captures bounded
  output, enforces deadlines, and terminates the child process tree where the
  GNAT runtime supports it.
- `Counterweave.JSON` validates complete JSON grammar and provides scoped,
  typed access to artifact and pack-owned values.
- `Counterweave.Terminal_UI` uses Flyology TUI only when standard input and
  output are terminals; the core remains independent of presentation.
- `Counterweave.Campaign_UI` drives one bounded trial per TUI command, renders
  progress after every result, and keeps the terminal responsive to bounded
  cancellation while the solver or adapter is active.
- `Counterweave.Terminal_Reports` renders the final verdict and replay data
  into the normal terminal with Flyology TUI components; redirected execution
  retains the stable line-oriented report.
- `counterweave_main.adb` is the Ada CLI composition root.

The implementation is one Alire crate and one GPR project. There is no Rust or
foreign-language runtime in the engine.

## Choice forks and replay

A fork is built from named and indexed path components. Its derivation input
uses explicit component lengths, so different path structures cannot collapse
through delimiter ambiguity. Each fork evolves independently under the pinned
`splitmix64-v1` algorithm.

The choice tape records the root seed, algorithm identifier, canonical fork
path, injective encoded fork key, and each consumed raw 64-bit value. It can be
decoded in a later process. Replay reads those values rather than re-running
the PRNG. It fails on unsupported formats or algorithms, duplicate forks,
missing or exhausted values, or unused values at completion.

## Generation

Random choices select semantic model parameters before solving. Counterweave
writes those values as MiniZinc data and requests one satisfying assignment.
The generated case contains:

- pack identity and intent;
- complete recorded choices;
- MiniZinc and backend identity;
- SHA-256 of the model entry point;
- SHA-256 of the solver-specific flattened model/data instance;
- SHA-256 of optional caller-supplied base data;
- the effective backend seed, when supported;
- the selected parameters;
- the completed solution.

The materialized `.cwcase` is authoritative for execution replay. Regeneration
also requires the model and its includes, the same MiniZinc/backend behavior,
and the recorded tape. The flattened-instance hash covers the effective include
and data closure seen by that solver. A future pack manifest can additionally
name and hash individual source files for source-level diagnostics.

## Search campaigns

`counterweave search` derives every trial seed from the campaign root seed and
an indexed `campaign/trial` fork. Each trial then records its own choice tape in
its `.cwcase`, invokes MiniZinc once, executes the resulting steps once, and
classifies the adapter result. Passing trials continue until the bound; the
first semantic adapter failure retains the exact case/run pair and ends the
search. Solver, protocol, timeout, output-limit, and cancellation outcomes stop
as infrastructure results rather than being mislabeled as discovered bugs.

The campaign UI is incremental rather than a long opaque action. A Flyology
TUI command executes one complete trial, its application message updates the
dashboard, and the next indexed command is scheduled only after that update.
Non-terminal execution follows the same order and emits one stable line per
trial.

## Ada adapter boundary

An adapter is an Ada executable built against the exact code under test. It
receives `--case PATH`, validates its pack version, initializes a fresh bounded
test instance, iterates the pack-owned generated steps, translates each abstract
action into public calls, captures its return or exception, and emits one
canonical JSON observation. The adapter is deterministic: all exploratory
choices and generated values are already present in the case.

Process isolation is deliberate: systems under test may crash, hang, leak task
state, or corrupt their own instance. Persistent workers require an explicit
and verified reset protocol and are outside the initial implementation.

The stale-handle example keeps the oracle narrow. MiniZinc emits operation,
logical-handle, value, and expected-outcome arrays. The adapter interprets all
steps, records the actual handles and per-step outcomes, and reports whether the
stale read was accepted. Its failed exit makes the mismatch visible to scripts,
while the complete trace remains in the `.cwrun` evidence.

## Limits and next steps

The current engine intentionally lacks a universal operation language. Payloads
remain model-pack-owned until several independent packs establish a useful
common shape.

The next steps are:

1. add a pack manifest and adapter handshake;
2. hash complete MiniZinc include closures;
3. separate general oracle verdicts from adapter process outcomes;
4. add stable failure fingerprints;
5. add model-aware reduction that preserves both validity and fingerprint;
6. add time-budgeted stopping and corpus promotion to bounded campaigns;
7. build the first Flyology allocator refinement pack.
