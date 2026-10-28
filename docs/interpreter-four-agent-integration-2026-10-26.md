# Four-Agent Native Integration

## Scope And Status

Integration of the four workstreams captured in
`performance-workstreams-2026-10-26.md`, using its exact pre-dispatch dirty-tree
snapshot rather than git HEAD. Existing unrelated changes are preserved.

Implementation and correctness review are complete. The final Simulator candidate
failed performance acceptance. The source remains in the working tree for review,
but this batch is not an accepted end-to-end performance improvement. The preserved
pre-dispatch app is the rollback target; no source reset is involved.

## Changes

- Paired 64-bit loads/stores reuse a certified same-page TLB span. Cross-page,
  permission, observation-lock and generation paths remain intact.
- Superblock composition reuses repeated edges and deduplicates block validation
  within a stable epoch. Checkpoint invalidation, recycled cache entries,
  self-modifying callbacks and changed callback operands are checked explicitly.
- Musttail handlers cover shifted/extended arithmetic, carry arithmetic and
  shifted logical operations. There are 48 verified register tail handlers.
  Runtime selection retains the existing precedence; an unconditional
  superblock-priority experiment was rejected after full-guest measurements.
- Auxiliary programs have bounded ownership, lifetime-negative eligibility,
  explicit invalidation cleanup and a 256-program FIFO replacement cache. Hits
  do not rewrite the replacement list.
- Optional scalar-memory integration has separate eligibility and telemetry.
  It exits after each memory access, revalidates after callbacks, and never
  retries an unclassified failed access through another executor.

No Swift fallback, JIT, guest image, RAM or vCPU policy changes were introduced.
The simulator register prototype remains enabled. Physical-device defaults are
unchanged. `PINECONE_THREADED_MEMORY=1` is an opt-in experiment, **off by default**.

## Review Corrections

Parent review found that successful prototype stores must clear the local
exclusive reservation. The original public test oracle did not copy exclusive
state back, hiding the discrepancy. Tests now use the full-state reference API.

A second review found two optional-memory integration issues: narrow stores must
mask callback values to their access width, and a Swift error must publish the
retired CPU prefix, including PSTATE/FP status, before propagating the error.
These are corrected before final installation; the A/B candidate was built
before these corrections with the entire optional memory path disabled.

Public-VM tests then exposed a second retry inside the common memory helper:
a failing physical callback fell through to the virtual slow callback. Successful
physical translation now makes the installed physical callback authoritative.
Cross-page, unavailable-translation and absent-callback slow paths remain intact.
Both load and store tests verify exactly one failed device invocation, preserved
CPU/FP state and retired RAM/MMIO writes, with zero Swift fallback.

The reference executor can retry a failed store after retiring a block prefix.
The optional path explicitly fails after one attempt; integrated regressions
check architectural equivalence without requiring that duplicate callback.

## Serial Microbenchmarks

Positive percentages mean **more time**, negative means less. These are bounded
synthetic workloads on the host Mac, not projected UI speedups.

| Workload | Candidate time change |
| --- | ---: |
| Hot 64-bit pairs | -16.08% |
| 32-bit pair control | +1.05% |
| Unaligned 64-bit pairs | -9.83% |
| Host-observed pairs | -12.83% |
| Cross-page pairs | -0.04% |
| Cold pair translation | +1.89% |
| Cached-chain pair workload | -10.66% |
| Steady arithmetic validation | +3.81% |
| Steady memory validation | +4.76% |
| Arithmetic superblock composition | -5.62% |
| Memory superblock composition | -3.69% |

Pair measurements used eight rounds of eight million steps. Validation used six
rounds and 10,000 iterations. The pair sweep preceded stopping the Simulator;
later sweeps ran with the app stopped. Other host workloads were not controlled.

Four prepared arithmetic loops ran 2.16-2.71 times as fast under the expanded
musttail executor as the frozen existing threaded executor, with six alternating
rounds of 30 million instructions. This is **not** a comparison against the
previous musttail subset or a measurement of whole-guest throughput.

The cache collision test reduced 200,000 program constructions to four. However,
its single-order diagnostics-off measurements were +12.3% hot, +122.9% on the
five-entry collision-free stream, +22.8% mixed and +11.7% at capacity. Absolute
times were short, and this used the agent's pre-memory-integration cache snapshot.
Do not claim an across-the-board cache speedup; combined app measurements are
required. Parent subsequently replaced LRU hit updates with FIFO. A new 2-million
lookup sweep (current dependencies, not a cache-policy-only comparison) measured
hot 19.56ms versus 14.77ms baseline, collision-free five-entry 14.09ms versus
12.43ms, mixed 27.53ms versus 31.07ms, and capacity 414.24ms versus 409.36ms.
Forced-collision time was 19.53ms versus 400.56ms, with two million constructions
reduced to four. Remaining hot-hit overhead is explicitly not considered solved.

The integrated million-instruction load/add/store/branch loop used nine rotating
rounds. The optional memory path took about 22.7ms versus about 7.2ms without it,
and generated 250,003 checkpoints rather than 245. **Rejected as a default.**
Its correctness boundary is retained, not removed to make the benchmark faster.

## Verification

- 507,622 prototype differential cases passed in optimized, unoptimized-musttail
  and UBSan builds, including the final narrow-store regression additions.
- Machine code: 48 indirect register tail branches with zero ordinary calls;
  two terminal memory helpers with no successor dispatch.
- 3,136 integrated cached-chain/budget/checkpoint/memory scenarios and 128 cache
  replacements passed normally and under UBSan.
- Paired memory: 13,109 cases, matching reference digest under UBSan.
- Validation: all nine candidate groups passed under UBSan; four correctness
  groups reproduce failures on the frozen baseline.
- FIFO cache: normal, diagnostics-off, UBSan and prototype-disabled checks passed,
  including memory classification, eviction/recreation and lifetime reset.
- Full Swift suite: 653 tests passed, including both public-VM fault regressions.

Final Simulator boot/unlock/Settings observations are recorded below once complete.
ASan and real-device performance are not acceptance claims.

## Initial Combined ABBA

The initial LRU candidate, with optional memory disabled, did **not** demonstrate
an end-to-end gain. Both builds used the same restored disk, two parallel vCPUs,
register prototype enabled, and interaction tracing. No compiler/test jobs ran
during this comparison; unrelated host activity was not controlled.

| Order | Build | Readiness seconds | Process CPU seconds at readiness |
| --- | --- | ---: | ---: |
| 1 | Frozen baseline | 67.34 | 68.92 |
| 2 | Initial candidate | 66.93 | 72.20 |
| 3 | Initial candidate | 87.53 | 85.07 |
| 4 | Frozen baseline | 67.08 | 70.06 |

All four reached shell and a Phosh frame with zero Swift fallback. Expanded
musttail coverage increased from 0.47-0.49% to 1.94-2.00% of primary instructions,
but coverage alone did not produce a demonstrated runtime gain.

After run 4, baseline unlock required two accessibility full-height swipes.
The first was still on the lock screen at the 42-second observation; the launcher
was visible 24 seconds after the second swipe. Settings showed its splash at
16.6 seconds and Network content at 47.1 seconds after the tap. The recorded
request-to-first-surface interval was 29.625 seconds, not a complete-content
latency. These observation brackets are not ordinary touch-to-frame measurements.

## Dispatch Interaction Found During Acceptance

The FIFO revision still produced readiness times of 83.02 and 89.68 seconds,
with 88.35 and 84.88 process CPU seconds. Those results were rejected as evidence
of a performance improvement, despite both runs booting with zero fallback.

Inspection found that prototype eligibility suppressed superblock construction.
Expanding instruction coverage therefore moved additional short blocks out of
long fused traces and into repeated cache dispatch. A new integrated million-step
ADD/ADC/AND/branch loop reproduced this conflict:

- Before: prototype enabled had zero superblock dispatches, all one million
  instructions in isolated prototype blocks, median approximately 14.65ms.
- Reference path: approximately 6.1ms with superblock dispatch.
- After prioritizing superblock construction: approximately 5.46ms, 7,813
  superblock dispatches and only the initial four instructions in the prototype.

Nine rotating on/off rounds checked exact state and instruction retirement.
Before/after binaries were run serially rather than interleaved, so the strongest
evidence is the within-run enabled/disabled comparison and dispatch counts, not
an exact percentage speedup. However, actual guest runs with this experiment took
111.59 and 91.93 seconds, with 105.91 and 102.78 process CPU seconds. A fresh
baseline control took 58.08 seconds / 67.48 CPU seconds. **Rejected and removed**:
the synthetic-loop improvement did not translate to the guest. The diagnostic
benchmark remains, but the production precedence and regression expectations
were restored. Existing callback, code-write, timer and fault checks remain
intact. The optional memory experiment stays off.

The rejected priority build did unlock and render Settings with zero fallback;
its request-to-first-surface interval was 36.626 seconds. Functional correctness
is not performance acceptance. A five-second unlock sample is retained at
`/tmp/pinecone-priority-unlock.sample.txt`.

The two intermediate app identities and raw runs remain preserved in
`/tmp/pinecone-four-agent-abba-20261026` and
`/tmp/pinecone-four-agent-final-20261026`; the latter name predates discovering this
dispatch issue and does not identify the final accepted executable.

## Follow-Up On The Regression

The review identified over-conservative global epoch exits: unrelated executable
page mutations can split otherwise valid traces, and epochs captured before a
mapping lookup can cause a zero-step exit after that lookup refreshed the code.
The corrective work keeps serial/mapping/code checks, but revalidates mismatches
before deciding whether the current span must exit. All 12 focused groups pass
normally and under UBSan; the three new groups reproduce failures in the prior
candidate. Selected-entry serial checks replace unrelated global residency
checks. Validation must observe stable reset, mapping and code epochs before
continuing at the current instruction index. No blind epoch acknowledgment or
unbounded retry loop is used.

The first cold-validator build regressed steady synthetic loops by 26-30%.
Explicitly inlining the small fast checks and keeping revalidation cold/noinline
reduced this to +6.26% arithmetic / +5.36% memory; composition measured -2.77% /
-1.06%. All 12 groups still passed. Raw comparison:
`/tmp/native-validation-span-inline-parent-serial`. These percentages remain
relative to the baseline with the four known correctness failures, not proof of
whole-guest improvement.

The shared code epoch also sat immediately beside write-ticket and translation
state. It now has 128 bytes of padding on both sides, isolating it for cache lines
up to 128 bytes without an over-aligned allocation requirement. All atomics and
locks are unchanged. This adds 256 bytes per guest-memory object; its benefit
requires measurement. Candidate test dependencies must use the matching private
layout, never a mixture of old object files and the new header.

Eight alternating rounds of the two-thread counter benchmark measured -11.30%
elapsed time with shared-reader/writer traffic. Reader-only, writer-only and
separate-object controls changed -3.34%, -2.38% and +3.45%, respectively. Each
round used eight million atomic operations per worker and checked exact final
ticket/epoch values. This models contention, not guest execution or UI latency.
Raw results: `/tmp/native-pair-memory-epoch-parent-serial`.

The layout-aware paired-memory runner builds each version with its own source,
private headers and objects; normal and UBSan runs passed all 13,109 pair cases
plus four contention correctness cases. Its current full-candidate comparison
must not be described as isolating only the paired-memory optimization.

## Evidence And Reproduction

Durable raw evidence: [four-agent-integration-2026-10-26.tar.gz](performance-evidence/four-agent-integration-2026-10-26.tar.gz)
(SHA-256 `ab474ad4ca192720471989b5300b9cf332488842884ebe4e66799ad8d6223715`).
This archive includes the rejected and final Simulator runs, serial validation
and contention measurements, final test/build logs and the rejected-build
unlock sample. It deliberately excludes guest disks and app binaries.
The later restored-control raw files are in
[four-agent-restoration-2026-10-26.tar.gz](performance-evidence/four-agent-restoration-2026-10-26.tar.gz).

The dedicated regression Simulator now has the frozen pre-dispatch app installed.
Its installed executable hash was verified as
`9344a25f0fe36eaa0fb69f90d8860e847c64afad181a1adaa76629bc23d2533a`.
No source files were reverted, no physical device was changed, and no commit was
created. Rebuilding the current working tree produces the unapproved candidate,
not the installed baseline.
The restored lock screen was visually confirmed with zero fallback. Its launcher
was also not observed at 36 seconds after the second accessibility swipe. Thus
this session does not isolate the failed unlock check to the candidate, and it
does not establish a successful final unlock/Settings smoke test on either build.

### Final Acceptance Result

Final executable SHA-256:
`ccc35bc3e0251744c85caa1654962ae686fa118d2e716294cf6acaaea4a808e8`.
Final `ARM64VizNative.c` SHA-256:
`5c254819c31c2c9f5416cc31e24e731c1a039e70b959b2cf488337941779811e`.

The final Release build, 653 Swift tests, and 3,136 integrated runtime scenarios
plus 128 replacements under UBSan passed. The optional memory executor remained
disabled. Final same-disk Simulator comparison:

| Order | Build | Readiness seconds | Process CPU seconds at readiness |
| --- | --- | ---: | ---: |
| 1 | Frozen baseline | 132.46 | 132.66 |
| 2 | Final candidate | 153.57 | 142.49 |
| 3 | Final candidate | 148.71 | 160.07 |
| 4 | Restored frozen baseline | 164.26 | 149.40 |

All four reached the recorded readiness milestone with zero fallback on both
vCPUs. Candidate wall time was 12.3-15.9% longer and process CPU time was 7.4-20.7%
higher than the first control. The subsequent restored control was slower than
both candidates, so that first-control comparison cannot establish a reliable
regression size. Mean readiness was 148.36 seconds baseline versus 151.14 seconds
candidate; mean process CPU time was 141.03 versus 151.28 seconds. These are
descriptive values, not a significant treatment effect. The restoration run also
overlapped a short evidence-compression command and is not a pristine timed run.
This is a small sequential sample on a busy host, not
a confidence interval or clean attribution to a particular change. WindowServer,
Codex and Chrome were consuming substantial CPU; even the preserved baseline
slowed from earlier 58-67-second runs to 132-164 seconds. Nevertheless, these results
do not meet the no-regression gate and cannot support a speedup claim.

The final candidate lock screen was visually confirmed. Two full-height
accessibility swipes and one coordinate drag did not produce an observed
launcher; the last observation was 72 seconds after the coordinate drag. Input
telemetry recorded two 98-event gestures plus the three-event drag, but these
events remained uncorrelated to a guest frame. Settings was therefore not
verified on the final candidate. This is a failed/incomplete UI acceptance
check, not proof of a particular input or CPU defect. Earlier intermediate
builds reaching Settings do not substitute for this check.

Do not enable the experimental scalar-memory path or ship this batch on the
strength of its synthetic gains. The next acceptance experiment must isolate
coverage/dispatch changes from required correctness checks using the frozen
source snapshot and identical guest disks. Preserve the invalidation/fault
regressions when selecting any smaller subset for rollout.

Serial logs: `/tmp/native-pair-memory-parent-serial.log`,
`/tmp/native-validation-span-parent-serial/`,
`/tmp/threaded-coverage-parent-benchmark.log`,
`/tmp/threaded-memory-integrated-benchmark.log`.

`scripts/compare-native-simulator-builds.py` performs explicit-device ABBA
comparison of two app bundles, restoring a checksum-verified APFS-cloned disk for
each run. It preserves the initial Simulator disk, collects raw UART/runtime
logs, process CPU/RSS samples and milestones, and stops on any profile failure.
Milestones are not semantic proof of unlock or Settings content; those require
separate UI observation. The utility intentionally requires all paths and the
Simulator ID, rather than selecting a physical device or resetting user data.
