# Phase 3 Gadget Experiment Results

Date: 2026-10-29. Outcome: the bounded offline register-only experiment passes
its differential and synthetic-throughput gate. It is not integrated into the
VM or approved as the default executor. Both C paths remain intact.

Implementation and reproduction: [experiments/phase3](../experiments/phase3/README.md).

## Correctness

- 82,370 differential/boundary cases pass in optimized and UBSan builds.
- Supported cases compare full CPU state and result status/steps against the C
  switch reference, public computed-goto reference and direct-CPU execution core.
- Coverage includes 32/64-bit arithmetic edge values, all source/destination
  registers for immediate forms, SP/XZR, carry/borrow, flags, all condition/flag
  combinations, move-wide fields, bit/zero branches, inside/outside targets,
  partial budgets, address wrap and precise unsupported-prefix exits.
- ABI probe passes across all implemented exit classes. It checks x19-x28,
  complete v8-v15 contents, FPCR/FPSR, SP and frame pointer. A million-instruction
  loop returns through the same 64-byte frame.
- Peer publication of each of three shared generations terminates an active
  register-only loop with the exact architectural prefix. This is not a measured
  event-latency bound or a proof of all guest synchronization semantics.
- Disabled compilation returns without executing or allocating a program.
- The existing native runtime suite also passes after this work: 3,136
  differential scenarios, 128 cache replacements and all continuation groups.
- Emitted assembly has indirect tail dispatch, no ordinary calls and no x18 use.
  Generated layout offsets have C static assertions. The frame has emitted CFI
  covering handler execution and the restored exit state.

UBSan covers C, not the assembly's memory operations. Live signal/exception
unwinding, arm64e, device execution and C-helper transitions are not claimed as
tested. There are no helper calls in this initial subset. Full-system G1-G8
promotion requirements remain in the [Phase 2 matrix](phase2-test-matrix.md).

Development corrections: the first assembly build rejected global labels inside
one CFI region. Handler labels now use Mach-O alternate-entry metadata. Initial
timing used only the public C API; that copying adapter is not the production
direct-CPU path. A new test-only bridge supplies the direct core without changing
production source. The final cohort includes both controls.

## Final Timing Cohort

Evidence: `experiments/phase3/results/20261029-cohort2/` (generated, ignored).
600 samples: two loops, four windows, five modes, 15 rounds per cell.
Host: Darwin ARM64, Apple clang 17.0.0 (`clang-1700.6.3.2`), C compiled `-O3`,
no LTO; assembly precompiled for Darwin arm64.

Pinecone's Simulator process was temporarily suspended and automatically resumed
without a restart. All four host-load checks passed: active process peak 55.6%,
aggregate peak 112.1%, below the declared 100%/400% limits. The same process was
subsequently verified in a non-stopped state. No competing build/test ran during
the timed cohort. The controller samples load before/after, not continuously.

Each sample retires 1,048,576 guest instructions. Values below are median wall
milliseconds; lower is better. Preparation is excluded. The C prototype and
direct C controls use immutable code; guarded assembly checks four actual epoch
pointers at entry and each instruction.

| Loop | Window | Direct-CPU C core | C threaded prototype | Guarded assembly |
| --- | ---: | ---: | ---: | ---: |
| Arithmetic | 4 | 12.714 | 4.466 | 3.406 |
| Arithmetic | 64 | 10.295 | 4.061 | 2.168 |
| Arithmetic | 256 | 10.156 | 3.840 | 2.027 |
| Arithmetic | 4096 | 10.082 | 3.783 | 2.000 |
| Branch | 4 | 11.201 | 4.647 | 3.113 |
| Branch | 64 | 8.955 | 4.073 | 1.834 |
| Branch | 256 | 8.918 | 3.860 | 1.812 |
| Branch | 4096 | 8.748 | 3.775 | 1.783 |

At window 64, guarded assembly is 1.87x/2.22x the throughput of the C threaded
prototype for these arithmetic/branch fixtures. Guarded wall-time IQRs are
0.015/0.014 ms. The corresponding direct-C-minus-guarded-assembly paired savings
are positive in every round: 8.063-8.314 ms arithmetic and 6.771-7.598 ms branch.
All other window comparisons also have positive paired savings versus direct C.
Host thread CPU times track wall times closely in this cohort.

**These are not 4-5x Pinecone/Phosh speedups.** This core microbenchmark excludes
the production block cache, semantic-candidate metadata, devices, timers and
checkpoint scheduling. Its direct-C numbers are not interchangeable with the
earlier Phase 1 cached-chain measurements. The result supports continuing the
experiment, not replacing the runtime or granting a 4096-step production slice.

Mode 0's copying API is slower and is retained only as a diagnostic control in
the raw CSV. Mode 2's no-token assembly timing is also retained; neither controls
the promotion decision. The first exploratory cohort is preserved separately
as `20261029-cohort1` and is not combined with this five-mode cohort.

## Footprint and Preparation

- Decoded operations: 48 bytes versus 80 bytes in the current C prototype, a 40%
  reduction per operation. Both still store original opcodes for precise exits.
- Four-instruction assembly snapshot including sentinel/header: 256 bytes.
- Precompiled assembly text: 8,252 bytes for entry/exit and 42 handler labels.
- One-shot preparation in this cohort: 2 microseconds per four-instruction
  program. This is not a repeated cold-start/decode benchmark and should not be
  used as a startup-performance prediction.

The model avoids repeated C-handler frame setup and keeps control pointers,
remaining allowance and retired count in host registers. Guest registers/flags
remain architectural in memory after each instruction; per-instruction epoch
validation has not been removed to obtain the measured result.

## Evidence Identity

Final enabled benchmark binary SHA-256:

```text
4fc3bbca8eb461e605b0e63ae9da6f7494db1dc3862d9bbd9758d529191fac67
```

`report.json` records source/header hashes, binary identity, raw load inventories,
acceptance/resume status and per-cell median/min/max/IQR/thread CPU values.
`samples.csv` contains all 600 samples; all final CPU states were checked during
collection. Local build evidence is in `/tmp/pinecone-phase3-direct`, including
generated offsets, disassembly, unwind metadata and enabled/disabled binaries.
The script can rebuild this evidence; `/tmp` contents are not a dependency.

## Decision and Next Gate

The Phase 3 **offline subset** gate passes: exact-state differential tests pass
and repeated arithmetic/branch execution improves beyond observed variability.
No production backend, installed app, guest image or preference changed.

Phase 4 may add the validated scalar RAM path in the isolated experiment, keeping
the existing authoritative helpers and precise exits. Before any VM integration,
the adapter must also implement cache-owned lifetime/pinning, validation at
selection, timer and block/checkpoint service bounds, host preemption and debug
eligibility. It must retain established C for ineligible work. A later Simulator
boot/unlock/app-response comparison is mandatory before enabling it for users.
