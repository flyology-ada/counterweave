# Counterweave

Constraint-guided generative testing for whole systems, implemented in Ada.

Counterweave combines recorded random choices with constraint solving. Ada
chooses a testing intent and meaningful scenario parameters; MiniZinc
completes those choices into a coherent system-valid case. A separate Ada
adapter then executes the materialized case against the system under test.

Counterweave is experimental. The current vertical slice provides named choice
forks, exact choice replay, one-solution MiniZinc completion, versioned case and
run artifacts, strict JSON decoding, bounded subprocess execution, automatic
Flyology TUI presentation on real terminals, bounded replayable search
campaigns, and an Ada bug-discovery example. Model-aware reduction and a
general oracle protocol remain planned.

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
randomness. Counterweave asks it for one satisfying completion. A supported
backend seed adds diversity but does not imply uniform sampling.

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
- `stale_handle_adapter` — the example Ada system adapter.

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
attempt budget, replay seed, progress, and last oracle result.

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
exits unsuccessfully; Counterweave records the failure in
`/tmp/counterweave-stale-handle.cwrun`. Set `COUNTERWEAVE_OUTPUT_DIR` to
retain the example artifacts elsewhere.

The important evidence looks like this:

```json
{
  "property": "released-handles-stay-stale",
  "steps": [
    {"index": 1, "operation": "allocate", "status": "ok"},
    {"index": 7, "operation": "read", "status": "ok", "value": 139}
  ],
  "scenario": 23,
  "expected_stale": true,
  "stale_read_accepted": true,
  "old_generation": 1,
  "new_generation": 1
}
```

That is a generated system-valid history exposing a real semantic mismatch,
not merely a randomly generated integer that caused a crash.

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
  --run-output /tmp/stale.cwrun
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

## Ada adapter protocol

Counterweave starts each adapter in a separate process with:

```text
adapter --case /absolute/or/relative/path.cwcase
```

The adapter writes one JSON observation value to standard output. Counterweave
captures standard output and error into a versioned run artifact and classifies
success, failure, timeout, output-limit, spawn, and protocol failure separately.
JSON is parsed structurally; malformed documents, duplicate members, unknown
artifact versions, and data outside the one observation value fail closed. The
deadline covers the child process; GNAT's process-tree termination is used
where supported.

A Flyology adapter should be an Ada test executable linked against the exact
Flyology library and runtime under examination. It decodes its pack payload,
calls public operations, and emits narrow semantic observations. Flyology-
specific models and adapters should live with Flyology; the generic engine
stays here.

## Terminal presentation

`generate`, `execute`, and `search` use `flyology_tui` automatically when both
standard input and standard output are real terminals and `TERM` is usable.
Search uses Flyology TUI progress, indicator, help, and layout components as a
persistent campaign dashboard. When search ends, a styled report remains in
the normal terminal with its verdict, trial count, replay seed, evidence paths,
and a copyable replay command. Redirected commands, CI, and pipelines retain
stable plain output. The TUI is only a presentation layer: choices, solver
inputs, adapter arguments, exit status, and artifacts are identical in either
mode. Press `q` or Ctrl-C to cancel the active solver or adapter; cancellation
is recorded separately from a timeout.

Case provenance records the source model hash, optional base-data hash, and a
hash of the solver-specific flattened instance. Run provenance records the
Counterweave version, adapter executable hash, and complete effective argument
list.

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
