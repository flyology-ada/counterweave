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
fingerprint-preserving reduction, and two independent Ada bug-discovery packs.

## Why constraints and randomness are separate

Ordinary value generators establish local shape. Counterweave is intended for
relationships spanning a system: ownership, generations, topology, capacity,
operation history, and deliberately rejected actions.

Randomness comes from Ada `splitmix64-v1` streams derived from a root seed and
length-delimited named fork paths. Consuming one fork does not shift a sibling.
The case records every consumed 64-bit value, not merely the seed.
Serialized tapes include the injective fork key and can be decoded into a new
Ada process for fail-closed replay.

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
   exceptions with the modeled outcomes, and emits
   `counterweave.adapter-result/1`.

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

Add Flyology's Alire index before resolving the `flyology_tui` dependency:

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

The example searches bounded generational-handle-pool histories. With campaign
seed 42, it explores 13 passing constraint-valid cases and finds the violation
on trial 14. The Flyology TUI stays active across the campaign and shows the
attempt budget, replay seed, progress, and last property result.

MiniZinc materializes explicit operation, handle, value, and expected-outcome
arrays for each valid eight-step history:

1. allocate an old handle;
2. write its value;
3. read it while it is live;
4. release it;
5. allocate a new handle in the same slot;
6. write a different value;
7. read either the current handle or, in one sampled scenario, the released
   handle;
8. release the current handle.

The model requires the reused slot's generation to advance, so a stale-probe
read must be rejected. The deliberately buggy Ada pool forgets that increment.
The old handle aliases the new allocation and reads its value. The Ada adapter
iterates the generated arrays, dispatches every operation, and compares each
return or exception with its modeled outcome. It emits canonical evidence and
reports a semantic violation; Counterweave records the failure in
`/tmp/counterweave-stale-handle.cwrun`. Set `COUNTERWEAVE_OUTPUT_DIR` to
retain the example artifacts elsewhere.

The important evidence looks like this:

```json
{
  "outcome": "property-violation",
  "process": {"outcome": "completed"},
  "adapter_result": {
    "property": "released-handles-stay-stale",
    "fingerprint": "stale-read-accepted",
    "observations": {
      "scenario": 23,
      "expected_stale": true,
      "stale_read_accepted": true,
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
  --report-output /tmp/transfer-reduced.cwreduction
```

For the checked-in seed, reduction changes the generated history from 11 steps
to 5 and reduces its balance and amount bounds. Each candidate is solved again,
executed again, and retained only if the property and fingerprint are unchanged.

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
  --seed 42 \
  --trials 64 \
  --pack ada-stale-handle \
  --intent explore \
  --target released-handles-stay-stale \
  --case-output /tmp/stale.cwcase \
  --run-output /tmp/stale.cwrun \
  --campaign-output /tmp/stale.cwcampaign
```

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
from an indexed campaign fork; adding work inside one generated case does not
shift the seeds of its sibling trials.

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
  "format": "counterweave.adapter-result/1",
  "pack": {"name": "ada-idempotent-transfer", "version": "1"},
  "verdict": "property-violation",
  "property": "transfers-are-idempotent",
  "fingerprint": "duplicate-transfer-not-ignored",
  "observations": {}
}
```

Verdicts are `pass`, `property-violation`, or `invalid-case`. A violation must
have a nonempty stable fingerprint; the other verdicts use `null`. Pack identity
must match the case. A nonzero adapter exit is always an infrastructure error,
even if the process printed plausible JSON, so a crash cannot be reported as a
bug. `counterweave execute` itself returns unsuccessfully for a semantic
violation so shell scripts can stop, while `counterweave.run/2` preserves the
successful adapter process outcome separately from the semantic verdict.

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

- `counterweave.case/2` contains the opaque pack parameters and solution,
  complete choice tape, recorded diversity seed, and solver provenance.
- `counterweave.run/2` separates subprocess outcome from the parsed adapter
  result and binds both to case and adapter hashes.
- `counterweave.campaign/2` records the complete search configuration and every
  trial seed, outcome, property, fingerprint, and canonical semantic case hash.
- `counterweave.reduction/2` records every candidate and the final reduced
  parameters, case, run, property, and fingerprint.

Exact execution replay needs only a case and adapter. Campaign replay invokes
the model again and therefore verifies semantic case identity rather than
requiring the solver-specific flattened bytes to be identical.

## Terminal presentation

`generate`, `execute`, `search`, and `reduce` use `flyology_tui` automatically
when both standard input and standard output are real terminals and `TERM` is
usable.
Search uses Flyology TUI progress, indicator, help, and layout components as a
persistent campaign dashboard. When search ends, a styled report remains in
the normal terminal with its verdict, trial count, replay seed, evidence paths,
and a copyable replay command. Redirected commands, CI, and pipelines retain
stable plain output. The TUI is only a presentation layer: choices, solver
inputs, adapter arguments, exit status, and artifacts are identical in either
mode. Press `q` or Ctrl-C to cancel the active solver or adapter; cancellation
is recorded separately from a timeout.

Case provenance records the source model hash, optional base-data hash, recorded
diversity seed, and a hash of the solver-specific flattened instance. Run
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
