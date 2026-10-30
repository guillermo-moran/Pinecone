# Phase 4: Validated Scalar RAM Gadgets

Date: 2026-10-29. This extends the isolated Phase 3 experiment, not the installed
app's executor. The established C executor and two-vCPU defaults remain selected.
No guest image, scheduler cadence, graphics pipeline or Swift fallback changed.

## Implementation

- Eight specialized scalar unsigned-immediate handlers: load/store of 1, 2, 4
  and 8 bytes. SP/XZR and scaled offsets are decoded once.
- Inline proof of a normal RAM hit: access-specific TLB, virtual/context tags,
  translation generation, contiguous span, physical bounds, aligned host
  pointer and shared observation flags. Mapping metadata is captured once per
  invocation; shared epochs and observer state remain live atomic reads.
- Relaxed atomic-width host loads/stores; release dirty-page publication;
  local exclusive-reservation clearing after successful stores.
- Per-instruction shared code/translation validation remains enabled. A pending
  shared TLBI at entry executes zero instructions. Register-only tails still
  observe peer invalidation.
- All misses, MMIO, unaligned/cross-page accesses, observed writes, executable
  stores and faults use the existing C memory helpers. Detailed statistics and
  detached memory also conservatively use C. Success exits after exactly one
  retirement; failure leaves the faulting instruction unretired. Neither is
  retried as an unsupported instruction.
- Post-store code enrollment uses a separate commit-only exit, not a repeated
  store. Dirty/code/exclusive bookkeeping stays authoritative in C.
- The program is pinned for the invocation. Same-owner callback retirement
  defers freeing until the last run returns. Callbacks cannot destroy RAM,
  fast-path, CPU or guard storage. Cross-program cache chaining is not added.
- Generated offsets/constants are checked with C static assertions. Emitted
  assembly has only two calls, both terminal memory helpers; ordinary hot
  dispatch remains direct-threaded and call-free with a fixed 64-byte frame.

## Shared Walker Correction

The new EL0 tests found that `avz_stage1_validate_leaf` checked read-only stores
but did not reject supervisor-only pages at EL0. The shared C walker now checks
leaf AP[1] (descriptor bit 6) for reads, writes and instruction fetch. This is
the only production implementation change in Phase 4; it is not an assembly
special case and adds no work to successful TLB-hit accesses.

Existing supervisor-only test mappings now run at EL1 where that was their
intent. Actual EL0 spinlock and IRQ-transition fixtures instead grant EL0 access.
The kernel-entry cache test now expects a denied EL0 fetch and still verifies
reuse after returning to EL1. New tests cover all four AP combinations, both
address halves, warm entries and privilege transitions.

This is not a claim of complete ARM MMU support: the experiment inherits the
existing walker's supported translation regimes and attribute/table-descriptor
limitations. It does not add a second walker or bypass permission faults.

## Correctness Evidence

- Existing 82,370 register/branch differential and boundary cases pass.
- 768 RAM differential cases compare full CPU state, all RAM bytes and dirty
  ranges against the established direct-CPU core: four widths, SP/XZR, immediate
  offsets and every budget through multiple loop iterations.
- 72 MMIO success/failure/retirement/remap cases, with exactly-once callback
  effects, plus translation-callback retirement. Helper callbacks deliberately
  clobber volatile GPR/SIMD state and unwind through the assembly frame.
- 24 deliberately rejected hot proofs; 48 observer/alignment/code cases.
- Low/high VA, ASID changes, EL0/EL1, warmed read-only mapping store faults,
  permission revocation, same-value exclusive invalidation and stale-code entry.
- Parallel code publication and all four shared TLBI scopes, including
  register-only tails; 100,000 concurrent aligned publications without torn
  values.
- Optimized and UBSan experiment builds pass, including disabled API checks.
- Existing runtime regressions pass optimized and UBSan: 3,136 differential
  scenarios, 128 replacements and the continuation/checkpoint/journal matrix.
- Full Swift suite: **669 tests, zero failures**.

ASan was attempted twice, including outside the sandbox. A process sample shows
a pre-`main` deadlock in Apple ASan shadow-memory initialization through
`dyld_shared_cache_iterate_text_swift` and the allocator interceptor. Neither
attempt counts as a sanitizer pass. UBSan does not instrument assembly memory
accesses; ASan/TSan coverage remains a promotion limitation.

## Measurement Method

Three 64-bit loops: load/arithmetic, store/arithmetic and load/increment/store.
Each sample retires 1,048,576 instructions after 8,192 warmup instructions.
Fifteen rounds rotate all three ordering slots at windows 4/64/256/4096.
The assembly and threaded-C modes use equivalent local/shared cache and memory
epoch guards. All modes disable detailed memory statistics and warm their TLBs.
CPU and RAM are checked against C outside each timing interval.

Mode 0 is the unchanged established direct-CPU C core; mode 1 is the existing
threaded-C memory prototype; mode 2 is guarded assembly. Neither C core fixture
includes production cache lookup/chaining or cache-provided semantic hints.
The workload is hot single-page RAM, not real guest working sets, TLB miss
throughput, graphics observations, device traffic or end-to-end Phosh latency.

The controller records source/binary hashes, wall and thread-CPU times, medians,
IQR and min/max. Host load gates run before/after, not continuously. Pinecone is
temporarily paused during timing and resumed in `finally`. Results are retained
under the ignored `experiments/phase3/results` directory.

## Final Results

Final binary SHA-256:
`bdcb251fa7301d0026a4c90a6330aebb8dc3eede3a2f425a706941a928d46896`.

Accepted final cohorts: `phase4-final-memory2` and `phase4-final-memory3`, each
540 samples; `phase4-final-register`, 600 samples. All resumed the Simulator.
Peak active process/aggregate CPU at load checks: 47.8%/164.3%, 48.9%/121.6% and
70.4%/233.2%, respectively. `phase4-final-memory1` was rejected before timing
because a Chrome renderer reached 110.6%, above the predeclared 100% limit.
Earlier `phase4-memory-cohort1/2` and `phase4-register-control` are development
measurements of a different binary and are not pooled into the final result.

Median milliseconds per 1,048,576 instructions, final memory cohort 3:

| Loop | Window | Established C core | Threaded C memory | Guarded assembly |
| --- | ---: | ---: | ---: | ---: |
| Load64 | 4 | 15.098 | 6.088 | 5.517 |
| Load64 | 64 | 12.969 | 4.654 | 3.582 |
| Load64 | 256 | 12.291 | 4.223 | 3.221 |
| Load64 | 4096 | 12.565 | 4.208 | 3.173 |
| Store64 | 4 | 15.048 | 6.436 | 5.900 |
| Store64 | 64 | 12.611 | 4.618 | 3.763 |
| Store64 | 256 | 12.427 | 4.354 | 3.448 |
| Store64 | 4096 | 12.293 | 4.161 | 3.359 |
| Mixed64 | 4 | 16.525 | 7.041 | 6.570 |
| Mixed64 | 64 | 13.971 | 5.260 | 4.597 |
| Mixed64 | 256 | 13.911 | 5.073 | 4.379 |
| Mixed64 | 4096 | 13.731 | 4.870 | 4.164 |

At window 64, the two final cohorts show **1.14-1.30x throughput versus threaded
C memory**, and **3.04-3.62x versus the direct-CPU core control**. Cohort 2 assembly
medians were 3.571/3.790/4.549 ms for load/store/mixed; cohort 3 was
3.582/3.763/4.597 ms. Cohort 3 assembly IQRs were 0.126/0.077/0.137 ms, with
thread-CPU medians 3.538/3.750/4.571 ms. These are reductions in host execution
time for these loops, not a projected UI speedup.

Register-only window-64 controls: arithmetic 2.484 ms assembly vs 4.250 ms
threaded C; branch 2.277 vs 4.418 ms (1.71x and 1.94x). The extension still beats
both C controls, but the earlier Phase 3 cohort had 1.87x/2.22x ratios. The
extra memory-mode check, run metadata and lifetime protocol have a register-only
cost; different host cohorts also prevent treating the difference as an exact
causal estimate. Do not claim register-only nonregression or erase the earlier
result. Phase 5 should address this overhead without dropping correctness checks.

Each operation remains 48 bytes; a four-instruction program now occupies 264
bytes including header/sentinel/pin state. Assembly text is 15,268 bytes versus
8,252 in Phase 3. The one-shot preparation columns remain diagnostic, not a
repeated cold-cache benchmark.

## Simulator Smoke Test

Built Release for Simulator and installed in the existing **Pinecone Graphics
Regression** device `541E22EE-C52B-4478-A041-56FEDC23ACFF`, preserving its disk.
The old guest was stopped through the UI before installation. Both
`PINECONE_THREADED_PROTOTYPE` and `PINECONE_THREADED_MEMORY` were explicitly zero.
The new assembly files are outside the app and SwiftPM source targets.

Observed Linux's persistent-root mount and shell prompt, automatic Phosh launch,
the guest lock screen, tap-to-unlock, Home with intact labels/icons, Settings'
Network page, and return to Home. The native badge remained at zero fallback.
This validates the shared C permission fix on the existing executor, **not**
production execution through the new gadgets. Benchmark pauses and compilation
overlapped the smoke-test interval, so no boot/app-launch timing is claimed.

Simulator executable SHA-256:
`19733bc3d731a9328b14d7f8d956fd87a04c7bd7b8f65fa5964685ae0ab56623`.

## Remaining Gates

Phase 5 is safe block chaining and validation amortization. Production cache
integration, timer/checkpoint/host-preemption service bounds, arm64e, asynchronous
unwinding and matched end-to-end UI cohorts remain separate gates. No near-native
or Phosh speedup is inferred from these scalar-memory measurements.
