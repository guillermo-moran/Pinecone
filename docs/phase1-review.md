# Phase 1 Review: Executor Regression

Status at this static-review handoff: investigations complete; controlled cost
attribution was still open. The subsequent
[clean timing cohort](phase1-clean-cohort-results.md) closes Phase 1's bounded
decision gate. This document preserves the original hypotheses and experiment
order, not a claim that all of them were confirmed. No runtime implementation
or guest-image changes were made by this static review.

## Reviewed Evidence

- [Dispatch and generated code](phase1-dispatch-analysis.md)
- [Validation and accounting](phase1-validation-analysis.md)
- [Scalar memory](phase1-memory-analysis.md)
- [Existing benchmark](executor-benchmark-2026-10-28.md)

Parent review verified the current source/header/build-script hashes against
`/tmp/arm64viz-phase1-dispatch.GtPQ5W/source-sha256.txt`, reran the selected
assembly-path counting script, and checked the wrapper, eligibility/superblock
gate, hot memory helper and benchmark fixtures against the reports. Saved
benchmark logs confirm superblock and checkpoint counts below. This is not an
independent proof of every selected assembly path or full-system correctness.

## Accepted Findings

| Finding | Evidence | Interpretation |
| --- | --- | --- |
| Prototype invocation is capped at one decoded block's instruction count | Native wrapper at `ARM64VizNative.c:13749`; four-instruction arithmetic fixture | Repeated entry/exit is the leading attribution hypothesis, not a measured percentage |
| Successful no-memory wrapper and guarded entry/exit contain 160 selected-path host instructions | Generated assembly and reproducible counting script; excludes handler and other callee bodies | Substantial recurring work; static instructions are not CPU cycles |
| 48 register handlers tail-branch without ordinary calls or stack references | Optimized assembly checks | Growing handler stacks do not explain the slowdown in this build |
| Prototype eligibility suppresses new established superblock composition | `ARM64VizNative.c:14833`; retained arithmetic log: 7,781 established superblock dispatches versus zero prototype | The integrated comparison includes execution-policy differences, not just dispatch style |
| Prototype validates at entry and after hot-path instructions | `TP_NEXT` and `tp_is_current` | Validation/state traffic is a separate attribution candidate |
| Both paths share inline hot RAM/TLB helpers | `ARM64VizGuestMemoryInternal.h` and call sites | A wholesale MMU rewrite is not justified by the memory-loop timing |
| Memory fixture has no attached shared guest-memory object | Fixture initialization | Shared-epoch contention, observer locks and native page walks cannot explain its steady-state regression |
| Memory checkpoint counts are 245 established and 247 prototype | Retained timing log | Consistent with initial read/write fills, not recurring slow exits; checkpoints are not executor-entry counts |
| Prototype operations occupy 80 bytes versus 32-byte decoded instructions | Compiler record layouts | Additional working-set cost is plausible, but cache misses were not measured |

The source-derived four-step arithmetic case implies about 250,000 prototype
invocations and 500,000 block/step statistics atomic updates per million guest
instructions. Capture these dynamically before assigning time to them. Some
prototype handlers are smaller than the established single-block handler paths;
the claim that every prototype instruction simply does more work is unsupported.
Those single-block assembly counts do not describe every superblock path taken
by the measured established executor.

## Corrections to Earlier Descriptions

1. Calling memory helper functions in C does not imply an out-of-line TLB lookup.
   The hot RAM helpers are already forced inline in both executors. A recurring
   store commit/invalidation call remains in this fixture in both modes; its
   different register-allocation/ABI impact is unmeasured.
2. "Computed-goto" was imprecise shorthand for the current established dispatch.
   The inspected source uses a switch targeting local labels, lowered by Clang
   to an indirect jump table. This is not a naive switch-versus-threading test.
3. The current hash manifest proves the inspected source identity, not its
   identity with the earlier discarded microbenchmark binaries. The installed
   app hash does not close that separate harness provenance gap.

## Remaining Phase 1 Work, in Order

1. Freeze a disposable source snapshot, compiler/build settings and binary
   hashes. Reproduce the two small existing benchmarks, not the entire boot/UI
   suite, and confirm full expected state and instruction counts.
2. Collect an untimed event ledger: executor entries, eligibility/program
   lookups, prototype steps, superblock/semantic steps, checkpoint calls, hot
   read/write successes, full-helper exits and commit/invalidation calls.
   Separate diagnostic instrumentation from timing runs.
3. In the fixed-code, single-thread offline fixture, sweep the prototype's
   invocation budget while preserving per-instruction validation and the
   checkpoint budget. This isolates repeated invocation work without also
   removing validation. Such a diagnostic is not a safe production policy.
4. At fixed invocation frequency, separately measure validation/accounting,
   statistics and warm-versus-cold preparation costs. Any omit-check diagnostic
   must remain outside the runtime checkout and has no concurrency claim.
5. If a material gap remains, examine store-call ABI effects and the lost
   superblock/semantic opportunity separately. Do not subtract unrelated loop
   totals and call the difference memory overhead.

Use at least nine alternating samples per arm without concurrent builds, test
VMs or profiling jobs. Keep original controls, failures and raw distributions.
Report changes in the executor gap, not just absolute improvements, and do not
assume overlapping experimental effects add linearly.

Exit deliverable: measured ranking of the major costs, annotated generated
code, reproducible artifacts and a bounded recommendation for Phase 2's
execution/invalidation contract. If a hypothesis fails, update the ranking;
do not advance directly to assembly implementation to avoid that result.

Established C remains the baseline. No validation removal, longer production
slice, executor default change or guest memory rewrite is approved by this
review. Firefox's failed input response remains a separate track U issue.
