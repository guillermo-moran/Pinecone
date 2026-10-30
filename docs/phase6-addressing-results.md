# Phase 6: Scalar Addressing

Status: isolated experiment, **not installed or promoted**. No Swift, production
C executor, guest image, graphics or scheduling changes are part of this batch.
The existing app remains on two vCPUs and the established C path. Phase 6's
end-to-end acceptance gate is still open.

## Implemented

- Scalar unsigned-immediate and unscaled loads/stores, including signed offsets.
- Pre/post-index loads/stores with successful-access-only base writeback.
- Register offsets using UXTW, LSL, SXTW or SXTX, with optional width scaling.
- Sign-extending byte/halfword loads to W or X, and word loads to X, across the
  supported addressing modes. SP/XZR roles and 32-bit result clearing are explicit.
- Compact address metadata in the existing 48-byte prepared operation; no new
  per-operation allocations or host executable pointers.
- Immediate and register-offset entries share the same RAM proof/access body.
  Writeback and signed-result handlers are selected during preparation.

The fast path keeps the prior TLB tags, context epochs, bounds, alignment,
permission-derived entries, observation checks, dirty tracking and code-store
checks. A helper transition remains terminal. It captures address/writeback
before callbacks, commits state once on success, and retires nothing on a fault.
Post-store code accounting does not repeat an already completed write.

LDTR/STTR remain excluded because they require an unprivileged access check.
Pre/post-index Rt/Rn overlaps are constrained-unpredictable and remain excluded
except the distinct SP/XZR case. Reserved and vector forms do not enter this
scalar path. Pairs, atomics and additional control-flow forms are separate work.

## Correctness

Optimized and UBSan builds pass all prior register, memory, ABI, invalidation,
chain and disabled-build suites. New checks include:

| Coverage | Cases |
| --- | ---: |
| Address modes, widths, sign, SP/XZR, offset/result aliases, wrapping addresses, hot/cold RAM, observers, unaligned and cross-page access | 2,432 |
| MMIO success/failure, writeback, callback retirement and unwind | 128 |
| Translation/permission faults, pending TLBI, code writes and already-completed-store accounting | 64 |
| Cross-block pre/post/register-offset execution at exact service budgets | 129 |

Six explicitly excluded encodings also verify zero retirement and unchanged
CPU state. Comparisons include all CPU fields, RAM bytes and dirty ranges where
applicable. MMIO writeback/fault expectations are also checked independently of
the C reference. Host Clang confirms the new benchmark encodings.

The optimized/UBSan logs, emitted disassembly, unwind records, generated offsets
and reclassified capture are retained under
`experiments/phase3/results/phase6-address-final-validation/` (ignored artifacts).
UBSan instruments C, not assembly.
This does not claim ASan/TSan, arm64e or physical-device validation. The
deterministic post-store helper test is not an exhaustive concurrent code-page
enrollment race test; prior concurrent publication tests remain in the suite.

## Profile Reclassification

Reused the prior saved Phosh/Settings/Firefox-observed captures, rather than
claiming new application timings. Fully eligible **retained prefixes** change:

| Capture | Primary before/after | Secondary before/after |
| --- | ---: | ---: |
| Phosh | 18 / 21 | 17 / 20 |
| Settings | 16 / 19 | 11 / 16 |
| Firefox-observed | 18 / 22 | 19 / 20 |

Each column contains only 32 retained prefixes of at most four instructions.
The capture-window and approximate-sampling limitations in the first Phase 6
report still apply. Eligibility does not establish execution share or UI speed.
Load/store pairs remain the most frequent first miss in the Firefox-observed
prefixes, followed by indirect branches and conditional operations.

## Performance Method

The first implementation added a writeback flag check to every scalar access.
The matched existing-memory control showed most assembly cells about 1-2%
slower. That implementation was superseded by decode-selected writeback handlers;
ordinary memory handlers now contain no writeback test. The intermediate
measurements are retained, not presented as the final candidate.

The final emitted assembly `__TEXT` is 35,528 bytes versus 24,516 before this
batch. Specialization trades 11,012 additional code bytes for avoiding work on
every ordinary access. Prepared-operation size stays unchanged. Emission checks
still allow exactly two terminal C helper calls and no x18 use or indirect calls.

Existing-memory controls use the preserved pre-change executable with SHA-256
`a56305af662e91817c6df2e39e22900e549292a17c091fbeb8bb2237ea7c8ade`, also recorded by
the previous Phase 6 accepted reports. The measurement runner's source hashes
are snapshots at collection time, not build attestations for that older binary.

The new-form suite compares guarded assembly to the direct C core over three
bounded loops, four windows and 15 interleaved rounds: 360 samples per cohort.
Full CPU and RAM equality is checked outside timing. The old C prototype is
ineligible for these forms and is excluded, not silently completed elsewhere.
Pinecone is paused by verified process identity and resumed in `finally`; host
load checks bracket collection. None of this is an in-app latency measurement.

## Final New-Form Results

Two identical-binary cohorts, `phase6-address-final-1` and
`phase6-address-final-2`, pass the runner's completeness/load checks and CPU/RAM
comparisons: 720 samples total. Both reports confirm the Simulator was resumed.
The optimized executable SHA-256 is
`c20a9d2ef7fa85975a2621392c0c44e76ed07723b56af09c0826f004305fd7dd`.

The table shows assembly / direct-C median wall-time ratios for each cohort.
Lower is better; all cells execute 1,048,576 guest instructions per sample.

| Loop | Window 4 | Window 64 | Window 256 | Window 4096 |
| --- | ---: | ---: | ---: | ---: |
| Unscaled load/store | .392 / .399 | .316 / .320 | .308 / .306 | .299 / .296 |
| Pre/post-index load/store | .398 / .399 | .321 / .319 | .310 / .308 | .302 / .300 |
| Register-offset signed-byte load/store | .394 / .390 | .317 / .308 | .301 / .303 | .288 / .287 |

These loops use 60-71% less median wall time than the direct C reference. This
is warmed isolated execution, not preparation cost, production-dispatch speed,
whole-guest instruction coverage, app launch latency or touch responsiveness.

## Existing-Path Control

The initial final-candidate control (`phase6-address-final-control`) against
`phase6-address-baseline` ranges from 0.7% faster to 4.0% slower across the 12
existing assembly memory cells. It does not establish a universal improvement.

The reverse-order candidate (`phase6-address-final-control-2`) passes the
runner's before/after load checks but is unsuitable for fine timing claims:
the load64/window4096 interval stalls across **all three** interleaved modes.
Assembly median is 5.689 ms (4.124 ms CPU), versus 2.966 ms in the first run;
direct C reaches 155.219 ms wall for a 16.745 ms CPU sample. CPU-time variation
also rises. This is evidence of transient interference, not proof of its exact
cause. The complete cohort is retained and excluded from no-regression claims;
individual samples are not cherry-picked. The runner's coarse load gate alone
is insufficient to certify a low-noise cohort.

The subsequent `phase6-address-final-control-3` against the repeated preserved
binary (`phase6-address-baseline-2`) passes collection checks, resumes Pinecone,
and does not reproduce that large stall. Existing assembly cells range from
2.7% faster to 2.7% slower. Selected paired medians, old / new:

| Loop/window | Old ms | New ms | Change |
| --- | ---: | ---: | ---: |
| load64/256 | 3.046 | 3.129 | +2.7% |
| load64/4096 | 2.965 | 2.948 | -0.6% |
| store64/4096 | 3.196 | 3.232 | +1.1% |
| mixed64/4 | 6.501 | 6.328 | -2.7% |
| mixed64/4096 | 3.982 | 4.038 | +1.4% |

The results are consistent with a small cost/noise band, not a demonstrated
zero-regression guarantee. In particular, load64/window256 is slower in both
clean comparisons. Code-layout/cache cost remains a plausible hypothesis, not
a measured cause. No statistical equivalence margin was declared before these
runs, so none is invented afterward. Keep this control issue open before
production promotion; the substantial new-form benefit does not erase it.

## Simulator Check

After all measurements, the existing Simulator shows the unlocked Home launcher
and the instruction badge reports fallback 0. This is a resume/display check,
not a fresh boot, new unlock gesture, app-launch test or experimental-executor
integration test. No install, disk reset or production runtime change occurred.

## Remaining Work

Next: load/store pairs, including partial-access faults and precise writeback,
then measured indirect/conditional control flow. A production cache/lifetime
adapter and matched end-to-end UI measurements are still required before any
app-default change. No Phosh speedup is claimed by this isolated expansion.
