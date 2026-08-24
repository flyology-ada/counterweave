# Counterweave product

## Register

product

## Users

Counterweave serves systems programmers and verification-minded test authors
working in a terminal. They need to understand how a constraint-valid model
scenario became concrete Ada calls, where the implementation first diverged
from the model, and whether shrinking preserved the same failure.

## Product Purpose

Counterweave generates system-valid scenarios from replayable choices and a
constraint model, executes them against code under test, and retains evidence
that explains and reproduces a property violation. Success means a user can
move from discovery to a smaller counterexample without mentally joining raw
model, case, run, and reduction JSON.

## Brand Personality

Precise, composed, and investigative. The interface should feel like an expert
debugging instrument: dense enough to answer the next question, restrained
enough that the failure path remains dominant.

## Anti-references

Do not resemble a generic metrics dashboard, a decorative terminal animation,
or a raw JSON viewer with color added. Progress counters must not displace the
counterexample, and model-specific concepts must not leak into Counterweave's
core interface.

## Design Principles

- Lead with the counterexample path, not campaign machinery.
- Align model expectations and system observations at every transition.
- Identify the first divergence separately from the final property violation.
- Keep shrink provenance visible through original and current-best summaries.
- Make fresh exploration the default, while exposing the recorded campaign and
  trial seeds needed to understand or repeat a run.
- Preserve expert detail through progressive disclosure and durable artifacts.

## Accessibility & Inclusion

Never communicate match, divergence, or violation through color alone. Retain
text markers and labels under monochrome and reduced-color terminals. Support
narrow terminal layouts, avoid decorative motion, and keep redirected output
stable and machine-readable.
