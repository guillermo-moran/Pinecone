# Interpreter Execution Overhead

## Scope and Baseline

This work changes only the immediate ADD/SUB handler in
`Sources/ARM64VizNative/ARM64VizNative.c`. It does not change dispatch architecture,
cache or memory implementation, public interfaces, runtime settings, guest images,
Swift fallback policy, synchronization, or the new threaded prototype.

The exact dirty executor was copied **before the first production edit** to:

```
/tmp/arm64viz-execution-overhead.ZWarOM/baseline/ARM64VizNative.c
SHA-256: 9432c35819bbd69653195c2db2151a6996195ecead85209161eb23cb3d3ecced
```

The containing `baseline` directory contains the captured native sources and
headers. `dirty-baseline.diff` and `dirty-baseline.status` in the parent directory
record pre-edit dirty state. In particular, the two semantic fill-loop mapped-exit
fixes and the generic-context native-clock guards were already present and remain
intact. Git HEAD is not the comparison baseline. No resets, reverts, or commits
were performed, and other agents' files were not edited.

Retained candidate executor SHA-256:
`07550f6036dc3a56c6ce0a392d2fda44eb25b94717420a1de5dff35e304dab7f`.

## Inspection and Change

The mapped executor already skips semantic preparation for ordinary candidate
bytes. Mapped-PC validation occurs at entry and block boundaries, semantic loops
can resume or exit to the next mapped block, and generic fallback calls
`execute_decoded_instruction` while recording generic dispatches. None of these
paths or retirement/budget checks was altered.

Apple Clang 17 `-O3` assembly showed that the original immediate handler already
sank most unused NZCV work past its `set_flags` branch. Merely moving that
calculation is therefore not a sound optimization rationale. However, even normal
32/64-bit unflagged immediates executed dynamic general-width mask construction
and complemented-operand carry arithmetic. Flagged forms additionally used the
general-width 128-bit unsigned-sum carry calculation.

The retained handler specializes decoded 32/64-bit ADD/SUB immediates:

- Compute an unsigned sum/difference and truncate the result once.
- Compute N/Z/C/V only for flag-setting forms. Addition carry is `result < lhs`;
  subtraction carry is `lhs >= rhs`; overflow uses the operand/result sign bits.
- Preserve the original general-width helper for other decoded widths.
- Preserve SP versus ZR destinations, unrelated PSTATE bits, the PC update, and
  the single existing `AVZ_THREADED_STEP()` retirement path.

The generic reference executor is unchanged. This is arithmetic metadata
specialization, not deferred CPU state, batched retirement, or relaxed faults.

## Reproduction

Run from `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
python3 scripts/native-execution-overhead-run.py /tmp/arm64viz-execution-overhead.ZWarOM/baseline --rounds 8 --steps 60000000 --output /tmp/arm64viz-execution-overhead.ZWarOM/final16
python3 scripts/native-execution-overhead-run.py /tmp/arm64viz-execution-overhead.ZWarOM/baseline --ubsan --output /tmp/arm64viz-execution-overhead.ZWarOM/final-ubsan
python3 scripts/native-execution-overhead-run.py /tmp/arm64viz-execution-overhead.ZWarOM/baseline --workload memory --rounds 10 --steps 120000000 --output /tmp/arm64viz-execution-overhead.ZWarOM/memory-control
sh scripts/run-native-dispatch-boundary-regressions.sh
sh scripts/run-native-dispatch-boundary-regressions.sh --ubsan
sh scripts/run-native-simd-direct-regressions.sh
sh scripts/run-native-simd-direct-regressions.sh --ubsan
```

The standalone runner prints every compiler/execution command, hashes both
executors, compiles both against **the same captured headers/cache/memory sources**,
compares correctness output and benchmark steps/checksums, alternates binary order,
and preserves raw timing logs and median summaries. No SwiftPM/Xcode/rootfs build
is involved. `--workload generic` (or another listed workload) isolates a workload;
`--rounds 0` runs correctness only. Use a new output directory to retain prior logs.

Final benchmarks use 32 mapped blocks of the production maximum 16 instructions.
Workloads perform accumulating integer arithmetic, mixed arithmetic/control flow,
callback loads/stores, SIMD duplication interleaved with arithmetic, dependent
generic SIMD addition, and execution through the public cached-chain API. There
is no NOP-only benchmark. The mapped microbenchmarks intentionally isolate the
executor; they are not captured application traces.

## Correctness

The new standalone harness covers all register source/destination combinations,
32/64-bit forms, ADD/SUB with and without flags, immediate shifts, zero/sign/carry
edges, random immediates and NZCV, SP/ZR aliases, mapped and linear execution,
budget truncation, callback-observed PCs, memory failures, generic SIMD fallback,
host checkpoint sequences, and native timer/pending-IRQ checkpoints.

The generic single-instruction reference and the exact captured executor are
both used as oracles. On this ARM64 host, 144,405 arithmetic cases additionally
check result and NZCV against actual host `adds`/`subs` instructions, including
32-bit zero extension. Full CPU state and result counters are compared; benchmark
checksums and retired-step counts must also match.

The final `-O3` and UBSan baseline/candidate runs all pass **153,239 cases**,
including 48 native timer/IRQ cases, with matching digest `80802c368e2a2e20`.

Existing suites passed:

| Command | Result |
| --- | --- |
| native dispatch boundary | 1,647 cases |
| native dispatch boundary, UBSan | 1,647 cases |
| native SIMD direct | 6,058 checks, including per-element faults |
| SIMD memory hardware differential | 13,056 executions, 816 opcodes, 0 mismatches |
| SIMD vector hardware differential | 2,816 executions, 176 opcodes, 0 mismatches |
| native SIMD direct, UBSan | 6,058 checks |

Initial timer-harness setup attempts failed in the baseline because the
fast-memory constructor requires a non-null slow context and translation callback,
and the physically bound instruction RAM must contain the fetched code. The
harness was corrected; no production change was made to address these test errors.

## Candidate Measurements

Host: ARM64 Apple silicon (`T8112`), Darwin 25.5.0, Apple Clang 17.0.0
(`clang-1700.6.3.2`), C11 `-O3`. Five agents were active, so these are provisional
elapsed-time measurements, not quiet-host acceptance results. Negative changes
below mean less elapsed time, not an equal percentage increase in throughput.

Two correct candidates were rejected, not retained:

| Candidate, six alternating rounds | ADD64 | SUB32 | Flagged | Mixed | Cached chain |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1: early no-flags specialization | -13.84% | -12.65% | +6.81% | -10.18% | +5.01% |
| 2: split no-flags arithmetic, shared retirement | -9.89% | -10.64% | +11.53% | +1.57% | +1.28% |

Their raw logs and rejected executor copies remain in `candidate1` and
`candidate2` under the artifact directory. These exploratory runs used
32-instruction blocks, not the final production-sized 16-instruction benchmark.

Candidate 3 (retained width-specialized arithmetic and NZCV) initially measured
ADD64 -8.93%, flagged -19.44%, and cached chain -13.95%, but generic SIMD +6.23%.
An eight-round, 60-million-step repeat measured ADD64 -11.98%, SUB32 -12.66%,
flagged -18.54%, mixed -4.48%, memory +1.07%, SIMD -1.69%, generic -5.79%, and
cached chain -17.00%. Thus the initial generic regression was not repeatable in
that run. Both exploratory logs are retained in `candidate3` and
`candidate3-repeat`; the final production-sized measurements follow separately.

Final 16-instruction blocks, eight alternating rounds, **59,999,744 retired
instructions per mapped workload per sample**, and 60,000,000 for cached chain:

| Workload | Baseline median seconds | Candidate median seconds | Time change |
| --- | ---: | ---: | ---: |
| ADD64 | 0.511527 | 0.455522 | -10.95% |
| SUB32 | 0.520159 | 0.523033 | +0.55% |
| Flagged immediate | 0.617352 | 0.509384 | -17.49% |
| Mixed | 0.463877 | 0.442101 | -4.69% |
| Callback memory | 0.498213 | 0.514756 | +3.32% |
| SIMD + immediate | 0.424608 | 0.425315 | +0.17% |
| Dependent generic SIMD | 2.558409 | 2.434778 | -4.83% |
| Cached chain | 0.517172 | 0.438091 | -15.29% |

Raw samples: `/tmp/arm64viz-execution-overhead.ZWarOM/final16/benchmark.txt`.
The small positive controls must not be presented as improvements. Arithmetic
and cached-chain gains repeated across three runs; these measurements do not
establish that every instruction mix improves.

The isolated memory follow-up used ten alternating rounds of 120,000,000 retired
instructions each. Median baseline **0.857233 s**, candidate **0.834857 s**,
elapsed-time change **-2.61%**; matching checksums throughout. The suite's +3.32%
memory slowdown did not repeat. Logs are in `memory-control/benchmark.txt` under
the same artifact directory. This still requires the parent's quiet-host rerun;
it is not proof of a memory-system optimization.

## Limitations

These results do **not** establish UI/input/frame latency, Phosh responsiveness,
full-system interrupt latency, or application-level speedup. No Simulator,
integrated build, guest-image rebuild, or captured-application replay was run;
those belong to the parent integration task. The arithmetic result/flags and
native instruction-count clock/checkpoint behavior are tested locally. Memory
callbacks in the mapped benchmark are synthetic, not a RAM/TLB performance claim.

Concurrent memory/cache work can change the integrated binary; the frozen runner
deliberately excludes it. Existing regression scripts use the current workspace
dependencies. The parent should rerun the retained candidate serially, including
the generic and memory controls, before making an integrated performance claim.
