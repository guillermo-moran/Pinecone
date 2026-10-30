# Phase 1: Clean Timing Cohort

Measured October 29, 2026. Parent-owned serial run; production code, guest image
and executor defaults unchanged. The full cohort completed. Independent review
of the resulting interpretation is recorded in `experiments/phase1/review.md`.

## Executive Finding

Repeated short prototype invocations are the dominant demonstrated performance
cost among the tested controls. Keeping per-instruction validation but extending
invocations substantially improves both synthetic workloads, and the extended
prototype outperforms established C in these fixtures. Tail-call interpretation
itself is not disproven by the original integrated regression.

This is evidence for designing safe execution continuity in Phase 2, not for
shipping a larger instruction cap immediately. No Phosh, Firefox, concurrent
invalidation or physical-device speedup was measured in this cohort.

## Provenance and Completion

- Fresh output: `experiments/phase1/results/20261029-retry-01/`.
- Exact accepted bundle:
  `e530182a7c96c2473926279869e25b385759d464accb074e59cb7a5d8e6eec24`.
- Reused the previously reviewed source snapshots, binaries and verification.
  Structured bundle comparison found only the output directory changed. No
  compilation overlapped timing; no samples from the aborted cohort were copied.
- Twelve arms, 64 workload/mode/cold-warm cells, 11 forward/reverse alternating
  samples per cell: **704 successful samples**. All expected-state/step/RAM
  assertions passed. `timing-status.json` is `complete`; summary eligibility true.
- All **91 process-load snapshots passed**. Maximum sampled aggregate process
  CPU was 128.6%; maximum individual process CPU was 44.9%; Pinecone was absent.
  Predeclared limits remained 400% aggregate and 100% per process.
- The original VM was stopped only during measurement and relaunched afterward
  with established C, threaded memory disabled and two parallel vCPUs.
  `app-restoration.json` records successful launch, PID 70641. Parent then
  visually verified the Phosh lock screen (`restored-phosh.png`) and checked
  fresh readiness telemetry: both prototype flags zero, both vCPU fallback
  counters zero, readiness 61.258 seconds. That restoration boot is not an
  additional controlled boot-performance trial.

The detailed fixture, untimed verification and scope are documented in
[the first attribution report](phase1-attribution-results.md). This cohort uses
the same one-million-step, four-instruction, single-thread immutable fixtures,
fixed-4096 checkpoint allowance and raw RAM without attached shared guest memory.
Checkpoint invariant assertions remain inside every arm's measured path; full
expected-state comparisons are outside timing. These timings must not be pooled
with the earlier benchmark's differently instrumented harness.

## Invocation Sweep

Median milliseconds per million guest instructions, prewarmed execution:

| Executor / invocation cap | Arithmetic | Memory |
| --- | ---: | ---: |
| Established C baseline | 5.106 | 7.485 |
| Prototype unchanged baseline | 15.522 | 19.696 |
| Prototype cap 4, matched source control | 15.584 | 19.626 |
| Prototype cap 16 | 6.392 | 9.149 |
| Prototype cap 64 | 4.599 | 5.801 |
| Prototype cap 256 | 3.914 | 4.943 |
| Prototype cap 4096 | 3.678 | 4.672 |

Every sweep arm retains validation, architectural state updates, instruction
accounting and requested/checkpoint-budget clamping. Increasing the cap reduces
wrapper entry/exit, lookup, pinning, entry validation and statistics-update
frequency together; this is not a measurement of any one component alone.

Against the matched cap-4 control, the cap-4096 median elapsed times are about
76% lower in both workloads. Relative to established C's medians, they are
about 28% lower for arithmetic and 38% lower for memory. These are synthetic
elapsed-time reductions, not application speedups or native-performance ratios.

Most of the benefit appears before the largest cap. From 256 to 4096, median
elapsed time falls another 0.236 ms (arithmetic) and 0.271 ms (memory); paired
round savings are 0.246 and 0.256 ms. This is diminishing benefit, not a flat
plateau or proof of no additional gain. It argues
for evaluating a conservative bounded continuation window, not selecting the
largest slice solely because its throughput is highest.

Cold arithmetic medians are 5.159 ms established, 15.628 ms unchanged prototype
and 3.674 ms cap-4096; cold memory is 7.406, 19.613 and 4.732 ms respectively.
Cold and warm results stay separate. In cold memory, some work takes established
C instead of the prototype; their difference is not pure preparation cost.

## Paired Attribution Controls

Differences are computed within alternating rounds, not simply by subtracting
unpaired medians. For cost controls, compare the prototype-minus-C gap against
the matched reference's gap. Positive values mean the candidate reduces it.

| Warm contrast | Median paired improvement (ms) | Descriptive bootstrap interval (ms) |
| --- | ---: | --- |
| Arithmetic cap 4 -> 4096, validation retained | 11.844 | 11.693 to 11.964 |
| Memory cap 4 -> 4096, validation retained | 14.865 | 14.793 to 15.017 |
| Arithmetic validation only at entry, fixed original cap | 0.649 | 0.532 to 0.739 |
| Arithmetic wrapper block/step statistics omitted, fixed original cap | 0.128 | 0.087 to 0.224 |
| Memory detailed statistics off, fixed original cap | -0.105 | -0.243 to 0.027 |

Intervals are the analyzer's seeded percentile bootstrap of median paired
differences with n=11. They are descriptive, uncorrected for multiple comparisons
and not a hardware-cycle allocation or population-level guarantee. The sweep
contrast uses the cap-4 prototype control; the other rows use gap differences
against their own C/reference arms. Effects may interact and must not be summed.

The validation omission control is unsafe for a changing full-system guest and
is confined to this immutable fixture. Its smaller benefit does not justify
removing validation. Memory statistics do not explain the differential slowdown:
their omission helps established C too, and the paired gap effect spans zero.
Shared-epoch contention is absent from this fixture, so these results do not
measure its cost or eliminate it as a separate full-system concern.

## Superblock Result

Disabling established superblock lookup/composition reduced warm established-C
medians to 4.683 ms arithmetic and 5.916 ms memory. Median paired savings against
the established baseline were 0.401 and 1.582 ms respectively.

Thus the proposed explanation that the prototype loses a beneficial superblock
path is not supported for these tiny self-loops: superblock suppression helps
the established executor here. This is a whole-policy contrast, not proof that
superblocks should be disabled in Phosh. Real block-size and working-set profiles
are required before changing that production policy. The long-invocation
prototype remains faster in these fixtures even against this C control.

## Limits and Retained Outliers

- One host/compiler and two tiny synthetic loops; not a representative general
  Linux workload. No shared memory, MMIO, live timers, remaps or peer mutation.
- Load gates sample processes, not every scheduling interruption. All samples
  are retained, including a 17.960 ms established warm-memory sample and a
  25.274 ms cap-4 warm-memory sample. Passing the gate does not imply zero noise.
- Warm limit-4 and unchanged prototype controls are close, but source-policy
  equivalence does not imply binary identity. All distinct arms remain separate.
- Dynamic counts identify work frequency, not separate CPU-cycle shares.
  Store-call ABI effects, larger working-set cache pressure and real guest
  contention were not independently timed here.
- No new UI responsiveness result follows. Firefox's failed button response
  remains an independent event-delivery/handling/rendering investigation.

## Decision for the Roadmap

Phase 1 is complete for ranking the tested synthetic controls, supported by the
source/assembly investigation, verified work ledgers and complete matched timing
cohort. This is not exhaustive attribution of every handler/helper CPU cycle.

Advance to **Phase 2: execution and invalidation contract**, prioritizing bounded
continuation across internal branches without re-entering the wrapper each tiny
block. Define precise side exits, event/deadline service, code and translation
visibility, callback retirement and two-vCPU lifetime rules before implementation.

The evidence does not require an immediate assembly rewrite or removal of
per-instruction guards. Phase 3 remains a gated experiment, not a predetermined
replacement: first use Phase 2 to establish whether the demonstrated continuity
benefit can be retained safely in the existing C prototype. Any implementation
ordering change beyond that must be made explicitly in the roadmap.

Keep established C enabled in the app until production correctness and UI gates
pass. Do not install these offline diagnostic variants. Do not broaden the
claims from Phase 1's fixed-4096 synthetic contract to real interrupt latency.

## Reproduction and Evidence

The complete accepted command was:

```sh
python3 experiments/phase1/measure.py time experiments/phase1/results/20261029-retry-01 baseline prototype-limit-4 prototype-limit-16 prototype-limit-64 prototype-limit-256 prototype-limit-4096 established-superblock-off cost-reference cost-validation-entry-only cost-prototype-stats-off cost-memory-stats-on cost-memory-stats-off --samples 11
python3 experiments/phase1/analyze_results.py experiments/phase1/results/20261029-retry-01
```

Do not append or rerun into this completed cohort. Its `timings.jsonl`,
`summary.json`, `contrasts.json`, load snapshots, bundle, approval and restoration
record are retained locally under the output directory. A future repeat needs a
new output directory, exact-artifact approval and VM/load coordination.
