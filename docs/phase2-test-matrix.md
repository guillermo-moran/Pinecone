# Phase 2 Test Matrix

Companion to the [execution contract](phase2-execution-contract.md).
Test names refer to current source, not planned coverage. Tests below exercise
the current C implementations; they do not establish correctness of an unwritten
assembly executor or longer production slices.

## Current Regression Coverage

| Boundary | Executable coverage | Limits |
| --- | --- | --- |
| Exact registers/PC/retirement and native side exits | `scripts/threaded-runtime-regression.c`: `compare`, `memory_compare`; standalone prototype differential harness | Current instruction subset, not all ARM64 or Android workloads |
| Widths, SP/XZR, exact budgets and hot RAM writes | `threaded-memory-continuation-regression.c`: `hot_differential` | 384 deterministic cases, selected forms |
| Null/zero/halted/stale/misaligned/outside entry precedence | `entry_precedence` (new) | 32 state/precedence combinations plus null arguments |
| Full-helper success/failure, cache clear/eviction and remap | `callbacks` | Includes side-effect-on-failure and one callback, no CPU writeback on failure |
| Self-modification and validation-to-entry races | `code_writes_and_entry_races` | Controlled publication; not exhaustive enrollment races |
| Pending TLBI and mapping replacement | `remap_and_pending_tlbi` | Owner-mediated remapping, not concurrent host RAM destruction |
| Journal catch-up and overwritten invalidation | `translation_journal_overflow` (new) | 63/64/65/129 publications; early ALL must not be lost. Does not test epoch wrap |
| Observed/exclusive/same-value stores, unaligned and cross-page accesses | `observations_and_faults` | Bulk-reader flag is synthetic, not a real GPU reader lifetime test |
| Peer invalidation during memory and register-only tails | `concurrent_shootdowns` | Two host owners, code plus four TLBI scopes. Detects exit, not exact publication-to-service latency |
| Native timer retirement boundary | `chain_deadlines` | 12 deadlines in instruction-driven timer mode; not host-clock latency |
| Changing instruction allowances, block interval and cancellation | `checkpoint_stop_and_resume` (new) | 90 cases, budgets around 16/64/256/4096, intervals 1/3/4096; stop at third callback, then resume exactly 17 instructions |
| Host checkpoint invalidates selected cache | `checkpoint_stop_and_resume` (new), existing `compare` mutation cases | Clear on every checkpoint; verifies no stale-pointer continuation or duplicated prefix |
| Precise fault prefix through Swift | `ThreadedMemoryFaultTests`: load/store failure tests | Existing production bridge, not speculative cached guest state |
| Host preemption/IRQ and signal lifetime | `HostPreemptionCheckpointTests`: five tests | Established native path; must be parameterized for a new executor before promotion |
| Enforced tail dispatch | `run-threaded-prototype.sh --verify` | Emitted current compiler output, not a hand-written veneer or device unwind test |

The continuation harness includes `ARM64VizNative.c` to exercise private runtime
integration in an isolated test executable. The new tests do not add test hooks,
flags or branches to the shipping runtime.

## Required Gates for Future Implementations

| Gate | Required adversarial test and acceptance |
| --- | --- |
| G1: Gadget ABI | Seed callee-saved GPR/vector state, host FPCR/FPSR, aligned SP and canaries. Return through every exit and a clobbering C helper. Assert preservation, exact guest state, bounded stack, unwindability and supported target/arm64e behavior. Fail closed on unverified targets. |
| G2: Longer-window event schedule | Compare step/block service points against current runtime for short loops, conditional branches, partial budgets and helper exits. Inject stop, touch-preemption, pending IRQ and host timer deadlines at each point. No extra service delay or acknowledgement merely by polling. |
| G3: Exit collisions | Fault plus stop/IRQ/deadline/invalidation in the same boundary. Preserve one callback and one recorded fault; no replay or lost prefix. Extend Swift bridge tests to each enabled executor. |
| G4: Code enrollment/publication | Controlled writer interleavings before fetch, during decode, after validation, before pin, and before dispatch on newly executable pages. Never publish a mixed or stale snapshot as current. Test ISB/cache-maintenance boundaries through established handlers. |
| G5: Lifetime and identity | Retire/evict/clear during callback, successor lookup and peer invalidation; force allocator address reuse and generation wrap. Old pins must not acquire a new identity. Teardown/remap waits for vCPU and real shared-surface readers. |
| G6: Translation and synchronization | Concurrent page-table changes plus each relevant TLBI/DSB/ISB sequence, ASIDs/EL changes, page permissions, journal overflow and wrap. Verify owner acknowledgement where required, not just eventual epoch mismatch. |
| G7: Memory observations | Real retained GPU/bulk readers, exclusives/atomics, same-value writes, dirty ranges and code notifications under two-vCPU contention. The initial register-only gadget path must side-exit before these operations. |
| G8: Full-system promotion | Same app/image/rootfs hashes and two-vCPU workload: boot, tap-to-unlock, Settings, browser semantic response. Compare wall time, host CPU, memory, input-to-frame distribution and fallback counts against baseline; retain failures. |

G1 is required before executing the Phase 3 experiment beyond an isolated test.
G2-G7 apply when the corresponding boundary changes; the unchanged authoritative
path remains in use until each relevant gate passes. G8 is required before a
default/runtime promotion. These are not checked off by synthetic speed results.

Phase 3 follow-up: the [register-only experiment](phase3-gadget-results.md) now
tests caller ABI preservation, precise subset exits and shared-token rejection.
It has no C-helper calls or mutable-cache integration; live unwind, arm64e and
the remaining boundary-specific/full-system gates above are still open.

## Reproduction and Results

Run from the repository root:

```sh
sh scripts/run-threaded-runtime-regressions.sh
sh scripts/run-threaded-runtime-regressions.sh --ubsan
AVZ_TP_REFERENCE_DIR="$PWD/Sources/ARM64VizNative" sh scripts/run-threaded-prototype.sh --test
AVZ_TP_REFERENCE_DIR="$PWD/Sources/ARM64VizNative" sh scripts/run-threaded-prototype.sh --verify
swift test --filter 'HostPreemptionCheckpointTests|ThreadedMemoryFaultTests'
```

The explicit reference directory prevents the standalone harness from silently
comparing against its historical `/tmp` reference snapshot. These are correctness
runs, not performance samples.

### Results: 2026-10-29

Host: Darwin ARM64, Apple clang 17.0.0 (`clang-1700.6.3.2`).

| Run | Result |
| --- | --- |
| Runtime `-O3` | PASS: 3,136 differential scenarios, 128 replacements, opt-out; all continuation groups pass |
| Runtime UBSan `-O1`, abort on first UB | PASS: same suites, no sanitizer findings |
| Newly added scenarios within both runtime runs | PASS: 32 entry combinations, 90 checkpoint/clear/stop/resume cases, four journal cases and null arguments |
| Standalone enabled `-O3` | PASS: 507,622 differential cases against current C source |
| Standalone enabled `-O0`, sibling-call optimization disabled | PASS: 507,622 differential cases |
| Standalone disabled | PASS: no execution/allocation, CPU unchanged |
| Dispatch verifier (also executed by `--test`) | PASS: 50 mandatory tail sites, 48 register handlers with indirect tail branches/no ordinary calls, two memory handlers with hot tails and terminal helpers; unsupported compiler mode rejected |
| Targeted Swift tests | PASS: five host-preemption tests and two threaded fault-prefix tests, zero failures |

The first test-development run failed to compile because the new test used a
singular TLBI enum suffix; corrected to the existing `AVZ_TLBI_VA_ALL_ASIDS`.
The next run exposed an overstrong test assertion that prototype steps equal all
retirement. A mid-block resume can select a one-instruction entry, which is
intentionally handled by established C. The test now verifies exact CPU/PC and
retired-prefix accounting while requiring prototype activity without claiming
every instruction used it. Neither correction changed production behavior.

Source identity for reproduction (SHA-256):

```text
scripts/threaded-memory-continuation-regression.c
c7f6d24cac51b7fc116c06cff457278da6f50539b9cfed6e802308fdcb5b82b3
scripts/threaded-runtime-regression.c
79545f80af49ce93c60fa231c049fd0b9b714afbcca1f88bdbf87c3f6a5fee41
scripts/run-threaded-runtime-regressions.sh
c57fdd8c5359155cc5ed39260f4f7404bfbd817c607f41c5067163107e5604c7
Sources/ARM64VizNative/ARM64VizNative.c
a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f
Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416
```

No Simulator reinstall, boot/UI benchmark or physical-device test was performed
for this docs/test-only phase. No ASan/TSan success is claimed by these runs.
The previous installed baseline remains untouched; there is no measured speedup
from Phase 2 itself.
