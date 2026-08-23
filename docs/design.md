# Counterweave design

## Contract

Given a named intent and replayable choices, Counterweave materializes a
bounded scenario satisfying a constraint model, executes it through a
versioned adapter, and preserves the evidence needed to reproduce an observed
failure. Later versions will judge observations through independent oracles
and reduce counterexamples while preserving a stable failure fingerprint.

Counterweave does not claim uniform solution sampling, exhaustive exploration,
proof beyond a model's checked bounds, or deterministic control over
uninstrumented native and kernel scheduling.

## Pipeline

```text
Intent -> Generator -> Case -> Executor -> Run -> Oracle -> Verdict
                         ^                          |
                         +------ Reducer <---------+
```

The current implementation covers choices, MiniZinc generation, cases,
execution, and runs. Oracle, verdict, campaign, corpus, and reducer interfaces
remain planned rather than implied by placeholder abstractions.

### Intent and choices

An intent identifies what kind of scenario to seek, for example:

- `satisfy:default`;
- `reach:coalesce-before-success`;
- `reject:stale-generation`;
- `violate:capacity`;
- `distinguish:native-lightweight`.

Choice forks select semantic parameters, feature families, solver-diversity
inputs, faults, and controlled execution decisions. Each fork is named and
indexed. Its stream is derived from the root seed and complete path, rather
than from the amount of entropy consumed by earlier siblings.

A choice tape records every consumed value. Replay fails closed if a fork is
missing, duplicated, exhausted, left partially consumed, or encoded with an
unknown format.

### Generator

The initial generator invokes MiniZinc for one satisfying assignment. Model
packs should distinguish:

- structural assumptions that always hold;
- state invariants;
- valid before/action/after transitions;
- named target states or histories;
- expected canonical observations.

Random semantic parameters are drawn before solving and supplied as MiniZinc
data. Solver seeds and later randomized objectives or hash partitions may
increase diversity, but are not uniform samplers.

### Case

`counterweave.case/1` contains a generic envelope and an opaque model-pack
payload. The envelope identifies the pack, intent, choice tape, model digest,
MiniZinc version, solver, and solver seed. The payload currently contains the
completed parameters and MiniZinc solution.

The materialized case is authoritative for execution replay. Adapter execution
must not require the model or solver.

### Executor and run

The executor writes one complete case to an adapter's standard input. The
adapter writes one canonical JSON observation to standard output. Counterweave
captures standard error and classifies completion, nonzero exit, timeout, and
protocol error into `counterweave.run/1`.

Process isolation is the default because systems under test may crash, hang,
leak task state, or deliberately corrupt their own test instance. Persistent
adapter processes may be considered only for packs that define and verify a
complete reset boundary.

### Oracle

An oracle should remain independent of mechanical adapter dispatch. Planned
forms include model-predicted observations, a separate reference model,
differential execution, metamorphic relations, invariant snapshots, and
linearizability checking. A verdict needs a stable property identifier and
failure fingerprint rather than relying on diagnostic prose.

### Reduction

Generic JSON shrinking can destroy system validity, while replaying a smaller
seed may generate an unrelated completion. A model pack will therefore define
a semantic complexity vector and a strict reduction relation. Counterweave
will generate simpler admissible candidates, execute them, and retain only
candidates with the same failure fingerprint.

Generation and execution choices are reduced separately: generation choices
change the materialized world; execution choices simplify schedules, delays,
and injected faults for the same world.

## Ada adapter boundary

An Ada adapter is a test executable built against the exact code and runtime
under test. It should:

1. decode the case and validate the pack compatibility version;
2. initialize a fresh bounded test instance;
3. translate abstract actions into public Ada calls;
4. capture results, exceptions, and narrow canonical snapshots;
5. clean up and emit one observation document.

Black-box packs need only public APIs. Refinement packs may use test-only child
packages that expose semantic state without widening the production API.
Fault-enabled runtime variants must preserve Flyology's compile-time hook
elision contract.

Controlled concurrency scenarios may use ordinary Ada protected objects as
application checkpoints. Natural-scheduling mode repeats an unchanged case
without enforcing a full order. Neither mode claims control of uninstrumented
kernel events.

## Repository ownership

The generic engine belongs in `flyology-ada/counterweave`. Flyology-specific
models, adapters, oracles, and permanent regression cases should live in the
Flyology repository so they evolve with the implementation they describe.

The first engineering model pack should exercise allocator refinement because
Flyology already has deterministic traces and canonical Ada/TLA+ snapshots.
The first product-level demonstration should then exercise supervision or
completion gates, where topology, generations, lifetimes, thresholds, and
temporal constraints show the advantage of system-wide synthesis.

## Near-term sequence

1. Finish the stable choice, case, and run formats with compatibility tests.
2. Add a pack manifest and explicit adapter handshake.
3. Build the Flyology allocator model and Ada adapter.
4. Introduce oracle verdicts and failure fingerprints.
5. Add model-aware reduction.
6. Add time-budgeted campaigns and corpus promotion.

Additional solver backends, direct Rust/Ada FFI, distributed execution, a web
interface, and general deterministic scheduling are intentionally outside the
initial scope.
