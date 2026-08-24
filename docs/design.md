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
                                                       +-> violation -> retain pair
                         |
                         +-> .cwcampaign -> verified replay
                                           |
                                           +-> regenerate + reduce -> .cwreduction
```

- `Counterweave.Choices` owns structurally independent replay streams and the
  recorded choice tape.
- `Counterweave.Adapter_Results` validates the versioned semantic result,
  model-pack handshake, property, and stable failure fingerprint independently
  of process exit status.
- `Counterweave.MiniZinc` asks for one completion under a bounded deadline and
  records the seed actually supplied to supported solvers.
- `Counterweave.Artifacts` writes versioned JSON cases and runs with SHA-256
  provenance.
- `Counterweave.Campaigns` persists every trial and reconstructs a campaign
  only after checking model, data, and adapter provenance. It verifies semantic
  case identity after replay.
- `Counterweave.Choices.Shrink` mutates the recorded fork forest through a
  deterministic strategy portfolio. `Counterweave.Reduction_Engine` replays
  each candidate through MiniZinc and the adapter, accepting it only when the
  same property and fingerprint remain.
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

`counterweave.choices/2` also records `upper-rejection-v1`, the bounded-choice
codec. It preserves uniform modulo sampling while making zero and other small
raw values valid shrink targets. `counterweave.choices/1` remains decodable
with its original lower-tail rejection behavior.

## Generation

Random choices select semantic model parameters before solving. Counterweave
writes those values and a reserved `counterweave_diversity_seed` as MiniZinc
data and requests one satisfying assignment. Each pack declares the seed and
may use it in a constraint partition or objective over its typed decision
vector. Supported solvers also receive it through their backend seed option.
The generated case contains:

- pack identity and intent;
- complete recorded choices;
- MiniZinc and backend identity;
- SHA-256 of the model entry point;
- SHA-256 of the solver-specific flattened model/data instance;
- SHA-256 of optional caller-supplied base data;
- the effective backend seed, when supported;
- the recorded model-level diversity seed;
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
first semantic property violation retains the exact case/run pair and ends the
search. Solver, adapter-process, invalid-case, protocol, timeout, output-limit,
and cancellation outcomes stop as infrastructure results rather than being
mislabeled as discovered bugs.

The campaign artifact records the complete invocation, source and executable
hashes, every trial seed, semantic outcome, property, fingerprint, byte hashes,
and semantic case hashes. `replay-campaign` writes to separate paths, checks the
recorded provenance before running, and then compares those semantic fields for
every attempt. The flattened solver artifact remains diagnostic: MiniZinc can
emit byte-different FlatZinc for an equivalent materialized case.

`counterweave.campaign/3` defines semantic case identity through canonical JSON:
object members are sorted, strings are decoded and re-encoded consistently,
whitespace is removed, and exact decimal values are normalized without
floating-point conversion. This keeps equivalent pack payloads identical while
retaining array order and every semantically distinct value. Reduction reports
using that identity are `counterweave.reduction/3`; earlier artifact versions
are rejected rather than interpreted with the new hash definition.

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
versioned `counterweave.adapter-result/1` value. The adapter is deterministic: all exploratory
choices and generated values are already present in the case.

A normal adapter process exits successfully for `pass`, `property-violation`,
and `invalid-case`. Its result repeats the model-pack identity and contains the
property, a failure fingerprint for violations, and pack-owned observations.
Counterweave rejects missing fingerprints, pack mismatches, malformed JSON, and
unknown verdicts. Any nonzero adapter exit is an infrastructure error regardless
of its output. `counterweave.run/2` preserves the process and semantic layers
separately.

Process isolation is deliberate: systems under test may crash, hang, leak task
state, or corrupt their own instance. Persistent workers require an explicit
and verified reset protocol and are outside the initial implementation.

The stale-handle example keeps the property narrow. MiniZinc emits operation,
logical-handle, value, and expected-outcome arrays. The adapter interprets all
steps, records the actual handles and per-step outcomes, and reports whether the
stale read was accepted. Its semantic result makes the mismatch visible to
scripts, while the complete trace remains in the `.cwrun` evidence.

The independent idempotent-transfer pack uses a variable-length schema. Its
model generates deposits, first transfers, and valid matching retries while
maintaining every account balance and seen transaction after every step. A
recorded diversity objective changes the complete history. Its Ada adapter
executes every step against a faulty ledger and reports
`transfers-are-idempotent / duplicate-transfer-not-ignored` when a retry is
reapplied.

## Reduction

Reduction starts from the exact choice tape in a retained failing case. The
generic shrinker repeatedly tries fork-subtree and fork deletion, chunk
deletion, small and boundary values, halving, bit clearing and redistribution,
binary search, duplicate co-shrinking, lowering with dependent deletion, and
simpler ordering within one fork. Cross-fork swaps and flattening are
deliberately absent because named paths carry semantic identity.

Progress uses a fixed, well-founded tape order: fewer recorded values, then
fewer forks, then lexicographic fork paths and values. Raw values rank `0..4`
first, followed by the documented integer boundaries, then ordinary numeric
order. A boundary such as `u64::MAX` can therefore be a simpler explanatory
choice without being numerically smaller than the value it replaces.

Each candidate tape is replayed through the original draw declarations. Replay
failure makes it an invalid candidate. Successful replay is normalized to the
forks and values actually consumed, completed through MiniZinc, and executed by
the Ada adapter. A mutation is retained only when it is strictly smaller and
the original property plus failure fingerprint remain. This allows a random
choice controlling `step_count`, topology, or another structural dimension to
shrink without a pack-specific reducer while keeping every generated case
system-valid. It is not a claim of a globally minimal semantic case.

`counterweave.reduction/3` records every strategy attempt, before/candidate tape
hashes, invalid candidates separately from infrastructure errors, the original
and final tapes, and the final case and run hashes.

## Limits and next steps

The current engine intentionally lacks a universal operation language. Payloads
remain model-pack-owned until several independent packs establish a useful
common shape.

The next steps are:

1. add a pack manifest and source-closure inventory around the implemented
   adapter handshake;
2. hash complete MiniZinc include closures;
3. add time-budgeted stopping, corpus promotion, and coverage feedback to
   bounded campaigns;
4. add parallel campaigns without changing indexed trial identity;
5. add pack-owned semantic complexity objectives as an optional second phase
   after generic choice-tape shrinking;
6. build the first Flyology allocator refinement pack against production code.
