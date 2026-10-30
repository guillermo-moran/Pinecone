# Phase 1 Controlled Attribution Results

Follow-up: the subsequent fresh cohort completed. See
[clean cohort results](phase1-clean-cohort-results.md) for measured attribution.
This document preserves the earlier aborted cohort and must not be interpreted
as its samples becoming eligible retroactively.

Status: exact-artifact review and final untimed verification passed; timed
attribution **blocked by host load**. The incomplete cohort is excluded.
Phase 1 remains open; there is no defensible measured ranking from this attempt.
Measurement owner: Hypatia. Independent reviewer: Maxwell. Native-only, offline
diagnostics; no runtime implementation or promotion is authorized.

## Frozen Evidence

Final run: `experiments/phase1/results/20261029T044919Z/`.
The UTC date is October 29; the host's America/Chicago local date is October 28.
`manifest.json` records the dirty checkout, compiler, SDK, host, flags, environment,
source overrides, and source hashes. HEAD alone does not reproduce this build.
Each arm has exact transformation/ledger diffs, source hashes, build commands,
executable hashes, and a binary-bound verification record. Disposable source
roots are outside the checkout; source archives live with the result artifacts.
`disposable-artifacts.tar.gz` retains the exact final source trees, binaries,
and build records. `final-artifact-hashes.json` verified 114 retained artifacts
with no mismatches. `runtime-preservation.json` confirms native/harness hashes
and the pre-existing dirty runtime diff remained unchanged. Optimized assembly
was emitted only after timing ended and retained under `assembly/`; it is
static evidence, not an additional performance experiment or measured ranking.

Exact review bundle SHA-256:
`53ed86869263b518c5e5ad7f09777d96c2bdaf5f4c340a78c35904badf4a3dee`.
The bundle binds all 12 arms, fixture, runner, instrumentation, verification
records, and focused test evidence. Earlier result directories are retained
as failed/superseded preparations, not timed evidence. Two preparer modules
and their documents remained under their original owners.

## Measurement Contract

- Same four-word arithmetic and memory loops as the earlier native benchmark;
  one million guest instructions. Established C is the reference. Memory mode 1
  enables the register prototype but leaves the memory block ineligible.
- One native execution thread, fixed code/mappings, raw 8 KiB callback-mapped RAM,
  no attached shared guest-memory object, observers, devices, peer writers,
  timers, or production interaction workload. These are not two-vCPU results.
- Fixed checkpoint allowance 4096, block interval 10000, total block cap
  budget+1. Exact step deltas and cumulative checkpoints are asserted. No
  general smaller-budget, zero-return, interrupt-latency, or event-service claim.
- Cold execution includes first decode/program/cache preparation. Warm execution
  follows an excluded 8192-step complete-chain warmup. Allocation/setup and this
  preparation-plus-warmup are separately clocked; warmup is not pure decode cost.
  CPU/data reset is outside timing. RAM reset uses the existing write helper;
  valid cache/TLB metadata is retained. No active guest clock needs resetting.
- Timing and instrumentation use separate copied trees/binaries. Diagnostic
  counters are compiled out of timing builds; ledger binaries reject timed mode.
  Each sample uses a fresh process. Full expected-state/code checks and JSON
  emission follow timing; checkpoint invariant checks remain inside the common
  measured execution path in every arm.
- Every execution and warmup checks all CPU fields, full 8192-byte RAM, exact
  steps/status/PC, and no unexpected data callbacks. Code-byte and epoch
  comparisons guard the measured execution interval; the epoch baseline is
  captured after warmup, not before it.
  CPU hex and RAM fingerprint accompany results; full equality is asserted,
  not inferred from the fingerprint. No architectural CPU field is excluded.
  Internal statistics and cache/result-policy counters intentionally differ.
- Eleven forward/reverse alternating rounds per accepted cell are predeclared.
  No compilation, ledger execution, or other benchmark overlaps timing. Three
  process snapshots two seconds apart precede timing; per-round checks follow.
  Pinecone must be absent, no process may exceed 100% CPU, and aggregate sampled
  process CPU must not exceed 400%. Resident VMs alone are not a rejection.
  A load failure invalidates the cohort for attribution, retaining every record.

## Untimed Verification

Final owner-run verification: **1856 exact-prefix cases and 64 million-step
ledgers passed**. Prefix budgets are 1 through 17, 63/64/65, 255/256/257,
4095/4096/4097, and 8191/8192/8193, in both cold and warm fixtures.
`verification-audit.json` checks cross-arm CPU/RAM agreement and independent
event totals. These are focused synthetic checks, not the full native/Swift
fault, concurrent-invalidation, or full-system test suites.

Fifteen targeted rejection cases passed: real checkout, missing marker, source
drift, symlink, and hardlink for each preparation/instrumentation module.
This is not exhaustive validation of every malformed marker or duplicate call.
The ledger status test covers all nine documented native/prototype statuses,
including REVALIDATE and MEMORY_FAULT, and confirms an unknown status traps.

One superseded diagnostic failed because its histogram assumed status<16;
REVALIDATE is 258. This was an instrumentation bug, not a guest regression.
The final recorder explicitly classifies symbolic statuses, rejects unknowns,
and retains exact architectural assertions. No runtime enum was changed.

## Observed Ledger

Per million instructions in the unchanged baseline:

| Event | Arithmetic prototype, warm | Memory prototype, cold | Memory prototype, warm |
| --- | ---: | ---: | ---: |
| Prototype entries | 250000 | 249757 | 250000 |
| Prototype completed steps | 1000000 | 998779 | 1000000 |
| Established executor entries | 0 | 245 | 0 |
| Eligibility/program lookups | 500000 / 500000 | 499516 / 499516 | 500000 / 500000 |
| Currency validations | 1250000 | 1248534 | 1250000 |
| Hot reads / writes | 0 / 0 | 249999 / 249999 | 250000 / 250000 |
| Full read / write helpers | 0 / 0 | 1 / 1 | 0 / 0 |
| Data translation callbacks | 0 | 2 | 0 |
| REVALIDATE / memory faults | 0 / 0 | 2 / 0 | 0 / 0 |
| External hot-store commit calls | 0 | 249999 | 250000 |

Cold memory executes the remaining 1221 instructions through established C
(total minus independently recorded prototype steps). Warm memory does not.
Thus cold minus warm time is not an isolated preparation intercept. Native
`generic_dispatches` counts generic fallback only, not every established handler.

Every memory ledger observes 250000 invalidation checks and skips, with zero
actual invalidations. Warm helpers have no translation callbacks or slow exits.
Statistics-off retains identical independent work counts; validation omission
retains 250000 entries and one million steps but reduces currency checks to
250000. Invocation histograms retain requested, capped, and completed sizes.
These are dynamically observed frequencies, never CPU cycles or cost shares.

## Timing And Interpretation

Maxwell accepted the exact bundle and current selected cells before timing
(`review.md`, Review 3; copied into `timing-approval.json`). The three preflight
samples showed aggregate process CPU 150.4%, 108.7%, and 102.2%, with no Pinecone
process or process above 100%. All before/after checks for rounds 0 through 5
passed. No compiler or ledger was running during those samples.

Before round 6 (the seventh round), Codex Renderer PID 25697 reached **335.8%**
CPU; aggregate sampled process CPU reached **452.3%**, exceeding both predeclared
gates. The runner aborted without executing that round. No process was stopped
to conceal the load. Raw process records and load averages are retained in
`arithmetic-0-6-before-load.json`; `failures.jsonl` records the abort.
The two resident virtualization processes were only 0.3% and 0.7% CPU in the
failing snapshot; their presence was not the abort reason.

Only **84 samples**, six per cold-arithmetic cell, exist. No warm or memory
timing was executed. All 84 are retained in `timings.jsonl` but excluded from
attribution: none meets the required nine-sample minimum. `timing-status.json`
records the terminal owner disposition (the runner left `in_progress` when
the pre-round check failed), and `summary.json` has
`eligible_for_attribution: false`. Its six-sample medians/spreads are descriptive
debugging artifacts, not publishable cost estimates or a ranked result. This
incomplete cohort does not satisfy the predeclared evidence gate; no inferential
performance claim is made.

The successful untimed evidence supports these narrower conclusions:

- Repeated invocation work is real: the warmed four-step prototype makes
  250000 entries and 500000 lookups per million instructions. Budget controls
  reduce entries while retaining per-instruction validation; the histograms
  prove the intended contrast, not its performance benefit.
- Cold-only helper exits are confirmed: exactly one full read and one full
  write, two translations, and two prototype REVALIDATE returns; zero in the
  warmed memory fixture. Persistent warmed helper misses are rejected as an
  explanation of this fixture's regression. Their cycle cost is unmeasured.
- Wrapper statistics omission preserves independently counted work; validation
  omission changes checks but not entries/steps. Neither has a ranked timing
  effect from this incomplete cohort.
- No measured evidence here ranks entry overhead against validation, statistics,
  superblock policy, store-call ABI effects, or handler work. Static instruction
  counts and the prior benchmark medians must not fill that gap. Effects must
  not be summed as independent components.

Next action is a fresh approved cohort on a quiet host, using the retained
sources/binaries and explicitly re-established timing/VM coordination. Do not
resume by appending to this failed cohort or relax the load threshold after
seeing the failure. Only after complete measurements should Phase 2 prioritize
an execution/invalidation contract; no assembly implementation is justified
by this blocked timing attempt.

## Scope And Restoration

No JIT, assembly executor implementation, production default, guest-image,
installation, or disk-state change belongs to this experiment. Parent stopped
the original Pinecone app after measurement preflight identified PID 58989.
Immediately after the timing abort, the measurement owner used the parent's
explicit restore-only grant. `xcrun simctl launch` on original booted device
`541E22EE-C52B-4478-A041-56FEDC23ACFF` returned success for
`me.gmoran.pinecone`, PID **68383**. `app-restoration.json` records the command,
exit code, returned PID, and all eight exact environment flags: established C,
threaded memory off, two vCPUs, parallel vCPU enabled, original Phosh autorun,
display, performance metrics, and UART dump. Parent was notified immediately.
This proves launch success, not a newly observed guest-ready state.

## Retry Same Artifacts

No further timing is authorized by this report. Prefer a complete fresh cohort
over continuity after the interruption and app restoration. Keep all six old
rounds excluded; do not replace only slow samples, append five rounds, or pool
across the break. The original binary/source approvals remain evidence of
identity, but a new output directory produces a new review-bundle hash and
requires renewed reviewer/parent approval.

Exact metadata-only preparation command from the repository root:

```sh
python3 experiments/phase1/fresh_cohort.py experiments/phase1/results/20261029T044919Z experiments/phase1/results/20261029-retry-01
```

This verifies the original bundle, copies only untimed verification/manifests,
and references the same frozen source trees and binaries. It neither compiles
nor runs native code; it prints the new bundle hash. It refuses an existing
destination. It has not been executed for a new cohort in this task.

After that exact new bundle is approved, the parent re-establishes the sole-owner
lease, quiet host, authorized Pinecone stop, and new restoration obligation.
Then the precise native timing command is:

```sh
python3 experiments/phase1/measure.py time experiments/phase1/results/20261029-retry-01 baseline prototype-limit-4 prototype-limit-16 prototype-limit-64 prototype-limit-256 prototype-limit-4096 established-superblock-off cost-reference cost-validation-entry-only cost-prototype-stats-off cost-memory-stats-on cost-memory-stats-off --samples 11
```

The helper also prints a command with the same accepted cells. Future parent
coordination, not this command, grants permission to stop/restore the app.
Original disposable sources must still exist and hash-match; if removed,
restore them from the retained archive at their recorded absolute paths or
rebuild and obtain approval for new identities. Never silently substitute files.

## Rebuild From Source

Run from the repository root, with the sole compile/timing lease:

```sh
python3 experiments/phase1/measure.py freeze
python3 experiments/phase1/measure.py prepare RUN baseline prototype-limit-4 prototype-limit-16 prototype-limit-64 prototype-limit-256 prototype-limit-4096 established-superblock-off cost-reference cost-validation-entry-only cost-prototype-stats-off cost-memory-stats-on cost-memory-stats-off
python3 experiments/phase1/test_preparation.py RUN
python3 experiments/phase1/measure.py verify RUN baseline prototype-limit-4 prototype-limit-16 prototype-limit-64 prototype-limit-256 prototype-limit-4096 established-superblock-off cost-reference cost-validation-entry-only cost-prototype-stats-off cost-memory-stats-on cost-memory-stats-off
python3 experiments/phase1/audit_verification.py RUN
python3 experiments/phase1/measure.py review-bundle RUN baseline prototype-limit-4 prototype-limit-16 prototype-limit-64 prototype-limit-256 prototype-limit-4096 established-superblock-off cost-reference cost-validation-entry-only cost-prototype-stats-off cost-memory-stats-on cost-memory-stats-off
```

The reviewer must accept the new exact bundle; review IDs alone are insufficient.
Then `measure.py time RUN` with the same explicit arm list and `--samples 11`
enforces source/binary/settings identity and process gates. `RUN` is the new
directory printed by freeze, not this aborted run. `analyze_results.py` refuses
incomplete cohorts. Restoring/stopping the app requires fresh explicit parent
coordination; the one-shot restoration above is already complete.
