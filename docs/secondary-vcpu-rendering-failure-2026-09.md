# Secondary vCPU rendering failure

## Reproduced failure

Opening Settings Appearance could stop CPU 1 while CPU 0 and the host display
continued running. Linux subsequently reported RCU stalls. A read-only LLDB
inspection of the stopped worker found:

```
lifecycle = halted
failureDescription = unsupported instruction 0x4d40c806 at 0xffff7fdd0a48
nativeSteps = 2314007765
fallbackSteps = 0
```

LLVM decodes the instruction as `ld1r {v6.4s}, [x0]`. The worker's catch path
stored the error and parked the worker, but did not propagate the failure to
the primary runner. This was a real loss of a guest CPU, not merely slow Metal
presentation. Evidence: `/tmp/pinecone-secondary-debug.txt` and
`/tmp/pinecone-rcu-stall-sample.txt`.

## Retained fixes

- Extend native C single-structure SIMD decoding/execution to LD1R-LD4R and
  LD/ST1-LD/ST4 lane forms. Cover vector-register wraparound, 64/128-bit
  replication, immediate/register post-indexing and SP addressing.
- Reject reserved replication encodings. Publish loaded vectors and base
  writeback only after all reads succeed. A failed read does not partially
  publish architectural registers.
- Wake the primary runner when a secondary worker fails, outside the worker
  condition lock. Check and report secondary failures at host execution-slice
  boundaries. The existing failure report now records the worker error instead
  of leaving a silently degraded VM running.
- Preserve native-only execution. No Swift instruction fallback, graphics
  workaround, guest image substitution or changes to Metal blending are added
  by these fixes.
- Replace lane-by-lane SIMD broadcast construction with masked multiplication
  for standard 8/16/32/64-bit elements. Reuse the existing broadcast helper in
  LD1R-LD4R. Retain the helper's previous behavior for other supported bit widths.

## Verification

- 506 Swift tests pass, including the exact Settings instruction, a 96-variant
  native-only replication matrix, every partial-read fault boundary of LD4R,
  and host notification/error propagation from a failed secondary worker.
- `bash scripts/run-simd-structure-regressions.sh` compares native execution
  with real ARM64 hardware: 4,608 executions across 288 legal encodings, zero
  mismatches. Includes lane loads/stores and replication, all element sizes,
  post-index forms and register wraparound.
- Also compare 928 register-broadcast executions across 58 encodings against
  real ARM64 hardware, including in-place source/destination overlap. Zero
  mismatches. Final hardware output: `/tmp/pinecone-splat-hardware.log`.
- The Simulator reached Phosh, unlocked, opened Settings Appearance and returned
  to the home screen. No unsupported instruction, RCU stall or fallback was
  observed in this interaction run.
- Test logs: `/tmp/pinecone-retained-regressions.log` and
  `/tmp/pinecone-retained-hardware.log`.

## Experiments rejected

Removing eager symbol-index construction from the patched musl loader did not
improve cold Settings launch. The existing r6 package, builder and staging
selection were restored. The added native-Alpine loader regression fixture is
retained for future loader work; it exercises PIE/non-PIE, GNU/SysV/both hashes,
preload interposition, weak symbols, TLS, dlopen and missing runtime symbols.

Inlining decoded-block metadata accessors and bypassing disabled profiling
loops produced a small, noisy microbenchmark difference, not an established
end-to-end gain. Those production edits were removed. The isolated diagnostic
benchmark remains in `scripts/benchmark-native-dispatch.c`; its tiny cached loop
is not representative of a full Settings launch.

The separate broadcast optimization was retained: in 15 alternating before/after
runs, the median throughput of the DUP/add/branch workload rose from 229.751 to
254.421 million guest instructions per second (10.7%). Median runtime for 30
million instructions fell from 0.130576 to 0.117915 seconds. Tests, compilation
and the Simulator app were stopped for that comparison. This isolates a local
execution improvement; it is not a measured Phosh responsiveness improvement.
Evidence: `/tmp/pinecone-splat-quiet-comparison.txt`.

## Measurements and limits

Dedicated Simulator: `541E22EE-C52B-4478-A041-56FEDC23ACFF`, two native vCPUs.
Host: Mac14,2, 8 CPUs, 24 GiB RAM. Original user Simulator/device data was not
modified. Each cold run below used a pristine copy of the same root image,
except the explicitly labelled loader experiment.

| Revision | Shell | Phosh marker | Settings request to surface |
| --- | ---: | ---: | ---: |
| Before native replication fix, original r6 loader | 2.39 s | 56.01 s | 26.64 s |
| Rejected demand-only r7 loader | 2.39 s | 61.10 s | 26.80 s |
| Replication/failure fix, first run | 2.85 s | 76.31 s | 45.22 s |
| Replication fix plus rejected dispatch experiment | 2.53 s | 61.77 s | 41.20 s |
| Final retained build, including constant-work broadcasts | 2.31 s | 58.41 s | 27.23 s |

These single runs do not demonstrate a launch improvement. In particular, the
45.22 s and 41.20 s runs are slower than the baseline; the cause of that difference is
not established. The first replication run overlapped some test/build activity
early in startup. No attribution to thermal throttling is established either.
Both cold launch and ordinary interaction latency remain unresolved.
The final retained build is back near the original launch timing, with no
fallback on either vCPU. This does not establish that broadcasts account for
the timing difference. Evidence: `/tmp/pinecone-splat-final-profile.json`.

Before the broadcast optimization, a manual Simulator swipe unlocked Phosh and
Appearance rendered successfully. On the final build, the automated pristine
boot/unlock/Settings presentation sequence passed. The Mac locked before the
final manual Appearance/home-screen check; that check is pending a manual Mac
unlock and is not counted as completed. No unsupported instruction, RCU stall
or ext4 error appeared in `/tmp/pinecone-splat-final-uart.log` during the
automated final run.

Four completed host temporal interaction samples in the dispatch-experiment
run had queue-to-device max 0.574 ms, publication-to-presentation max 21.811 ms,
and device-to-commit max 7432.117 ms. This is too small and heterogeneous a
sample for a comparative p95 claim. Guest timestamps also show long input to
render intervals; they are not causally matched to individual host inputs.
Evidence: `/tmp/pinecone-dispatch-interactions-analysis.json`.

The previous test disk also reproduced ext4 buddy/bitmap warnings before these
fixes. It is preserved at `/tmp/pinecone-response-inconsistent.ext4`. Journal
replay was tested only on a disposable clone. The pristine-image runs did not
show those warnings; their cause is not fixed or attributed to the SIMD error.
Do not treat this report as a filesystem or overall responsiveness sign-off.
