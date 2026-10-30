# Phase 5: Bounded Native Chaining

Status: the bounded offline Phase 5 gate is complete. Two load-qualified cohorts
on the same executable pass the declared throughput and event-service limits.
This does not promote the executor into Pinecone or establish a Phosh speedup.

## Predeclared Gates

This is an isolated Darwin ARM64 executor experiment, not a Pinecone runtime
default change. No Swift fallback or production scheduling cap is changed.

Before collecting Phase 5 timing:

- Keep the existing per-instruction code/context epoch checks. No extra stale
  instruction window is permitted.
- Clamp retirement to the smaller global and service allowance, and count every
  taken branch, initial entry and fallthrough block entry. Blocks contain at most
  16 instructions. Asynchronous event polling must be no later in guest
  instruction terms than the same block-return baseline.
- Full helper success/fault remains a terminal boundary. No callback replay.
- Throughput: at windows of 64 or more, median chained wall time must be no more
  than 1.05 times the equally guarded assembly block-return baseline, across
  rings of 2, 8, 32 and 128 blocks. Four-instruction windows are an overhead
  control, not a proposed use for chaining.
- Event-service diagnostic: 101 interleaved samples per mode and block length;
  target chained p95 <= baseline p95 * 1.10 + 1 microsecond. Record outliers,
  including host scheduling. This is not a physical-device or guest IRQ latency
  guarantee and cannot replace the Phase 7 full-system gate.
- Preserve all Phase 3/4 differential, ABI, helper and invalidation checks.
  Run optimized and UBSan suites. ASan remains a separately reported toolchain
  limitation until a run actually completes.

## Implementation

All changes are in `experiments/phase3` and documentation. The established C
executor, C threaded prototype, iOS build settings, images and defaults remain
unchanged in this phase.

- `chain.c` owns an immutable graph of separately decoded programs. It resolves
  branches/fallthrough into stable entry gates at construction. A run pins the
  entire graph, not just its first block. Owner callback retirement defers every
  program/gate free until return; reentrant execution is rejected.
- The new assembly boundary handler follows links without a C call, dispatcher
  lookup or additional frame. It polls the event word and accounts the block
  allowance. Out-of-graph branches use a distinct outside sentinel, never the
  adjacent block's fallthrough gate.
- Blocks must be sorted, disjoint, page-contained and at most 16 instructions.
  A branch before the last instruction is rejected: otherwise its not-taken path
  could silently skip a block-based checkpoint.
- Cached page-generation proofs are protected by a shared code epoch and the
  original translation/context guards. Unrelated executable writes require a
  page rescan; changed pages or contexts cannot reuse the graph. Validation is
  repeated around the scan and again at assembly entry.
- For native RAM, duplicate explicit/implicit epoch checks are merged only if
  the token address **and captured value** match. A newer memory snapshot must
  not validate stale decoded instructions. The remaining epoch check still runs
  after every retired instruction.
- CPU/PC writeback, retirement, budget decrement and validity checks remain
  per instruction. They are deliberately not batched speculatively. Every full
  memory helper remains terminal, including successful MMIO at the last budget
  unit and failures that also retire/invalidate the graph.
- Optional counters expose entry, proof reuse/scans, page checks, block entry,
  event polls, yields, revalidation, retirement and final reclamation.

## Verification

Optimized and UBSan runs pass:

- Existing 82,370 Phase 3 differential/ABI/boundary cases and the complete Phase
  4 memory/permission/observer/SMP suite.
- 72,753 Phase 5 cases: all tested instruction/service/block budget combinations,
  middle-of-block entry, conditional/compare/test/link branches, fallthrough,
  out-of-graph exits, unsupported instructions, cache proof reuse, context
  rejection, event requests and concurrent code/translation publication.
- 257 additional native-RAM cross-block differential budgets, comparing complete
  CPU and RAM contents against the established C core. Real self-modifying
  stores stop before following the successor; peer code writes and all four
  shared TLBI scopes stop register-only tails.
- Owner callback retirement with 300 replacement-chain allocations while a peer
  publishes invalidations. Reclamation stays at zero inside the callback and
  becomes one only after the pinned run returns. Successful and failed helpers
  retain exact retirement, fault PC and single callback effects.
- Disabled entrypoints do not allocate or execute. Generated C/assembly offsets
  match; emitted assembly retains one frame, no x18 use, no indirect C calls and
  only the two existing terminal helper calls.

Clang static analysis of `chain.c` also completes without diagnostics.
Final enabled binary SHA-256:
`082e3346bdc5a636cd9f0ed04029a932c04851a5f25179795190bedb51d86486`.
Final logs: `/tmp/pinecone-phase5-final.log` and
`/tmp/pinecone-phase5-final-ubsan.log`. UBSan instruments C, not assembly memory
accesses. ASan was not rerun: the Phase 4 host startup deadlock remains an open
toolchain limitation. TSan/arm64e are not verified. No Phase 5 simulator boot or
UI speed improvement is claimed: this executor is not linked into the app.

## Earlier Measurement Attempts

The first five attempts were rejected before timing by the unchanged
host-load gate, first aggregate CPU above 400%, then Spotlight `mds_stores`
above the per-process 100% threshold. No rejected timing is evidence of a speedup.
Each attempted pause resumed the identified Simulator process; no VM reset or
reinstall was performed. Raw attempt records are under
`experiments/phase3/results/phase5-*` (ignored build/measurement artifacts).

The harness now optionally waits up to 120 seconds for three consecutive
passing load checks. Thresholds and post-run rejection remain unchanged.
Those attempts did not close the gate. The accepted follow-up below is the
performance evidence used to close this isolated phase.

The separate functional benchmark smoke completed all 480 CPU-state assertions
and 404 event-publication samples. Its CSV/event output is retained at
`/tmp/pinecone-phase5-benchmark-smoke.csv` and
`/tmp/pinecone-phase5-benchmark-smoke.events`. It ran without a quiet-host gate;
its latency/throughput values are **excluded**, not substituted for accepted
performance evidence. The final Simulator process check showed PID 80152 in
normal `Ss` state, not suspended.

Allocation footprint is deterministic and does not depend on host timing:

| Four-instruction blocks | Separate program bytes | Chain graph bytes |
| ---: | ---: | ---: |
| 2 | 528 | 1,128 |
| 8 | 2,112 | 4,056 |
| 32 | 8,448 | 15,768 |
| 128 | 33,792 | 62,616 |

These totals exclude allocator overhead and common CPU/RAM/TLB storage. The
larger graph stores stable middle-of-block entry gates; it must earn that cost
in accepted throughput/cache-footprint measurements before promotion.

Reproduce on a quiet Darwin ARM64 host:

```sh
AG_BUILD_DIR=/tmp/pinecone-phase5-build sh experiments/phase3/run.sh --test
sh experiments/phase3/run.sh --ubsan
python3 experiments/phase3/measure.py \
  --binary /tmp/pinecone-phase5-build/test-enabled --suite chain \
  --output experiments/phase3/results/phase5-new-cohort --load-wait-seconds 120
```

Stop the Simulator VM normally first, or supply `--pause-simulator-pid` using
the freshly verified PID of the test app. Do not reuse a historical PID blindly.

## Requested Benchmark Rerun

The subsequent requested benchmark used the same verified binary and unchanged
C/header/assembly sources. Two new attempt records are retained:

- `experiments/phase3/results/phase5-benchmark-request-1`: three consecutive
  pre-run load checks passed. The executable completed with exit code 0,
  producing all 480 throughput samples and 404 event samples without assertion
  failures. The post-run aggregate host CPU was 413.7%, above the unchanged
  400% ceiling, so the entire timing cohort is rejected for acceptance.
- `experiments/phase3/results/phase5-benchmark-request-2`: no qualifying quiet
  window within 120 seconds; no timing executed. Both attempts resumed the
  identified Simulator app automatically. No settings or executor changes.

The following are **descriptive raw observations from the rejected first
attempt**, not accepted evidence of a speedup or permission to close Phase 5.
Each cell is the median of 15 samples, in milliseconds per 1,048,576 guest
instructions. Both modes use the same guarded assembly handlers. The baseline
returns to C after each four-instruction block; the chain retains execution to
the stated service window.

| Blocks | Window | Block returns (ms) | Chain (ms) |
| ---: | ---: | ---: | ---: |
| 2 | 64 | 4.030 | 2.605 |
| 8 | 64 | 4.045 | 2.545 |
| 32 | 64 | 4.020 | 2.635 |
| 128 | 64 | 3.971 | 2.911 |
| 2 | 256 | 3.953 | 2.311 |
| 8 | 256 | 3.965 | 2.309 |
| 32 | 256 | 3.896 | 2.389 |
| 128 | 256 | 3.939 | 2.334 |
| 2 | 4096 | 3.911 | 2.223 |
| 8 | 4096 | 3.955 | 2.252 |
| 32 | 4096 | 3.854 | 2.309 |
| 128 | 4096 | 3.899 | 2.256 |

The short-window control illustrates overhead, not a candidate configuration:
at window 4, chain medians were 5.534/6.433/8.958/11.614 ms for 2/8/32/128 blocks,
versus baseline 3.991/3.954/3.951/3.941 ms. Do not route very short calls through
the graph merely because longer-window observations look promising.

Raw publication-to-return p95 was 1 microsecond in both modes at both event
polling cadences (4 and 16 instructions), with 101 samples per cell. Maxima were
1/8 microseconds for baseline/chain at cadence 4 and 23/28 microseconds at
cadence 16. The clock returned zero for many sub-resolution intervals; that is
not zero latency. Host scheduling is included, and these rejected observations
do not establish guest interrupt or touch latency.

That functional test succeeded, but performance acceptance remained open until
the subsequent cohorts below. No rejected timing contributes to their results.

## Accepted Cohorts

Both cohorts use executable SHA-256
`082e3346bdc5a636cd9f0ed04029a932c04851a5f25179795190bedb51d86486`.
The executable hash and complete source manifests match across both runs, and
the compiled C/header/assembly source hashes match the tested Phase 5 build.
There were no executor, compiler, scheduling, image or app-setting changes.

Raw artifacts (ignored measurement output):

- A: `experiments/phase3/results/phase5-acceptance-1/{report.json,samples.csv,stderr.txt}`
- B: `experiments/phase3/results/phase5-acceptance-2/{report.json,samples.csv,stderr.txt}`

Each cohort contains 480 throughput samples (15 rounds per workload/window/mode)
and 404 event samples (101 per cadence/mode), for **960 throughput and 808 event
samples total**. Both executables exited zero, all CPU-state assertions passed,
and both reports record `accepted: true` and `resumed: true`.

The unchanged load protocol requires three consecutive passing pre-run checks
and a passing post-run check. Cohort A passed immediately. Cohort B waited for
load to settle before starting; its earlier failed preflight checks are retained.
The four qualifying aggregate CPU readings were:

- A: 180.5%, 244.1%, 257.8%, 334.8%; maximum individual process 91.2%.
- B: 397.9%, 399.1%, 396.2%, 388.9%; maximum individual process 61.4%.

These are endpoint load checks, not continuous interference monitoring or an
otherwise idle host. No system services or unrelated applications were stopped.

### Throughput

Median milliseconds per 1,048,576 guest instructions; 8,192-instruction warmup.
Baseline returns from guarded assembly after every four-instruction block.
Chaining uses the same handlers, code/context guards and block service cadence,
but amortizes entry/return work across the stated instruction window.

| Blocks | Window | A baseline | A chain | B baseline | B chain |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 64 | 4.209 | 2.674 | 4.028 | 2.537 |
| 8 | 64 | 3.926 | 2.515 | 4.044 | 2.534 |
| 32 | 64 | 3.970 | 2.578 | 3.974 | 2.653 |
| 128 | 64 | 3.800 | 2.805 | 3.976 | 2.834 |
| 2 | 256 | 4.399 | 2.495 | 3.873 | 2.312 |
| 8 | 256 | 3.825 | 2.300 | 3.891 | 2.310 |
| 32 | 256 | 3.863 | 2.277 | 3.875 | 2.327 |
| 128 | 256 | 3.748 | 2.282 | 3.825 | 2.456 |
| 2 | 4096 | 3.821 | 2.227 | 3.811 | 2.216 |
| 8 | 4096 | 3.828 | 2.210 | 3.874 | 2.260 |
| 32 | 4096 | 3.833 | 2.192 | 3.844 | 2.243 |
| 128 | 4096 | 3.766 | 2.197 | 3.868 | 2.352 |

All 24 eligible comparisons pass `chain <= baseline * 1.05`. Chaining uses
26.2-43.3% less median wall time (1.35-1.76x throughput) in A and 28.7-41.9% less
(1.40-1.72x) in B. These are synthetic, warmed, register-only block-ring results,
not whole-emulator or UI gains. Individual cells remain noisy: for example A's
2-block/256 window has baseline/chain IQRs of 0.957/0.985 ms, versus 0.094/0.066
ms in B. Raw distributions and CPU-time summaries remain in the reports; no
statistical-significance claim is made.

At the four-instruction control window, chaining is 1.38-3.04x slower across the
two cohorts. The larger graph costs 1.85-2.14x the separate decoded allocations
for the tested sizes (see footprint table). Thus the offline gate closes for
longer windows, not for blanket replacement of short calls. The existing
single-program path must remain available when the service allowance is small.
No production cap is widened by this result.

### Event Service

All four p95 comparisons pass the declared
`chain <= baseline * 1.10 + 1 microsecond` bound. Every cell has p95 1 microsecond.
Maxima are retained, not hidden by that percentile:

| Cohort | Cadence (instructions) | Baseline max (us) | Chain max (us) |
| --- | ---: | ---: | ---: |
| A | 4 | 1 | 2 |
| A | 16 | 1 | 7 |
| B | 4 | 1 | 10 |
| B | 16 | 7 | 1 |

Many median observations are zero at the host clock's observed resolution; they
do not establish zero latency. The outliers include host scheduling. This gate
measures an atomic host event publication to executor return, not guest IRQ
delivery, touch-to-frame latency or a hard wall-clock deadline guarantee.
Instruction/block service bounds remain covered by the correctness suite.

### Closure Decision

The bounded offline Phase 5 gate is complete: identical-source repeat cohorts
pass load, throughput and event-service checks, while short-call and footprint
costs remain explicit. Established C and Pinecone defaults remain unchanged.
The final optimized and UBSan correctness binaries were rerun after measurement;
both passed. Fresh logs are `/tmp/pinecone-phase5-acceptance-regression.log` and
`/tmp/pinecone-phase5-acceptance-ubsan.log`. Simulator PID 80152 was verified in
normal `Ss` state after both cohorts, not left suspended.
Phase 6 is next: expand only measured hot instruction forms. Full-system
integration and Phosh/application measurements still belong to Phase 7.

## Remaining Integration Gates

This chain API requires caller-validated snapshots and live page/context tokens.
Tests connect it to real native RAM tokens, but there is no production cache or
scheduler adapter yet. That adapter must enroll code pages, preserve ASID/EL and
mapping identity, convert timer/deadline budgets, propagate IRQ/cancellation and
quiesce before token identity reuse. Atomic event publication is a host service
signal, not guest interrupt injection or proof of ARM barrier completion.

Graph lifetime is owner-confined: peers publish invalidations, not frees. No
cross-thread destruction or reset/wrap ABA guarantee is claimed. Full-system
two-vCPU boot, unlock, Settings and browser event benchmarks remain Phase 7
promotion gates. The existing single-program path remains appropriate for short
invocations; chaining adds graph/proof setup and a larger decoded footprint.
