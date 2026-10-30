# Phase 6: Short-Entry Cost

Status: isolated prototype optimization, not linked into Pinecone. Short scalar
calls improve in both final comparisons. Longer scalar and chain cells remain
mixed; this is not a no-regression or application-promotion gate.

Follow-up: the [same-binary control and conditional batch](phase6-conditional-results.md)
separates preparation cost from linked handler placement. Three paired cohorts
repeat the short-call gain without the earlier repeatable long mixed-loop
slowdown. The historical measurements below remain unchanged.

## Investigation

A three-second host sampling run of the preserved branch-capable binary found
408 samples under the assembly memory runner: 33 in `ag_memory_prepare`, 31 in
the C entry wrapper and 344 below the assembly call. Preparation accounted for
about 8% of these samples. This mixes workloads/windows and ran with Pinecone
active: it identifies a candidate cost, not accepted throughput evidence or an
exact attribution of the previous 4.7% timing regression.

Emitted-code inspection showed a separate preparation call on every entry,
with argument/result preservation around it. The target range table itself is
not rebuilt per invocation: entry stores its pointer and count. Removing that
table would not address the preparation cost and would break indirect branches.

## Changes

- Inline the existing memory-view preparation in `ag_run_memory` only. The
  generated C wrapper frame shrinks from 336 to 320 bytes and no longer calls
  `ag_memory_prepare`. The assembly frame remains 64 bytes.
- Retain the out-of-line preparation function for chains and helper tests.
  Its body comes from the same private inline definition, avoiding divergence.
  Final `chain.o` and `memory.o` are byte-identical to the preserved baseline.
- Align the assembly dispatch region to 64 bytes and assert that alignment in
  the linked test binary. C wrapper size changes no longer change the region's
  position modulo 64. This does not eliminate all layout/cache effects and did
  not establish a separate throughput win for alignment.

No memory view is retained across invocations. Every entry still captures its
current mapping metadata and acquire-loads shared epochs. Guards, retirement,
fault precedence, callback lifetime, observation/dirty accounting and event
boundaries are unchanged. Operation size remains 48 bytes. No production source,
guest image, VM preference, execution window or Swift fallback setting changes.

## Final Measurements

Baseline: `/tmp/pinecone-phase6-branches-final/test-enabled`, SHA-256
`39a6dc5b80319760f2d306442c9448b221cc44183d8c54c7af2d65f60beeee34`.

Candidate: `/tmp/pinecone-phase6-entry-aligned-final/test-enabled`, SHA-256
`6348a0c344365a5f51c6b9fb964b615800e046aa018953d95df866fcbdae0038`.

Final artifacts are `experiments/phase3/results/phase6-entry-aligned-` followed
by `memory` or `chain`, then `-old-1`, `-new-1`, `-new-2`, `-old-2`. Each suite
ran in that order, sequentially with no concurrent build/test. All eight
cohorts pass the existing collection/load checks and record Simulator resume.
They contain 2,160 scalar and 1,920 chain throughput samples, plus 1,616
event-service observations across baseline and candidate. Each throughput
sample retires 1,048,576 instructions, with CPU/RAM checks outside timing.

The load gate is coarse (peak <=100%, total <=400%, Pinecone stopped). Passing
it is not proof of a perfectly quiet host or statistical equivalence. Current
source hashes collected beside a preserved binary are not its build attestation.

Candidate / baseline guarded-assembly wall medians; lower is faster:

| Scalar loop/window | Comparison 1 / comparison 2 |
| --- | ---: |
| load64/4 | .946 / .898 |
| load64/64 | .975 / .961 |
| load64/256 | .984 / .978 |
| load64/4096 | 1.039 / .999 |
| store64/4 | .944 / .930 |
| store64/64 | .999 / .998 |
| store64/256 | .993 / 1.021 |
| store64/4096 | .979 / 1.014 |
| mixed64/4 | .910 / .921 |
| mixed64/64 | .954 / .964 |
| mixed64/256 | 1.016 / 1.008 |
| mixed64/4096 | .997 / 1.048 |

Four-instruction scalar calls use approximately 5-10% less median wall time in
both comparisons. Larger windows amortize preparation, so they do not show the
same benefit. In particular, mixed64/4096 is 4.8% slower in comparison 2
(3.966 -> 4.157 ms, candidate IQR 0.253 ms). Variance does not prove that
slowdown is harmless. The previous broad no-regression gate remains open.

Candidate / baseline chain-mode wall medians:

| Chain/window | Comparison 1 / comparison 2 |
| --- | ---: |
| ring2/4 | 1.014 / .986 |
| ring2/64 | 1.050 / 1.030 |
| ring2/256 | 1.000 / 1.019 |
| ring2/4096 | 1.028 / 1.010 |
| ring8/4 | .997 / .987 |
| ring8/64 | 1.006 / .988 |
| ring8/256 | 1.052 / .961 |
| ring8/4096 | .995 / .954 |
| ring32/4 | 1.004 / .991 |
| ring32/64 | 1.022 / .989 |
| ring32/256 | .992 / .986 |
| ring32/4096 | 1.000 / 1.035 |
| ring128/4 | 1.015 / .977 |
| ring128/64 | 1.011 / 1.007 |
| ring128/256 | 1.017 / 1.035 |
| ring128/4096 | .991 / 1.015 |

There is no general chain-throughput gain. Some cells are consistently slower,
notably ring2/64. Identical chain object code does not prove identical linked
execution performance. These are direct-branch rings, not a benchmark of large
indirect target tables. Event-service p95 reports 1 microsecond in both binaries
at the clock's observed resolution. Candidate chain maxima reach 22 microseconds
versus 3 microseconds for the baseline; host scheduling is included. Neither
number measures guest touch-to-frame latency.

## Retained Iterations

- `phase6-entry-scalar-before-1` overlapped the initial build/test. Its collector
  accepted the coarse load gate, but it is excluded from performance evidence.
- The broad-inline variant is retained in `phase6-entry-scalar-*` and
  `phase6-entry-chain-*`. It improved short scalar calls but had slower short
  128-block chain cells. The chain/helper preparation boundary was restored.
- The restricted, unaligned variant is retained in `phase6-entry-final-*`.
  It improved short scalar calls, but mixed64/4096 still had a 5.5% slower cell.
- Fixed alignment did not establish uniform improvement. The final tables
  above, not the best cells from earlier iterations, describe the retained code.
- The first aligned test invocation encountered a shell tail error after
  `run.sh` was edited while it was running. It is not the validation run. The
  clean `entry-aligned-final` rerun completes successfully with the final script.

## Verification and Limits

The complete optimized and UBSan suites pass, including 190,406 register/boundary cases,
scalar/pair RAM and callback cases, 72,765 chain cases, 28,475 indirect-chain
cases, ABI/unwind checks, concurrent code/TLBI publication and disabled mode.
UBSan instruments the C code, not assembly instruction bodies; no ASan/TSan,
arm64e or physical-device validation is claimed.
The shell syntax and linked alignment assertion pass. No Swift production code
changed in this batch, so no new Swift/iOS build result is claimed.

Validation logs, emitted dispatch/unwind data and the attribution sample are
retained under `experiments/phase3/results/phase6-entry-validation/`.
The existing Simulator app was observed at Home with fallback 0 after earlier
cohorts. It was not rebuilt, reset or freshly booted. The new executor is still
offline; no Phosh boot, touch, app-launch or physical-device improvement is
established here.

Remaining work: isolate the longer-window/layout differences before promotion,
expand sampled conditional operations, then integrate behind an opt-in backend
and measure actual VM/UI behavior. This change is a short-entry improvement,
not completion of Phase 6 or a substitute for the application comparison.
