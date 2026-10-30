# Pinecone Performance Roadmap

## Priority 1: Phosh Interaction And Graphics Latency

### Current Device-Test Promotion

At the user's request, the tested assembly-backed executor is now the iOS
default and musl r10 is the default rootfs overlay, alongside the scoped Phosh
icon-shadow removal. Both primary and secondary iOS backends receive the same
default. Service/bounded chaining and older threaded experiments remain off;
these were not part of the measured candidate. Physical-device RAM remains
384 MiB. See `Apps/iOS/MobileOSHost/README.md` for installation and disk reseeding.
This explicitly supersedes the historical opt-in status below for device testing,
not the unresolved performance/correctness acceptance gates.

**This is the active top priority, ahead of every numbered executor phase below.**
The required outcome is visibly faster unlock, touch/scroll response, and
application launch, with correct text, icons, damage, and input delivery.
Boot readiness, instruction counts, and synthetic throughput are supporting
diagnostics, not acceptance criteria for this work.

Speculative interpreter expansion, further chaining experiments, snapshots,
additional platforms/apps, and cosmetic work are paused. CPU/scheduler changes
are permitted only when a measured interaction identifies them as the critical
path. Keep rejected service/bounded chaining disabled. Do not change executor,
guest packages, vCPU count, or profiling settings between a baseline and its
candidate merely to improve a result.

### Immediate Execution Order

1. Capture actual unlock, Settings cold launch, and warm Settings/Home
   transitions on the disposable Simulator. Preserve a known disk/build and
   record actual flags, two-vCPU configuration, competing load, and input
   observations. Keep failed taps, missing text, and timeouts in the results.
2. Attribute the delay across input queue/delivery, guest application/event
   processing, Phoc/Pixman rendering, paravirtual submission, host copies/locks,
   Metal execution, and presentation. Use interval counter deltas and profiles,
   not whole-boot totals. Separate guest software Pixman fallback from fast host
   C rasterization; a non-Metal operation is not automatically slow emulation.
3. Fix the largest measured contributor with a narrow, reviewable change.
   Prioritize the guest render/app path when host GPU/copy time cannot explain
   the stall. Do not redesign the interpreter or remove graphics synchronization
   without evidence that it dominates this workload.
4. Run targeted correctness regressions, then verify shell, lock/unlock,
   Settings, return Home, text/icons, input, and persistence. Reject missing
   frames, stale surfaces, lost input, crashes, or unexplained memory growth.
5. Compare matched interactions before/after, keeping cold launch and warm
   activation separate. Report sample counts, failures, p50/p95/max response
   latency, frame pacing, app CPU, and sampled memory. Small exploratory samples
   are screening evidence, not release-level tail-latency claims. Promote only
   a repeatable end-to-end improvement beyond baseline variability without
   material CPU/memory or correctness regression.

Temporal proximity between a touch and an unrelated frame is not proof of
causality or a usable response. Keep host and guest clock domains separate.
Confirm semantic completion visually; add missing identity hooks only where
necessary to explain the observed stall, not as an open-ended telemetry project.

**Immediate deliverable:** an interval-based graphics/interaction profile,
the dominant measured blocker, one targeted fix, and matched visual/latency
evidence. Until that evidence exists, responsiveness remains unresolved.

### Current Evidence

The [current non-bounded interaction capture](docs/phosh-graphics-priority-profile.md)
records a 41.97 s Settings launch-request-to-surface milestone interval, versus
61 ms of Metal execution and 18 ms of Metal copies in the surrounding capture
window. Unlock guest render-to-submit spans reached 557 ms. This is diagnostic,
not an isolated benchmark or a speedup claim.

Follow-up guest profiles identify GTK icon-shadow blur and musl startup symbol
hash/comparison loops. Scoped shadow removal and signed musl r10 are implemented
and regression-tested. The first unprofiled comparison is 34.93 s versus 33.82 s
for Settings, with 15.1% fewer guest instructions, but only a modest wall-clock
gain; the clean baseline sample is too small for promotion. r10 remains opt-in
and the disposable Simulator is restored to r8. See the report for the repeat
candidate and the watchdog-contaminated reverse baseline; do not claim a clean
ABBA cohort or solved responsiveness.

The missing Settings title bar also reproduces on the restored baseline. Next
is a navigation-surface on/off geometry and window-state check, not a guessed
loader rollback. The guest GTK/GStreamer/EGL/Gallium/LLVM dependency path remains
a concrete startup-cost target; shrinking it requires package-level dependency
and functionality validation, not simply setting a 'disable GL' variable.

The [bounded-service screen](docs/phase7-bounded-results.md) rejected promotion:
Phosh readiness averaged 92.0 s against 81.4 s for ordinary execution, despite
better synthetic loops. Its untimed smoke trace also records approximately
179 ms of Metal execution and 64 ms of Metal buffer-copy time across the whole
capture, versus hundreds of milliseconds in individual guest render-to-submit
spans. Those mixed-workload totals are a triage clue, not a causal interaction
profile or a performance gain. Investigate guest frame production and app
startup first; remeasure on the non-bounded path before choosing a fix.

## Historical Executor Progress

The phase history below is retained for provenance. Its historical "in progress"
and "next phase" statements do not override Priority 1 or authorize new work.

Status: active plan. Phase 1's reviewed synthetic-control work and Phase 2's
execution/invalidation design plus current-boundary regressions are complete.
Phases 3-5's isolated register/scalar-memory gadgets and bounded chaining pass
their offline gates. Phase 5 now has two accepted repeat cohorts. Phase 6 is
in progress: sampled-workload-guided shifts, logical masks, scalar addressing,
pairs, indirect branches and conditional selects/compares
have isolated implementations; end-to-end value is still unproven. Phase 7 now
has an opt-in VM adapter and a passing Simulator functional smoke test; matched
performance and default-promotion gates remain open.
See [hot-form results](docs/phase6-hot-work-results.md) and the
[scalar-addressing follow-up](docs/phase6-addressing-results.md) and
[pair follow-up](docs/phase6-pair-results.md) and
[indirect-branch follow-up](docs/phase6-indirect-results.md). No assembly
executor has been promoted to the app default. Phase 6 also fixes BLR x30 target/link
ordering in both shared C execution handlers, with Swift regression coverage.
The [short-entry follow-up](docs/phase6-entry-results.md) measures 5-10% less
median wall time for four-instruction scalar calls after inlining preparation.
Longer scalar/chain results remain mixed; no app-level gain is established.
The [conditional follow-up](docs/phase6-conditional-results.md) isolates entry
preparation in one binary, adds the sampled conditional operations with
independent flag checks and measures 69-78% less wall time on those synthetic
loops. Existing-path controls remain close but include a 2-3% short-chain
slowdown; production integration and Phosh gains are still unproven.
Phase 4 also corrects a shared C
leaf-permission bug, verified by the Swift suite and a Simulator smoke test.

Current progress: the fresh cohort completed 704 samples across 64 cells with
11 rounds per cell and passed all load gates. Independent review supports
ranking repeated short-invocation work ahead of the tested validation/statistics
controls. See [clean cohort results](docs/phase1-clean-cohort-results.md).
This closes Phase 1's bounded decision gate, not exhaustive handler/helper cycle
allocation, full-system safety or UI performance. Earlier failed-cohort evidence
remains excluded in [attribution results](docs/phase1-attribution-results.md).
Established C stays enabled; existing boot/UI measurements remain the baseline.

Phase 2 deliverables: [execution contract and state diagram](docs/phase2-execution-contract.md)
and [adversarial test matrix/results](docs/phase2-test-matrix.md). The contract
retains the threaded C path, precise exits, per-instruction validity guards and
current event-service cadence. Added 126 boundary scenarios plus null-input
checks; runtime regressions pass in optimized and UBSan builds, standalone
differential tests pass in optimized/unoptimized builds, and seven Swift bridge
tests pass. New assembly ABI, longer-window and full-system promotion gates are
explicitly pending implementation, not claimed as tested by Phase 2.

Phase 3 deliverables: [isolated gadgets](experiments/phase3/README.md) and
[results](docs/phase3-gadget-results.md). 82,370 cases pass in optimized/UBSan
builds; the final 600-sample cohort shows guarded register-only execution beating
both C core controls on the tested loops. No Phosh improvement is claimed and
no app integration/default change is made. Live unwind, arm64e, mutable-cache
lifetime and event-service integration gates remain open.

Phase 4 deliverables: [validated RAM gadgets and results](docs/phase4-memory-results.md).
The isolated scalar-memory subset passes optimized/UBSan differential, helper,
permission and SMP tests. Two final 540-sample cohorts beat both C core controls
on hot RAM; the 669-test Swift suite passes. A discovered EL0 leaf-permission
bug was fixed in the shared C walker and checked through a Simulator boot,
Phosh unlock and Settings smoke test. Assembly is still not linked into the app.
ASan startup is blocked by the host toolchain; register-only overhead and full
VM integration remain explicit limits, not hidden behind memory throughput.

Phase 5 deliverables: [bounded chaining and proof reuse](docs/phase5-chaining-results.md).
The owner-pinned block graph passes optimized/UBSan lifetime, exact-budget,
service-boundary, self-modification and shared-TLBI tests. Per-instruction
validity checks remain. Two accepted identical-source cohorts contain 960
throughput and 808 event samples: at windows >=64, chaining uses 26-43% less
median wall time than guarded assembly block returns, and event-service p95 is
1 microsecond in both modes. All declared comparison gates pass. Short calls
remain slower through the chain API; the extra graph footprint is documented.
Earlier rejected cohorts remain excluded. This closes the bounded offline
Phase 5 gate, not full-system promotion. App defaults remain unchanged.

## Objective

Make Alpine Linux + Phosh responsive on Pinecone's full-system ARM64 emulator,
including application launch, touch, scrolling and text input. Improve useful
guest execution per unit of host CPU time without sacrificing correctness,
two-vCPU safety, memory limits or observable failures.

This plan supersedes the performance priorities implied by the historical
[bring-up roadmap](docs/roadmap.md), not the project's broader scope. It does
not replace Linux with syscall emulation, introduce QEMU as a dependency, enable
Swift instruction fallback, or assume JIT/hypervisor access on iOS.

## Evidence and Constraints

The [October benchmark](docs/executor-benchmark-2026-10-28.md) is the baseline:

| Measurement | Established C | Register prototype | Prototype + scalar memory |
| --- | ---: | ---: | ---: |
| Phosh readiness, median of three boots | 62.3 s | 69.0 s | 78.0 s |
| Arithmetic loop, median | 5.410 ms | 16.290 ms | Not separately sampled |
| Memory loop, median | 8.019 ms | 8.020 ms | 20.433 ms |
| Settings launch, one trial | 32.7 s | 30.0 s | 36.1 s |
| Firefox local page, one trial | ~228 s | ~251 s | ~316 s |

All nine boot readiness samples had zero fallback on both vCPUs. Firefox's test
button produced no visible response during 89-101 seconds of observation in
any mode. That is an unresolved correctness/responsiveness failure, not a
successful latency measurement. These are Simulator results, not iPhone results.

The badge counts the primary vCPU only. Combined work was roughly 2.8B steps;
875M versus 1.8B on the badge does not establish a twofold efficiency difference.
The current established C executor already uses computed-goto dispatch and
semantic fast paths. The experimental path is a hybrid subset, not a complete
replacement. Its measured slowdown does not disprove all threaded designs.

Keep explicit runtime selections at `PINECONE_THREADED_PROTOTYPE=0` and
`PINECONE_THREADED_MEMORY=0`, together with `PINECONE_ASSEMBLY_EXECUTOR=0`,
for the baseline. Audit actual build/runtime defaults
rather than relying on older documentation. Keep two vCPUs unless a separately
identified experiment changes that variable.

## What the Reference Contributes

[iSH ARM64](https://github.com/Wind0ws11Aero/ish-arm64/blob/master/README_arm64.md)
describes a userspace Linux emulator with precompiled assembly gadgets, compact
operand streams, block linking and inline TLB access. It does not boot a Linux
kernel and explicitly excludes GUI support. Its performance claims are not
Pinecone measurements or evidence of Phosh compatibility.

Its [assembly definitions](https://github.com/Wind0ws11Aero/ish-arm64/blob/master/asbestos/guest-arm64/gadgets-aarch64/gadgets.h)
show a dedicated stream pointer, CPU/TLB pointers, a short load-and-branch
dispatch, and inline memory lookup. Most guest registers still live in memory.
Borrow the execution-design ideas, not a claim of automatic near-native speed.
Before importing any code, pin the source revision and review its license and
attribution requirements. No source import is authorized by this plan alone.

Pinecone must additionally preserve privileged execution, precise faults,
translation permissions, MMIO, interrupt deadlines, shared-memory semantics and
cross-vCPU invalidation. The reference's userspace memory model is not a drop-in
replacement for those contracts.

## Sequence and Ownership

Priority 1 owns the critical path. The roles below support that work; historical
executor phases no longer proceed independently of interaction evidence:

- Interaction/graphics owner: capture the failing Phosh interaction, attribute
  the guest-to-display path, and implement the dominant targeted fix.
- Executor owner: paused unless that profile identifies CPU/memory/scheduler
  work on the interaction's critical path; then one scoped change at a time.
- Reviewer/test owner: correctness contracts, evidence quality and promotion.

These are roles, not already-running agents. Do not run competing benchmarks
or have multiple workers change the same execution/synchronization boundary.
Phase 7 integrates only changes that pass their individual gates.

## Phase 0: Freeze and Repair the Measurement Contract

- Capture app/kernel/rootfs hashes, source state, compiler flags, executor flags,
  two-vCPU configuration and guest package versions. Preserve the user's disk.
- Reuse `scripts/benchmark-simulator-executors.py` on a disposable Simulator.
- Separate boot, decode/preparation, warmed execution, cold app launch and warm
  app activation. Keep first-run browser setup distinct from steady-state use.
- Record primary and secondary counts, wall time, host CPU seconds, memory,
  prototype eligibility, side exits, helper calls and checkpoint counts.
- Make browser completion depend on a recorded semantic result, and distinguish
  observer timeout from guest timeout. Retain failed attempts and raw videos.
- Update the acceptance protocol for the current tap-to-unlock screen. Retain
  historical swipe tests separately; do not silently relabel old cohorts.
- Validate the input driver's actual contact duration and coordinates. A tool
  click, injected event or unrelated new frame does not prove guest handling.

Exit gate: a repeatable workload manifest and a baseline run with known input
semantics, stable identities and explicit instrumentation overhead.

## Phase 1: Explain the Prototype Regression

Inspect `ARM64VizThreadedPrototype.c`, its generated ARM64 and the established
executor using the same compiler, optimization and workload configuration.

- Attribute time to handler bodies, dispatch, PC/state writes, budget updates,
  generation validation, atomics, memory helpers and block entry/exit.
- Measure runtime handler cost separately from operand preparation and cache
  lookup. Include current semantic fast paths in the production comparison.
- Use controlled diagnostic variants to isolate costs; variants that omit
  correctness checks must remain offline experiments, never installed defaults.
- Compare emitted code size and operation-stream footprint as well as cycles.

Exit gate: ranked measured costs, annotated assembly and a specific hypothesis
for each proposed change. Tail calls alone are not a performance explanation.

## Phase 2: Define the Execution and Invalidation Contract

Status: design/current-boundary gate complete, 2026-10-29. Source review and
executable checks are recorded in the linked contract and matrix; this is not
independent certification of a future executor. No runtime behavior changed.

Write the contract before reducing checks or caching architectural state:

- Define host-register ownership, entry/exit ABI, stack alignment, platform
  reserved registers, flags, vector state, helper clobbers and unwind behavior.
- Define exact guest PC, completed-step count and architectural state at every
  fault, unsupported-subset exit, interrupt, deadline and helper transition.
- Specify code/translation generation ownership, publication ordering, block
  lifetime and reclamation while another vCPU executes or invalidates code.
- Identify where validation may be amortized and the maximum permitted delay.
  Preserve guest-required visibility for executable writes, TLBI and barriers.
- Define the event/deadline polling bound. Longer runs must not starve input,
  device work, host cancellation or timer delivery.

Exit gate: reviewed state-machine/invariant document and adversarial tests for
the boundaries above. No global removal of validation or synchronization.

## Phase 3: Build a Minimal Assembly-Gadget Executor

Status: bounded offline subset gate complete, 2026-10-29. See the linked results
for comparison scope, preparation/footprint costs and unimplemented integration
gates. The established and threaded C paths are retained.

- Add an opt-in, host-ARM64-only experiment with precompiled assembly handlers;
  never generate executable code at runtime.
- Start with moves, integer arithmetic, comparisons and branches needed by the
  existing microbenchmarks. Use a compact decoded stream and explicit register
  conventions. Specialize widths, flags, operands and SP/XZR semantics.
- Keep stream/CPU pointers and bounded execution state resident where useful.
  Do not assume all guest registers can map directly to host registers.
- Materialize precise architectural state at the Phase 2 boundaries. Retain
  the established C executor for ineligible blocks and reference comparisons.
- Verify stack depth and emitted dispatch; account for decode cost and cache
  size. Do not infer production speed from a standalone ADD loop.

Exit gate: differential state/step tests pass and repeated arithmetic/branch
benchmarks beat established C with a gain larger than measurement variability.
Otherwise stop expansion and revisit the design.

## Phase 4: Inline the Validated RAM Fast Path

Status: bounded offline scalar subset gate complete, 2026-10-29. See
[results and limitations](docs/phase4-memory-results.md). No executor promotion
or end-to-end performance claim; the next implementation phase is Phase 5.

- Add scalar loads/stores using the existing translation contract, with inline
  tag/context/permission checks and a direct host pointer on a proven RAM hit.
- Preserve address-space identity, access type, translation epoch, applicable
  privilege/access controls, mapping lifetime and cross-page boundaries.
- Preserve dirty/code-write tracking, shared-surface observation and required
  exclusive-monitor interactions. Do not treat every writable page as plain RAM.
- Side-exit precisely for MMIO, misses, faults, observers and unsupported access
  forms. Keep the authoritative walker/device paths; avoid duplicate semantics.
- Test read-only pages, unaligned and cross-page accesses, invalidation during
  execution, remapping, code writes and concurrent two-vCPU access.

Exit gate: memory differential/stress tests pass and repeated hot-RAM workloads
beat the established path without weakening any observation or fault contract.

## Phase 5: Amortize Dispatch and Validation Safely

Status: bounded offline gate complete; see the
[accepted repeat cohorts and limitations](docs/phase5-chaining-results.md#accepted-cohorts).

- Chain validated blocks using the Phase 2 lifetime protocol. Keep entry,
  revalidation and reclamation visible in diagnostic counters.
- Batch budget/accounting work only where exact side-exit reconstruction is
  proven. Check interrupt/deadline state at a documented bounded cadence.
- Cache validation proofs at the appropriate code-page/context granularity;
  invalidate them on the required writes, mappings and synchronization events.
- Measure the tradeoff between longer chains, code/data cache footprint and
  worst-case event latency. Throughput gains cannot hide starvation.

Exit gate: self-modifying-code, TLBI, interrupts, cancellation and concurrent
reclamation tests pass; both throughput and event-service measurements improve
or remain within the predeclared nonregression limits.

## Phase 6: Expand Only Into Measured Hot Work

First batch implemented in the isolated experiment: shifted ADD/SUB, shifted
and inverted logical-register forms, and logical-immediate masks. Optimized and
UBSan suites pass, including exact SP/XZR and cross-block service boundaries.
Two accepted synthetic hot-form cohorts do not close this phase's exit gate.
The next batch adds scalar unscaled/pre/post-index and register-offset memory,
including sign-extending loads, with decode-selected writeback handlers.
Following batches add scalar LDP/STP, LDNP/STNP and LDPSW with exact pair
fault/writeback exits, then BR/BLR/RET using owner-pinned target ranges and the
existing chain service gates. The new C reference regression independently
checks BLR x30 source-before-link semantics. Two accepted branch cohorts and
two pair cohorts now measure the branch-capable binary. Existing scalar
controls still show small slowdowns/variation (up to 4.7% in one short-entry
cell), so zero regression and end-to-end promotion are not established.
The subsequent entry-cost pass removes a measured preparation call from the
standalone wrapper, preserves the chain/helper preparation boundary and fixes
the dispatch region's alignment. Final repeated short scalar calls improve
5-10%, but longer-window controls still include slower cells. The detailed
[entry report](docs/phase6-entry-results.md) preserves all iterations and leaves
the broader performance gate open; this is not an app default change.
The next batch adds all W/X conditional-select variants and register/immediate
CCMP/CCMN. Three same-binary entry cohorts confirm the preparation benefit
without the earlier repeatable long mixed-loop slowdown. Optimized/UBSan
conditional tests and two throughput cohorts pass; existing handler offsets
are preserved by appending the new family. An opt-in VM adapter and actual
boot/unlock/application comparisons are now the next meaningful integration
milestone, not a default switch based on synthetic throughput.
Unprivileged accesses and constrained-unpredictable writeback overlaps still
exit before execution. Remaining sampled gaps include bitfields and other
arithmetic/privileged forms. Capture better isolated workload
windows before ranking vector/FP expansion; current retained prefixes are not
a complete retired-instruction histogram. Production integration remains gated.

- Profile actual Phosh, Settings and Firefox traces after the earlier phases.
- Prioritize dominant operand forms, pairs, branches and vector/FP operations,
  not an indiscriminate rewrite of every instruction handler.
- Consider fused sequences only with exact original-instruction accounting,
  precise faults and bounded interruption. Preserve FP rounding/NaN behavior,
  atomics, barriers and memory-order semantics.
- Use host NEON where it exactly implements the guest operation; retain tested
  native C handlers where it does not. Avoid application-specific byte patches.

Exit gate: new coverage has differential tests and demonstrable end-to-end value.
Higher eligibility percentages alone do not count as success.

## Track U: Restore Reliable Interactive Applications

Start after Phase 0; do not wait for assembly integration.

1. Trace one identified tap through host capture, virtio queue/IRQ, Linux input,
   Wayland delivery, Firefox handling, surface damage and presentation. Identify
   the first missing or delayed transition. Do not subtract unrelated clocks.
2. Test input delivery independently of rendering using a minimal Wayland/input
   diagnostic client. Establish whether Firefox's event callback runs even when
   its visible button status does not change.
3. Sample guest threads and host execution during launch and the failed tap.
   Distinguish runnable CPU work, blocking waits, scheduler delay, renderer/IPC
   stalls and graphics synchronization. Test hypotheses rather than assuming
   dispatch overhead or low RAM explains everything.
4. Fix the demonstrated fault/bottleneck and add a regression test. Keep normal
   browser sandboxing and security settings; do not suppress errors to pass.
5. Verify button acknowledgement, guest keyboard focus, exact typed text,
   scrolling and returning Home, then repeat Phosh unlock and Settings launch.

Exit gate: repeatable functional input success before reporting latency gains.
Keep a local fixture to separate target downloads from browser execution;
record any remaining background browser networking.

## Phase 7: Integrate, Measure and Promote

The [opt-in VM adapter](docs/phase7-assembly-integration.md) now links the same
assembly source used by the offline harness. It uses a bounded cache and the
existing C execution/checkpoint loop; unsupported blocks stay in native C.
The long-running offline assembly chain is not yet a production VM path.
Assembly remains disabled by default pending end-to-end validation and cohorts.
The opt-in Simulator smoke test now passes shell, rendered lock screen, ordinary
unlock, Home, Settings and return Home with zero Swift fallback. The final
diagnostic boot reported readiness at 98.281 seconds; this is not a matched
speedup result against established C. Preparation churn and bounded-entry costs
remain, and the multi-run performance/promotion gate is still open.

Each integration change gets native tests, a Release build and a Simulator
smoke test: shell, Phosh lock screen, ordinary unlock, Home, Settings and return.
Memory/graphics changes additionally require text/icon and framebuffer checks.
Run Firefox input checks once track U supplies a reliable passing baseline.

For a promotion candidate:

- Run at least five matched alternating boots per mode, with no concurrent
  compilation, video analysis or other test VMs. Retain all failures.
- Collect at least 20 valid attempts per applicable interaction cohort; report
  failures, median, tail observations and maximum, not a single best run.
  Treat small-sample p95 estimates cautiously and preserve raw distributions.
- Separate cold/warm app launch; capture host CPU seconds, resident memory,
  executable/cache allocation growth and guest memory pressure.
- Predeclare acceptance budgets using the Phase 0 baseline. Require a repeatable
  improvement on a user-visible bottleneck and no unexplained deterioration
  beyond observed run-to-run variation elsewhere. Do not tune thresholds after
  seeing results; expand the sample when the outcome is ambiguous.
- Require zero Swift fallback and no new crashes, text corruption, lost input,
  stale-code execution, disk corruption or unbounded memory growth.
- Run separate physical-device/thermal/memory validation before promoting for
  iPhone use, with user authorization. Simulator wins are insufficient.

Keep each executor selectable for diagnosis. Stop promotion on a failure and
disable only the experimental path; do not revert unrelated work or change the
guest image, graphics pipeline and executor simultaneously to conceal a result.

## Immediate Deliverables

### Phase 7 Cache and Interaction Work Order

Assigned on 2026-10-29; all four bounded handoffs are delivered. Manager review
and local regression reruns passed on 2026-10-29. This completes preparation,
not production integration, measured improvement or the promotion gate.
The manager owns integration, code review and serialized Simulator validation.

| Owner | Bounded deliverable | Write scope |
| --- | --- | --- |
| Lagrange | Opt-in assembly-cache hit/miss, eviction, preparation and footprint diagnostics; focused tests and retention recommendation | Block cache, new private diagnostics header and standalone tests |
| Kierkegaard | Explicit assembly/baseline flag selection, provenance and failure-preserving benchmark harness tests | Simulator benchmark harness, new tests and benchmark protocol |
| Mendel | Production chaining contract, integration plan and targeted boundary tests | New chain plan and standalone tests; no production executor edits |
| Ohm | Identity-aware interaction trace analysis and missing-hook audit | New trace-analysis scripts/tests and attribution report |

Initial handoff review (before integration below):

- Cache diagnostics compile out of default hot paths. Optimized and UBSan
  fixtures reproduce FIFO eviction of a reused program while another slot is
  empty. Test free-slot-first insertion at unchanged capacity as the first
  retention candidate; replacement policy is not changed yet. Per-vCPU
  owner-thread diagnostic enable/export still needs integration.
- The [benchmark harness protocol](docs/phase7-benchmark-protocol.md) and its
  43 tests pass, with explicit executor flags and retained failures. No matched
  Simulator cohort has run.
- The [chaining contract](docs/phase7-chain-integration-plan.md) passes optimized
  and UBSan checks, including 324 budget cases and production checkpoint/PLT
  boundaries. Its timer/IRQ witnesses demonstrate why offline long chains
  cannot replace the single-block VM adapter without native boundary service.
  Production long-run integration and two-vCPU reclamation remain pending.
- The [interaction analyzer](docs/phase7-interaction-attribution.md) passes 31
  tests. Existing saved traces cannot bridge host event identities to guest
  handling or prove semantic response; missing hooks remain implementation
  work, not evidence of a diagnosed guest stall.
- The manager reran all 672 Swift tests successfully. No Simulator install,
  boot/unlock smoke test or performance measurement was performed for these
  handoffs. No executor defaults or cache replacement policy were changed.

### Cache Integration Follow-Through

The [cache integration report](docs/phase7-cache-integration-results.md) records
the completed O(1) free-slot-first/FIFO fix, owner-published per-vCPU diagnostics,
673 passing Swift tests, native optimized/UBSan checks and a successful
lock/unlock/Home/Settings/return functional smoke test. Detailed cache counters
remain compile-time opt-in; no executor defaults changed.

The same-build two-pair screening comparison failed the assembly promotion
gate: established C averaged 73.177 seconds to guest readiness, assembly
113.655 seconds (55.3% slower), with 45.4% more observed app CPU time. All four
runs had zero Swift fallback. This is not a before/after cache-policy comparison
or the full promotion cohort; do not claim the empty-slot fix accelerated Phosh.

Separate attribution observed 56.4M preparations, including 51.7M repeats in
the same decoded-entry lifetime, and zero evictions while slots were free.
About 8.8 seconds accumulated inside preparation across both vCPUs; freeing,
validation and execution are excluded. Assembly calls still average roughly
2.67 instructions. Next investigate bounded retention/admission and reuse of
decoded operands, alongside the pending native boundary-service/chaining work.
Track U's missing identity hooks and the full promotion gates remain open.

### Dispatch And Retention Follow-Through

The [dispatch/retention report](docs/phase7-dispatch-retention-results.md)
tracks C superblock precedence, single preparation per dispatch, bounded hot
program retention and slice-level counter publication. Correctness checks pass
(674 Swift tests plus native optimized/UBSan matrices). Two before/after Release
pairs reduce assembly readiness from 121.648 to 84.913 seconds (30.2%) and
observed app CPU from 117.57 to 80.43 seconds (31.6%). The current-C control is
still faster at 68.722 seconds. Candidate RSS samples are higher than baseline;
memory attribution and interaction-latency gates remain open. Lock/unlock/Home/
Settings/return smoke passes, but Settings startup is still slow. No default
promotion or measured touch-latency improvement is claimed.
The separately tested service-chain API is default-off and unwired. True
resident-register multi-block execution and production lifetime enrollment
remain open, not completed by that API.

### Native ALU Follow-Through

The [ALU report](docs/phase7-alu-results.md) records a narrowed no-flags
shifted-register ADD/SUB fast path: roughly 50% lower thread CPU cost in the
affected synthetic mapped-C loops, with 3.49M arithmetic regression cases and
674 Swift tests passing. Shared-code guard coalescing and broader ALU changes
were rejected after measured regressions. This is not a measured Phosh latency
improvement or permission to promote the assembly executor.

### Production Chaining Follow-Through

The [production chaining report](docs/phase7-production-chaining-results.md)
records an independently opt-in, cache-owned graph adapter and resident assembly
entry with native service at every visit. Strict residency, bounded storage,
terminal helpers, timer accounting, and shared invalidation are covered by
new native tests. Chaining can replace only wholly covered ordinary C traces;
mixed traces and semantic accelerators retain C execution. Both executors stay
selectable, and chaining defaults off. This integrates bounded multi-block
execution, not all-guest-register residency or a performance promotion. Consult
the report for final test, smoke, sanitizer, and measurement outcomes.

The [boundary cost follow-through](docs/phase7-boundary-cost-results.md) isolates
repeated graph validation and reduces candidate synthetic execution cost by
approximately 22-34% across the screened block lengths. Chaining still loses
to ordinary execution and remains off. The same work fixes instruction-translator
remapping, makes the contention regression deterministic, and validates with a
working installed LLVM ASan runtime. The next experiment must amortize visit
service under an explicit deadline/invalidation contract, not merely add caches.

The [bounded-service experiment](docs/phase7-bounded-results.md) implements
resident graph execution with exact timer/helper settlement, transactional
optional preparation, page-generation guards, and separate coverage counters.
Synthetic native loops improve, but the same-binary two-pair Phosh screen is
13.1% slower at readiness and uses 33.3% more observed app CPU than ordinary
execution. Bounded coverage is below 1% of native work. Keep chaining off;
profile admission/validation and useful work density before widening enrollment.
This is a completed experiment, not a responsiveness milestone or promotion.

Deferred executor sequence (not the active priority; gates remain open):

1. Integrate diagnostics and establish a same-build baseline/assembly comparison.
   Keep attribution profiling separate from clean timing cohorts.
2. Use the observed cache churn and preparation costs to choose bounded hot-block
   retention or decoded-operand reuse changes. Do not enlarge caches blindly.
3. Integrate bounded assembly chaining only after its lifetime, invalidation,
   exact-exit and event-service contracts pass production-path tests. Preserve
   existing C semantic accelerators.
4. Expand only the remaining measured hot instruction forms. In parallel, use
   Track U evidence to address input/application stalls that dispatch cannot fix.
5. Run Phase 7's matched boot and interaction promotion cohorts. Keep the
   established C path as reference; no default promotion on synthetic gains.
6. Consider a versioned persistent decoded-code cache only if preparation is
   still significant. Never persist raw host pointers or stale guest state.

After each integrated implementation change, run native regressions and a
Release Simulator smoke test through shell, Phosh, tap unlock, Settings and
return Home with zero Swift fallback. Do not run builds or competing VM tests
during timing cohorts. Preserve the user's guest disk; use a disposable
Simulator for seed-restored benchmarks. Physical devices remain out of scope.

- [ ] Phase 0 workload/provenance and input-driver validation.
- [x] Phase 1 generated-code and cost-attribution report for the tested synthetic controls.
- [x] Phase 2 execution/invalidation contract and existing-path boundary test matrix.
- [ ] Track U first failing-event trace and targeted fix plan.
- [x] Phase 3 isolated arithmetic/branch assembly proof of concept and bounded benchmark gate.
- [x] Phase 4 isolated scalar RAM extension, shared-walker correction and bounded benchmark gate.

No near-native guarantee or fixed speedup is implied. Completion means a
measured reduction in actual interaction/application latency with preserved
correctness, not simply more native instructions or a new dispatch mechanism.
