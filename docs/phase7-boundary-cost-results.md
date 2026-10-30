# Phase 7 Boundary Cost Follow-Through

Status: optimized native boundary implemented and screened; **not promoted**.
`PINECONE_ASSEMBLY_CHAINING` remains off by default. This work does not claim
a Phosh responsiveness improvement or change the selected ordinary executor.

## Changes

- Added compile-time-only sampled attribution (`--profile`) for retirement
  accounting, shared-TLBI synchronization, timer/IRQ evaluation, timer allowance,
  callback return, validation, visit selection, and memory-view preparation.
  Production has no profiling clocks/counters; the Release executable has no
  `ag_boundary_profile` symbol.
- Added a whole-graph validator for the cache-owned graph. It checks the common
  binding once and walks members directly, avoiding repeated binding checks and
  linear searches for each member. Generic per-member validators are unchanged.
- Removed only redundant generation-value loads from that callback. The service
  runtime still checks global guards, every member serial, and local/shared page
  generations before **and after** the callback. Live binding, identity, token
  address, captured-value, and enrollment metadata checks remain. Admission and
  reuse retain their complete checks. No timer/IRQ/TLBI service was skipped.
- Fixed instruction-translator replacement: invalidate decoded mappings and
  retire dependent chains before changing the mapping callback. The new active
  remap regression failed before the fix by executing the old successor; after
  the fix it exits, redecodes the new physical page, and executes the new code.
- Made exclusive-lock contention deterministic before retaining parallel stress.
  No assertions were weakened; see `phase7-contention-test.md`.
- Added explicit compiler/SDK selection to native runners. Installed LLVM 22
  supplies a working ASan runtime; Xcode's ASan startup remains incompatible on
  this host. See `phase7-asan-investigation.md` for negative controls and limits.

The assembly veneer was inspected, not rewritten. It materializes the operation
pointer, status, retired steps and dispatch count and calls native service.
Guest registers already live in `AVZNativeCPU`; there is no per-boundary full
register-file copy to remove. Veneer/dispatch cost has not been independently
timed and must not be inferred by subtracting instrumented stage estimates from
uninstrumented execution time.

## Cost Screen

Apple Clang `-O3`, six alternating mode pairs per block length, 524,288 retired
instructions per sample. Both modes prewarm identical positive programs. Every
sample checks architectural state, exact steps/visits, timer accounting, actual
chaining coverage, graph reuse, and graph byte bounds outside timing.

| Instructions/block | Before chaining ns/instruction | Final chaining | Final ordinary | Final chain/ordinary |
| ---: | ---: | ---: | ---: | ---: |
| 2 | 33.423 | 22.016 | 5.208 | 4.227x |
| 4 | 17.479 | 11.845 | 3.974 | 2.981x |
| 8 | 10.046 | 7.651 | 3.632 | 2.107x |
| 16 | 6.616 | 5.164 | 5.008 | 1.031x |

Chaining cost decreased approximately 22-34% between these synthetic screens,
but **still fails the ordinary-executor performance gate**. The before/after
figures are different build runs, not interleaved binaries or an isolated UI
benchmark. The intermediate bulk-only screen is also retained. The final
same-build ordinary/chaining comparison is the promotion decision's negative
evidence; a near tie at sixteen instructions does not justify enabling it.

The disposable VM was stopped during final screening. Builds/tests/agent CPU
work had completed. The user's original VM remained active (20.9% CPU at the
preceding observation), and host load, frequency and thermals were uncontrolled.
No clean whole-VM cohort, physical-device benchmark, or UI speedup is claimed.

## Attribution

Sampling selects roughly one boundary in 1,024 with a reproducible PRNG, avoiding
fixed phase-locking to alternating members. Samples are host elapsed ticks,
not thread CPU time. Clocks and sampling perturb execution, so profile-mode
throughput is never used for gating. Clock calibration is recorded as a
reference, not subtracted from stages. Short intervals and timer resolution
make these coarse attribution estimates, not precise component costs.

Initial weighted validation samples averaged about 33.7 ns. Consolidating the
callback reduced that to 28.1 ns; final validation samples averaged 18.7 ns.
These stages include probe overhead and came from separate runs.

Final medians of per-round sampled stage averages:

| Stage | Observed ns/sample |
| --- | ---: |
| Retirement accounting | 7.64 |
| TLBI synchronization, including call entry | 8.22 |
| Timer/IRQ evaluation | 6.22 |
| Native time-service return | 7.76 |
| Next timer allowance | 7.27 |
| Service callback return | 6.67 |
| Graph validation | 17.36 |
| Visit selection/setup | 8.68 |
| Memory-view preparation | 12.41 |

One timer-stage round averaged 552 ns/sample, consistent with a host interruption;
the raw outlier remains in the log. No outlier was silently deleted. That is why
the timer's pooled 19.9 ns mean is not presented as its normal cost. These stages
must not be added together and presented as uninstrumented boundary latency.

## Verification

- Full Swift regression: 676 tests pass after the mapping fix; two full runs
  passed during this change. The deterministic contention test separately
  passed 32 focused runs.
- Native production optimized, UBSan and LLVM ASan suites pass. Cache optimized
  and LLVM ASan+UBSan pass, including changed bindings/member metadata without
  changed epochs, peer code writes, TLBI scopes, journal overflow, retirement,
  and active instruction-translator remapping.
- Generic service UBSan and default-disabled checks pass; 64 benchmark-harness
  tests pass. ASan instruments C, not handwritten assembly accesses.
- Release Simulator build succeeds. Executable SHA-256:
  `c5e8a3d65fc4dc2b409e9c472010fabc44396a6883aaba6b59356a843603331b`.
- Disposable Simulator `C20024A2-E866-468D-BDC6-C44E6F01E0A3`: candidate booted
  with real chaining work recorded on both vCPUs. One tap unlocked; Home
  rendered, Settings displayed Network controls, and Home worked afterward.
  Both-vCPU milestone records and the visible counter showed zero fallback.
  The previously observed missing Settings header remains; this is not a full
  layout sign-off. No guest image or graphics implementation was changed.
- Candidate shell milestone: 3.573 s; guest-ready milestone: 91.332 s; Settings
  surface milestone: 43.924 s after launch request. These single retained-disk
  observations are not matched performance evidence. Visible Settings content
  was separately checked after the surface milestone.
- This candidate smoke set the guest trace environment but omitted the host
  `PINECONE_INTERACTION_TRACE=1`, so host attribution was empty. Saved guest
  records are temporal-only associations, not causal touch-to-frame evidence.
  No interaction percentile or repeated-unlock distribution is claimed. A
  future matched UI cohort must set this flag on both host and guest, without
  mixing instrumentation configurations between compared runs.
- After candidate verification, the disposable app was cleanly stopped and
  relaunched with ordinary assembly and `PINECONE_ASSEMBLY_CHAINING=0`. Both
  vCPUs report zero chain runs/steps. Lock screen and single-tap unlock to Home
  were visually verified again with zero fallback. The user's original
  Simulator app/disk/executor and physical device were untouched.

## Next Gate

Do not turn chaining on. Its fixed per-visit overhead still dominates short
blocks. The next experiment should amortize service across a validated run with
an explicit timer/IRQ/TLBI deadline contract, while preserving per-page write
detection and immediate exits for helpers/faults. The generic every-visit
callback API must remain unchanged. Compare against existing C superblocks,
which already amortize this work, before introducing another runtime mode.

Raw logs are under `experiments/phase3/results/phase7-boundary-cost/`.
