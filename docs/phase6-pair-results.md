# Phase 6: Scalar Pairs

Status: isolated implementation, not linked into SwiftPM/iOS or installed.
No production executor, scheduler, graphics, guest image or runtime-default
changes are part of this batch. Phase 6's end-to-end gate remains open.

## Implementation

- LDP/STP and LDNP/STNP, 32/64-bit, plus LDPSW. Offset and valid pre/post-index
  forms use decode-selected handlers; non-temporal forms use the same
  architectural access path, without claiming a host cache-placement hint.
- The shared memory-handler macro validates the whole pair's span before an
  access. Inline execution is same-page, naturally element-aligned RAM only,
  preserving TLB/context/permission proofs, observation flags and code checks.
- Each element is a separate host load/store. No stronger pair atomicity than
  the existing C memory model is claimed. Signed results and successful base
  writeback are specialized. Ordinary scalar handlers gain no pair flag check.
- Metadata remains 48 bytes per operation; the second register uses spare
  auxiliary bits, never a host executable pointer. Only the original two
  terminal assembly-to-C helper calls remain.
- Slow paths preflight both accesses, then use the shared C paired RAM API or
  memory callbacks. These are memory helpers, not instruction fallback.
  Faults retire zero instructions and leave PC/base/load destinations unchanged.
  A failing second store callback can leave the first external write completed.
  Post-store code accounting covers both elements without replaying writes.
- A boundary test caught duplicate fault reporting when retrying a failed pair
  translation. Preflighting individual elements before the paired helper and
  terminating on a pending translation fault fixes that experimental path.

Excluded: SIMD pairs, unallocated encodings, duplicate LDP destinations, and
non-SP writeback aliases with either pair register. These exit before execution
rather than choosing an arbitrary constrained-unpredictable behavior.

## Verification

Optimized and UBSan builds pass all earlier suites, disabled-build checks,
emitted-code inspection and these additions:

| Coverage | Cases |
| --- | ---: |
| Width, sign, address modes, SP/XZR, aliases, offset extremes, hot/cold RAM, observers, unaligned and cross-page accesses | 2,850 |
| Callback preflight, first/second failures, partial stores, writeback, program retirement and unwind | 152 |
| Second-page unmapped/read-only faults, warmed read permission, pending TLBI, code-write exits and no-replay commit | 48 |
| Cross-block execution with exact service budgets | 129 |

Five excluded encodings additionally check zero retirement and unchanged CPU.
RAM tests compare full CPU, RAM bytes and dirty ranges against the C core.
Callback/fault expectations are independently asserted, not merely differential.
Host Clang confirms the benchmark and chain-test instruction encodings.
UBSan covers C, not hand-written assembly; this does not establish arm64e,
ASan/TSan, physical-device or full-system integration correctness.

Emitted assembly __TEXT grows from 35,528 to 41,456 bytes (+5,928). The frame,
reserved-register policy, operation size and terminal-call count are unchanged.

## Profile Reclassification

These are the existing saved captures, not new application timings. Each cell
is fully eligible retained prefixes before / after this batch, out of 32:

| Capture | Primary | Secondary |
| --- | ---: | ---: |
| Phosh | 21 / 22 | 20 / 23 |
| Settings | 19 / 22 | 16 / 20 |
| Firefox-observed | 22 / 26 | 20 / 25 |

Prefixes contain at most four instructions. Approximate sampling, mixed capture
windows and secondary-vCPU reset differences documented in earlier reports
still apply. This is not dynamic instruction coverage or measured UI improvement.
Indirect branches now dominate first misses in these retained prefixes.

## Measurement Contract

The pair suite uses three warmed four-instruction loops, 4/64/256/4096-instruction
windows and 15 interleaved rounds for guarded assembly versus the direct C core.
Unlike historical scalar controls, this C control explicitly selects the
runtime's paired RAM helper. The old threaded C subset cannot execute pairs and
is excluded rather than completed by a hidden interpreter.

Each cohort has 360 samples, 1,048,576 guest instructions each, with full CPU/RAM
equality checks outside timing. Preparation is outside the warmed timing.
The runner verifies and temporarily pauses only Pinecone's Simulator process,
then resumes it in a finally block. Coarse host-load gates do not eliminate all
noise; inspect raw timings, retain failed/noisy evidence and do not infer UI
speed from these isolated loops.

## Collection Outcome

No timing cohort is accepted in this batch:

Later follow-up: the branch-capable binary has two accepted pair cohorts, as
documented in [indirect-branch results](phase6-indirect-results.md). The rejected
cohorts below remain rejected; those newer measurements have a different
binary identity and are not retroactive acceptance of this batch.

| Artifact under experiments/phase3/results | Outcome |
| --- | --- |
| phase6-pairs-1 | Pre-run host-load gate failed; no samples collected |
| phase6-pairs-2 | 360 samples and CPU/RAM checks completed; post-run load gate failed |
| phase6-pairs-3 | 360 samples and CPU/RAM checks completed; post-run load gate failed |

All three reports confirm Pinecone was resumed. The latter two complete sample
sets were independently checked for every expected workload/window/round/mode
and instruction count. macOS mediaanalysisd repeatedly exceeded the existing
100% per-process load threshold (post-run peaks 118.3% and 125.5%). No threshold
was relaxed and no unrelated process was stopped. These samples establish
successful benchmark execution, not an accepted speedup. Fine scalar-path
regression controls are also pending a clean host; prior scalar results cannot
be presented as measurements of this new binary.

Optimized executable SHA-256:
`7fbf8f7548252f98edb0295a0a48692db7c62fa4595af3be02c40e642840890d`.
The pre-pair binary remains preserved with SHA-256:
`c20a9d2ef7fa85975a2621392c0c44e76ed07723b56af09c0826f004305fd7dd`.
Test logs, emitted assembly, unwind information, generated offsets, encoding
source and reclassified capture are in
`experiments/phase3/results/phase6-pair-validation/` (ignored artifacts).

After collection, the Simulator still shows the unlocked Home launcher and
fallback 0, with the native counter advancing. This verifies resume/display of
the unchanged established C app, not a fresh boot/unlock or experimental backend.

## Remaining Gate

Next: measured register-branch and conditional-operation coverage, then the
production cache/lifetime adapter and matched application-level comparisons.
First obtain clean repeated pair timings and matched old/new scalar controls.
The earlier small scalar-control slowdowns also remain a promotion concern.
No assembly default switch or Phosh responsiveness claim is made here.
