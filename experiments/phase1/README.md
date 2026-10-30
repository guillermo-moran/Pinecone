# Phase 1 Controlled Attribution

Status: preparation assigned; no new measured results yet.

This directory contains offline experiment tooling, not runtime optimizations.
Follow `roadmap.md` and `docs/phase1-review.md`. Existing runtime edits belong to
earlier work and must remain untouched. Do not install diagnostic binaries or
change executor defaults, guest images or Simulator state.

## Ownership

- Boundary owner: `prepare_boundaries.py` and `boundaries.md`.
- Cost-control owner: `prepare_cost_controls.py` and `cost-controls.md`.
- Measurement owner: runner, fixture/ledger tooling, manifests and results.
- Independent reviewer: `review.md`; no runtime edits or timed execution.
- Parent: this work order, final evidence review and roadmap status.

Only the measurement owner may compile or execute benchmarks. Preparation and
review work is read-only inspection or tooling authoring, so it cannot create
competing build/benchmark load. The measurement owner may run a focused baseline
first, then controls serially once preparation and review are ready.

## Preparation Interface

Both preparation modules export `variants()` and `prepare(snapshot, variant)`.
`variants()` returns a list of dictionaries containing `id`, `description`,
`hypothesis`, `safety_limits` and `changed_factors`. `prepare` receives a pathlib
Path to a disposable source root and an advertised variant ID, applies bounded
source transformations there, and returns a JSON-serializable change summary.

Require `.pinecone-phase1-snapshot` at the snapshot root, reject the real
repository root, and reject unexpected source patterns/counts. Never weaken
checks in repository runtime files. The runner owns creating each snapshot and
retaining source hashes/diffs before and after preparation. A control is not a
production correctness proof even if it produces the expected synthetic result.

Boundary variants isolate invocation limits and established superblock use;
do not combine a budget sweep with removal of per-instruction validation.
Cost controls isolate validation and statistics at a fixed invocation policy;
an omission control is legal only in the immutable, single-thread offline
fixture. Never present its timing as a safe full-system implementation.

## Measurement Requirements

1. Record compiler/options, source and executable hashes, source overrides,
   environment flags, host and relevant process load. Preserve all controls.
2. Collect an untimed event ledger separately from timing runs. Distinguish
   executor entries, superblocks, hot memory access, slow exits and checkpoints.
3. Assert matching expected architectural state, completed steps and memory.
   Record any state field that cannot be compared; do not conceal differences.
4. Separate preparation/cold and prewarmed execution. Any warmup reset must
   preserve valid cache/memory metadata and occur outside the timed region.
5. Run at least nine alternating samples per accepted control arm, serialize
   workloads, keep all failures and report medians/spread and changes in the gap.
6. Do not silently time alongside a running test VM. If one is active, coordinate
   with the parent before stopping it; never terminate unrelated user processes.
7. No timing until independent review accepts the experimental contrast and
   exclusions. Unmodified baseline reproduction can precede that review.

## Completion

The reviewer must distinguish source/static facts from measured attribution.
Deliver raw artifacts plus a ranked recommendation, rejected hypotheses and
remaining uncertainties. Keep Phase 1 open if evidence is incomplete; assembly
implementation and production invocation changes remain later roadmap work.
