# Phase 6: Entry Attribution and Conditional Operations

Status: isolated prototype work. No production executor, guest image, simulator
installation, fallback policy or execution-window default changed. Phase 6's
application-level value and Phase 7 promotion gates remain open.

## Entry Attribution

The earlier cross-binary entry measurements changed both preparation and linked
code placement. A new control specializes the same entry implementation twice:
`ag_run_memory` inlines preparation; `ag_run_memory_control` calls the existing
preparation function. Both enter the identical assembly address in one binary.
The benchmark uses one common indirect call site, selected before timing, to
avoid different mode-selection branches on every invocation.

Emitted-code inspection confirms one preparation call only in the control and
the same `ag_enter` target for both. Fifty-six additional tests compare CPU,
RAM, exits and pin lifetime across cold/hot RAM, stale local/shared guards,
missing memory, halt/budget precedence, outside PCs, MMIO success/failure,
callback retirement, null arguments, retired programs and pin overflow.

Three accepted 360-sample cohorts are retained as
`experiments/phase3/results/phase6-entry-paired-{1,2,3}`. They alternate runner
order each round, verify full CPU/RAM results, and record Simulator resume.
The following are median *within-round* inline/outline wall-time ratios, not
ratios between separately linked executables:

| Loop/window | Run 1 / run 2 / run 3 |
| --- | ---: |
| load64/4 | .916 / .916 / .915 |
| load64/64 | .951 / .950 / .963 |
| load64/256 | .976 / .972 / .983 |
| load64/4096 | .993 / .990 / .994 |
| store64/4 | .921 / .918 / .905 |
| store64/64 | .978 / .968 / .949 |
| store64/256 | .996 / 1.015 / .992 |
| store64/4096 | 1.001 / .986 / .986 |
| mixed64/4 | .919 / .922 / .921 |
| mixed64/64 | .971 / .966 / .970 |
| mixed64/256 | .989 / .985 / .992 |
| mixed64/4096 | .997 / .989 / 1.001 |

The short-call reduction repeats at approximately 8-10%. The previous long
mixed-loop slowdown does not repeat in this control. This supports keeping
inline preparation; it does not prove all prior differences were code layout
or establish statistical equivalence for every workload.

The collector now rejects detected compilers, linkers and test processes even
when their instantaneous CPU use is low. Six Python tests cover these checks,
suspended processes, Simulator state and the existing CPU thresholds. This
would reject the previously excluded build-overlap case. Checks still occur
before/after collection, not continuously; passing is not proof of an otherwise
idle host. Raw per-round ratios and IQRs are retained, with no new post-hoc
performance threshold or significance claim.

## New Operations

- CSEL, CSINC, CSINV and CSNEG in both W and X forms. Their encoded aliases
  follow the same handlers, including XZR sources/destinations.
- CCMP and CCMN, both register and immediate forms, in both widths.
- All condition codes, including AL/NV, use the decoded condition table.
- Selects preserve guest flags; compares change only NZCV. The false compare
  path installs the encoded alternative flags. Thirty-two-bit results are
  zero-extended and register 31 is never treated as SP.
- Reserved S-bit select patterns exit unsupported before retirement. The
  shared decoder is permissive here; the new preparer explicitly rejects them.
  No unsupported operation is silently executed through Swift.

Semantics follow Arm's [conditional-select documentation](https://developer.arm.com/documentation/dui0801/f/A64-General-Instructions/CSEL)
and [instruction-set reference](https://documentation-service.arm.com/static/6245c734b059dc5ff9a8bdab).
Native host selects and ADD/SUB flag generation implement the arithmetic;
ordinary retirement, generation checks and chain service gates remain intact.

New handlers are appended after existing handlers within the same unwind range.
Every pre-existing handler retains its offset relative to `ag_enter`, verified
against the preserved entry-control object. The 64-byte executor frame and the
two terminal C-call sites are unchanged. No x18 use, extra hot helper call or
JIT code generation is introduced. Operations remain 48 bytes. Assembly text
grows from 41,708 to 46,172 bytes (+4,464); unwind data remains 88 bytes.

## Correctness

Optimized and UBSan suites pass:

- 65,536 independently calculated select inputs, each also compared with three
  C execution references at budgets 0/1/2.
- 131,072 compare inputs covering both widths/forms, all conditions, incoming
  flags and alternative NZCV values, all source/immediate encodings and boundary
  operands. Expected arithmetic flags come from separately compiled host
  ADD/SUB instructions, not the interpreter's arithmetic helper.
- Eight reserved-select exits with unchanged CPU state and zero retirement.
- 5,200 additional conditional cross-block budget/service/state comparisons and
  stale-page rejection.
- The full earlier memory, callback, fault, dirty/observation, ABI/unwind,
  lifetime, concurrent code/TLBI and disabled-executor suites.

The primary register/boundary suite now reports 518,086 cases. Independent
expectations and cross-block suites are additional checks, not new instruction
coverage claims for unimplemented families. UBSan instruments C, not assembly
bodies; arm64e, ASan/TSan and real-device validation are not claimed. No production
Swift code changed, and no fresh Swift or iOS build is claimed.

## Conditional Throughput

`phase6-conditional-1` and `-2` each contain 480 accepted samples with full CPU
equality, four service windows and 15 interleaved rounds. Modes include public
C, direct C, unguarded offline assembly and guarded assembly. The older C
prototype is excluded because it lacks these forms.

Guarded assembly / direct-C median wall ratios:

| Loop | Window 4 | Window 64 | Window 256 | Window 4096 |
| --- | ---: | ---: | ---: | ---: |
| Select | .308 / .310 | .251 / .251 | .240 / .236 | .235 / .234 |
| Compare | .289 / .290 | .231 / .232 | .220 / .220 | .225 / .217 |

These synthetic loops use approximately 69-78% less wall time than direct C.
They are not guest-trace replay or a measured Phosh gain.

## Existing-Path Controls

`phase6-conditional-memory-{old-1,new-1,new-2,old-2}` and the corresponding
`chain` cohorts ran sequentially in that order with no concurrent compilation.
All eight pass collection/equality checks and record Simulator resume. They
contain 2,160 scalar and 1,920 chain throughput samples and 1,616 event samples.
New/old guarded-assembly scalar median ratios:

| Loop/window | Comparison 1 / comparison 2 |
| --- | ---: |
| load64/4 | .995 / .992 |
| load64/64 | .990 / .994 |
| load64/256 | .994 / 1.002 |
| load64/4096 | .992 / 1.004 |
| store64/4 | .996 / .995 |
| store64/64 | .985 / .987 |
| store64/256 | 1.012 / .997 |
| store64/4096 | .990 / .993 |
| mixed64/4 | 1.002 / 1.015 |
| mixed64/64 | 1.025 / .996 |
| mixed64/256 | 1.022 / .956 |
| mixed64/4096 | 1.003 / 1.006 |

Chain-mode median ratios:

| Chain/window | Comparison 1 / comparison 2 |
| --- | ---: |
| ring2/4 | .966 / .997 |
| ring2/64 | .968 / 1.010 |
| ring2/256 | .993 / 1.006 |
| ring2/4096 | .997 / .979 |
| ring8/4 | 1.011 / 1.007 |
| ring8/64 | .977 / .973 |
| ring8/256 | .999 / 1.001 |
| ring8/4096 | 1.000 / 1.003 |
| ring32/4 | .983 / .997 |
| ring32/64 | .998 / .973 |
| ring32/256 | .991 / .997 |
| ring32/4096 | 1.002 / .990 |
| ring128/4 | 1.029 / 1.021 |
| ring128/64 | .999 / .975 |
| ring128/256 | 1.002 / 1.000 |
| ring128/4096 | .999 / .995 |

Changes are much smaller than the gains on newly supported forms. Nevertheless,
the 128-block, four-instruction chain entry is 2-3% slower in both comparisons;
this is not a zero-regression claim. Event-service p95 remains 1 microsecond at
the observed timer resolution; candidate chain maxima are 11 microseconds or
less, baseline maxima 20 microseconds. Host scheduling is included. These are
not touch-latency measurements or production scheduler deadline guarantees.

## Retained Prefixes

Reclassifying the same saved captures yields fully supported prefixes out of
32 before/after, without recapturing or changing the workload:

| Capture | Primary | Secondary |
| --- | ---: | ---: |
| Phosh | 25 / 26 | 28 / 29 |
| Settings | 25 / 26 | 23 / 27 |
| Firefox-observed | 29 / 31 | 30 / 30 |

These contain at most four words per prefix, with mixed capture windows and
estimated sample counts. They are not weighted dynamic coverage or proof of
application speed. Remaining sampled gaps include bitfields, shifts/division,
multiply forms, extended operands, atomics, SIMD and privileged operations.

## Artifacts and Next Gate

Entry-control baseline SHA-256:
`0d1a352e7f65b1b223c60b837d81562eab1dfb824b7a5db98756a9e352a33cbd`.
Final conditional candidate SHA-256:
`a7858bd3b8d939169cd4445d038cf9b76a278edfb017b4519ca4f152d69e6404`.
Validation logs, offsets, dispatch/unwind output, entry-control disassembly and
prefix reclassification are retained in
`experiments/phase3/results/phase6-conditional-validation/`.

The installed simulator remains on established C, with no image replacement or
fresh boot. The next meaningful milestone is an opt-in production cache/CPU/
memory adapter, with exact C exits for operations outside the assembly subset,
followed by matched boot/unlock/application tests. Production lifetime, SMP
invalidation and service boundaries must be verified there before promotion.
Do not infer readiness to enable the backend from these microbenchmarks alone.
