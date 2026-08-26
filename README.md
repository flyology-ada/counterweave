# Counterweave

Constraint-guided generative testing for whole systems, implemented in Ada.

Counterweave combines recorded random choices with constraint solving. Ada
chooses a testing intent and meaningful scenario parameters; MiniZinc
completes those choices into a coherent system-valid case. A separate Ada
adapter then executes the materialized case against the system under test.

Counterweave is experimental. The current implementation provides named choice
forks, exact choice replay, diversified one-solution MiniZinc completion,
versioned case, run, campaign, and reduction artifacts, an explicit semantic
adapter protocol, strict JSON decoding, bounded subprocess execution, automatic
Flyology TUI presentation on real terminals, verified campaign replay,
recorded-choice shrinking with fingerprint preservation, and two independent
Ada bug-discovery packs.

## Why constraints and randomness are separate

Ordinary value generators establish local shape. Counterweave is intended for
relationships spanning a system: ownership, generations, topology, capacity,
operation history, and deliberately rejected actions.

Randomness comes from Ada `splitmix64-v1` streams derived from a root seed and
length-delimited named fork paths. Consuming one fork does not shift a sibling.
The case records every consumed 64-bit value, not merely the seed.
Serialized tapes include the injective fork key and can be decoded into a new
Ada process for fail-closed replay.

`generate` and `search` choose a fresh root seed when `--seed` is absent. Pass
`--seed N` only when intentionally repeating an exploration. Example scripts
follow the same rule and accept `COUNTERWEAVE_SEED=N` as the reproducible
opt-in. Campaigns and choice tapes retain the selected seed and all consumed
choices for exact replay.

New tapes use a shrink-friendly bounded codec: raw values are reduced modulo
the requested range and only the tiny upper rejection tail is discarded. Thus
shrinking a recorded value toward zero normally shrinks the decoded choice
toward the range's lower bound without biasing fresh generation.

MiniZinc is the constraint-preserving completion engine, not the source of
randomness. Counterweave asks it for one satisfying completion. Every model
receives a recorded `counterweave_diversity_seed`; a pack can use it in a
partition or objective over its own decision vector. A supported backend also
receives the same seed. Neither mechanism implies uniform sampling.

## What a model-pack author writes

The user or library maintainer owns two pack-specific pieces:

1. A MiniZinc model declares the sampled integer parameters, the reserved
   `counterweave_diversity_seed`, bounded state transitions, invariants, typed
   step arrays, and modeled outcomes. Counterweave writes the sampled values as
   data and asks for one completion.
2. An Ada adapter links the exact code under test, validates its pack name and
   version, iterates every materialized step, compares actual returns or
   exceptions with the modeled outcomes through Flyology TLA+'s replay
   adapter, and emits `counterweave.adapter-result/2`. The result nests a
   strict `flyology.tla.result/1` verdict and its canonical
   `flyology.tla.trace/2`, aligning each generated action with the model
   expectation and originating model symbols. Pack-owned observations remain
   diagnostic because result/1 does not retain observed outcome/state values.

Counterweave owns choice derivation, MiniZinc execution, process isolation,
classification, artifacts, campaign replay, reduction, and terminal UI. A new
pack may use a completely different payload schema; the two checked-in packs do
so without special dispatch in the engine.

## Prerequisites

- Alire 2.1 or later;
- GNAT 13 through 16;
- MiniZinc for case generation;
- the CP-SAT MiniZinc backend for the default examples, or another backend
  selected with `--solver`.

Add Flyology's Alire index before resolving the exact development dependencies
on `flyology_tla` and `flyology_tui`:

```sh
alr index --add=git+https://github.com/flyology-ada/alire-index.git --name=flyology
```

Build and run the Ada test suite:

```sh
alr -n build
alr -n test
```

The executables are written to `bin/`:

- `counterweave` — generation, inspection, and execution CLI;
- `counterweave_tests` — Ada unit/integration tests;
- `stale_handle_adapter` — the generational-handle example adapter;
- `idempotent_transfer_adapter` — the variable-history ledger adapter.

## Run the Ada bug-discovery example

The complete example is one command:

```sh
examples/ada_stale_handle/run.sh
```

If CP-SAT is unavailable but MiniZinc has Gecode:

```sh
COUNTERWEAVE_SOLVER=gecode examples/ada_stale_handle/run.sh
```

The example searches bounded generational-handle-pool histories from a fresh
campaign seed, then runs a 256-candidate reduction campaign. The Flyology TUI
shows native rounded panels and high-color progress for both phases, including
the campaign seed, derived trial seed, property result, reduction strategy,
accepted count, and current choice-tape size. Reduction completion remains in
the full-terminal TUI so the entire causal path and evidence stay visible;
Enter, Escape, or `q` restores the shell. To repeat the documented campaign
that finds the violation on trial 14, run:

```sh
COUNTERWEAVE_SEED=42 examples/ada_stale_handle/run.sh
```

MiniZinc materializes explicit operation, handle, value, and expected-outcome
arrays for valid histories between 9 and 21 steps. A recorded `history_shape`
adds model-valid reads and writes while the first handle is live. The causal
core is:

1. allocate `h1` at generation 1 and release it;
2. allocate and release `h2` at generation 2;
3. allocate and release `h3` at generation 3;
4. allocate `h4`, which the model requires to use generation 4;
5. write the replacement value through `h4`;
6. read either current `h4` or, in scenario 23, stale `h1`.

The deliberately buggy Ada pool represents the effect of an undersized packed
generation field: after generation 3 it wraps to 1. Most generated histories
probe `h4` and pass. Scenario 23 probes the much older `h1`, which now aliases
the replacement and returns its value instead of raising `Stale_Handle`.

The Ada adapter iterates every generated step and compares modeled outcomes
with actual returns or exceptions. For seed 42, search finds a 13-step failure
on trial 14. Generic recorded-choice reduction changes `history_shape` from 81
to 0, regenerating a system-valid 9-step path; it also changes capacity from 4
to 1 and the replacement value from 139 to 101. The reduction therefore shows
both input minimization and path shortening while preserving
`stale-read-accepted`. The bounded example records `attempt-limit` after 256
candidates because the remaining raw scenario bits still decode to scenario
23. Counterweave records the final evidence in
`/tmp/counterweave-stale-handle.cwreduction`. Set
`COUNTERWEAVE_OUTPUT_DIR` to retain the example artifacts elsewhere.

The important evidence looks like this:

```json
{
  "outcome": "property-violation",
  "process": {"outcome": "completed"},
  "adapter_result": {
    "property": "released-handles-stay-stale",
    "fingerprint": "stale-read-accepted",
    "conformance": {
      "format": "flyology.tla.result/1",
      "verdict": "diverged",
      "trace_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "compared_steps": 9,
      "failure": {
        "step": 9,
        "property": "released-handles-stay-stale",
        "fingerprint": "stale-read-accepted",
        "detail": "a released handle read the replacement value"
      }
    },
    "observations": {
      "scenario": 23,
      "observed_value": 101,
      "old_generation": 1,
      "new_generation": 1
    }
  }
}
```

That is a generated system-valid history exposing a real semantic mismatch,
not merely a randomly generated integer that caused a crash.

## Run the variable-history Ada example

The independent ledger pack exercises a different payload and state machine:

```sh
examples/ada_idempotent_transfer/run.sh
```

MiniZinc chooses a variable-length history of deposits and transfers. It tracks
every account balance and transaction id after every step, permits a retry only
when its source, destination, and amount match the original request, and models
that retry as a no-op. A diversity objective over the complete decision vector
changes the satisfying history from the recorded diversity seed; there is no
scenario number that selects a handwritten reproduction.

The Ada adapter iterates the generated history against a deliberately faulty
ledger that reapplies a seen transaction. Counterweave reports the stable
failure identity:

```text
transfers-are-idempotent / duplicate-transfer-not-ignored
```

The retained example can be reduced through the same constraint model:

```sh
bin/counterweave reduce \
  --campaign /tmp/counterweave-idempotent-transfer.cwcampaign \
  --case-output /tmp/transfer-reduced.cwcase \
  --run-output /tmp/transfer-reduced.cwrun \
  --report-output /tmp/transfer-reduced.cwreduction \
  --max-attempts 1000
```

For the checked-in seed, reduction changes the generated history from 11 steps
to 5 and reduces its balance and amount bounds. Counterweave mutates the
recorded choice tape with structural and value strategies, replays generation,
and normalizes the candidate to the choices actually consumed. Duplicate raw
values receive the complete integer strategy portfolio together, and boundary
probes can only move toward a numerically smaller tape. Each candidate
is completed by MiniZinc, executed again, and retained only if the property and
fingerprint are unchanged.

## Run a search manually

Search up to 64 independently seeded, constraint-valid cases and retain the
first counterexample:

```sh
bin/counterweave search \
  --model examples/ada_stale_handle/model.mzn \
  --adapter bin/stale_handle_adapter \
  --draw capacity=1..4 \
  --draw old_value=10..100 \
  --draw new_value=101..200 \
  --draw scenario=0..31 \
  --trials 64 \
  --pack ada-stale-handle \
  --intent explore \
  --target released-handles-stay-stale \
  --case-output /tmp/stale.cwcase \
  --run-output /tmp/stale.cwrun \
  --campaign-output /tmp/stale.cwcampaign
```

This command chooses a fresh campaign seed. Add `--seed 42` to repeat that
specific campaign. The report distinguishes the campaign root seed from the
derived seed of the failing trial.

Inspect the complete materialized case:

```sh
bin/counterweave inspect /tmp/stale.cwcase
```

Replay the retained case against the Ada adapter without invoking MiniZinc:

```sh
bin/counterweave execute \
  --case /tmp/stale.cwcase \
  --adapter bin/stale_handle_adapter \
  --output /tmp/stale.cwrun
```

The replay command returns a failure status because the retained case exposes
the bug. The `.cwrun` remains durable evidence. Search derives each trial seed
from an indexed campaign fork rooted at the fresh or explicitly supplied
campaign seed; adding work inside one generated case does not shift the seeds
of its sibling trials.

Replay the complete campaign into different output paths:

```sh
bin/counterweave replay-campaign \
  --campaign /tmp/stale.cwcampaign \
  --case-output /tmp/stale-replayed.cwcase \
  --run-output /tmp/stale-replayed.cwrun \
  --campaign-output /tmp/stale-replayed.cwcampaign
```

Before replay, Counterweave checks the recorded model, data, and adapter hashes.
Afterward it compares every trial seed, semantic outcome, property, fingerprint,
and semantic case hash. The semantic hash canonicalizes object order, JSON
whitespace, string escapes, and exact decimal spelling. The flattened MiniZinc
hash remains diagnostic because equivalent flattening runs can differ
byte-for-byte while producing the same materialized case.

## Ada adapter protocol

Counterweave starts each adapter in a separate process with:

```text
adapter --case /absolute/or/relative/path.cwcase
```

On normal completion, the adapter exits successfully and writes one versioned
result to standard output:

```json
{
  "format": "counterweave.adapter-result/2",
  "pack": {"name": "ada-idempotent-transfer", "version": "1"},
  "verdict": "property-violation",
  "property": "transfers-are-idempotent",
  "fingerprint": "duplicate-transfer-not-ignored",
  "observations": {},
  "conformance": {
    "format": "flyology.tla.result/1",
    "verdict": "diverged",
    "trace_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "compared_steps": 2,
    "failure": {
      "step": 2,
      "property": "transfers-are-idempotent",
      "fingerprint": "duplicate-transfer-not-ignored",
      "detail": "a duplicate transfer changed the balances"
    }
  },
  "trace": {
    "format": "flyology.tla.trace/2",
    "model": {
      "module": "TransferLedger",
      "configuration": "ada-idempotent-transfer/1",
      "source_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "configuration_sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      "toolchain": "minizinc 2.9.7; solver cp-sat"
    },
    "initial": {"state": {"balances": [40, 40]}},
    "steps": [
      {
        "index": 1,
        "action": "TransferLedger!Transfer",
        "role": "first-transfer",
        "input": {"transaction": 1, "source": 1, "destination": 2, "amount": 14},
        "expected": {
          "outcome": {"status": "applied"},
          "state": {"balances": [26, 54]}
        },
        "model_source": "TransferLedger!Transfer"
      },
      {
        "index": 2,
        "action": "TransferLedger!Transfer",
        "role": "duplicate-transfer-retry",
        "input": {"transaction": 1, "source": 1, "destination": 2, "amount": 14},
        "expected": {
          "outcome": {"status": "ignored"},
          "state": {"balances": [26, 54]}
        },
        "model_source": "TransferLedger!Transfer"
      }
    ]
  }
}
```

Verdicts are `pass`, `property-violation`, or `invalid-case`. A violation must
have a nonempty stable fingerprint; the other verdicts use `null`. Pack identity
must match the case. A nonzero adapter exit is always an infrastructure error,
even if the process printed plausible JSON, so a crash cannot be reported as a
bug. `counterweave execute` itself returns unsuccessfully for a semantic
violation so shell scripts can stop, while `counterweave.run/3` preserves the
successful adapter process outcome separately from the semantic verdict.

The shared trace is the replay input, not a second verdict. A dynamic Flyology
TLA+ adapter projects each MiniZinc-authored step into a deterministic semantic
input, executes the real Ada operation, and compares the modeled and observed
outcome and state. The shared replay result supplies the compared-step count,
failure step, property, stable fingerprint, and detail. Counterweave validates
that result strictly and binds it to the exact trace SHA-256 before accepting
the pack's outer verdict.

The checked-in packs use Flyology TLA+'s dynamic adapter because MiniZinc, not
SANY, owns their typed step schemas. `source_sha256` is the Counterweave model
SHA-256 and `configuration_sha256` is the generated data SHA-256. The complete
canonical trace remains in the run artifact. The terminal view uses the shared
failure step to show one establishing transition before the divergence and all
transitions through the failed property. Shrink retention continues to use the
same property and failure fingerprint.

Counterweave captures standard output and error into the run artifact and keeps
completed, adapter-error, timeout, cancellation, output-limit, spawn, and
protocol outcomes distinct. JSON is parsed structurally; malformed documents,
duplicate members, unknown artifact versions, mismatched packs, and data outside
the one result fail closed. The deadline covers the child process; GNAT's
process-tree termination is used where supported.

A Flyology adapter should be an Ada test executable linked against the exact
Flyology library and runtime under examination. It decodes its pack payload,
calls public operations, and emits narrow semantic observations. Flyology-
specific models and adapters should live with Flyology; the generic engine
stays here.

## Durable artifacts

- `counterweave.case/3` contains the opaque pack parameters and solution,
  complete choice tape, recorded diversity seed, and solver provenance.
- `counterweave.run/3` separates subprocess outcome from the parsed adapter
  result, retains the bound `flyology.tla.result/1` and
  `flyology.tla.trace/2`, and binds them to case and adapter hashes.
- `counterweave.campaign/3` records the complete search configuration and every
  trial seed, outcome, property, fingerprint, and canonical semantic case hash.
- `counterweave.reduction/4` records every choice-tape mutation, strategy,
  outcome, normalized final tape, parameters, case, run, property,
  fingerprint, and the original and final replay results and traces.

Exact execution replay needs only a case and adapter. Campaign replay invokes
the model again and therefore verifies semantic case identity rather than
requiring the solver-specific flattened bytes to be identical.

## Terminal presentation

`generate`, `execute`, `search`, and `reduce` use `flyology_tui` automatically
when both standard input and standard output are real terminals and `TERM` is
usable.
Search uses Flyology TUI progress, indicator, help, and layout components as a
persistent campaign dashboard. Reduction has its own rounded panel with a
high-color candidate-budget bar, accepted-mutation count, current tape size,
and last strategy. Shrink activity is kept above the counterexample, while a
non-sortable Flyology TUI table preserves the causal transition order and
shows the modeled outcome and state through the shared failure step. Setup calls
outside that failure path stay in the durable trace instead of crowding the live
view. Text markers do not rely on color: `✓` identifies steps compared before
the divergence and `✕` identifies the shared result's failure step. The
pack-owned observations remain diagnostic evidence; they cannot replace or
contradict the shared verdict, property, or fingerprint. Search leaves a
bounded styled report in the normal terminal.
Reduction keeps its trace-first completed view in the full-terminal TUI until
Enter, Escape, `q`, or Ctrl-C restores the shell. Redirected commands, CI, and
pipelines retain stable plain output. The TUI is only a
presentation layer: choices, solver inputs, adapter arguments, exit status,
and artifacts are identical in either mode. Press `q` or Ctrl-C to cancel the
active solver or adapter; cancellation is recorded separately from a timeout.

Case provenance records the source model hash, complete generated-data hash,
recorded diversity seed, and a hash of the solver-specific flattened instance. Run
provenance records the Counterweave version, adapter executable hash, and
complete effective argument list. Campaign and reduction artifacts retain the
evidence chain above them.

See [`docs/design.md`](docs/design.md) for architecture and limitations.

## Agent setup

Counterweave retains Flyology's APM-managed agent workflow:

```sh
pip install apm-cli==0.28.0
apm install --frozen
apm compile --target codex
apm audit --ci
```

The generated `AGENTS.md` and `apm.lock.yaml` are committed. Generated local
rules and skills remain ignored.

## License

Counterweave is distributed under either the Apache License 2.0 or MIT License,
at your option.
