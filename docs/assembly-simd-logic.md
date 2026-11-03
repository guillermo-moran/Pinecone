# Assembly integer SIMD logic

The prototype gains 8-byte and 16-byte vector forms of ORR, EOR, AND, BIC,
ORN, BSL, BIT, BIF, and NOT. This is an integer SIMD slice; floating-point
arithmetic remains outside this change. The handlers use caller-saved v0–v2
and do not alter host or guest FPCR/FPSR. NaN-looking bit patterns are data.

Each operation captures destination and sources before writing the result,
preserving guest aliases and the destination mask used by BSL/BIT/BIF.
Eight-byte forms clear the upper 64 bits. Register 31 denotes V31 rather than
XZR. Retirement uses the existing NEXT macro, preserving exact PC, budget,
code/mapping guards, and service behavior. Operation layouts are unchanged.

The observed Android performance snapshot had the assembly executor enabled
on all four vCPUs, but no hot-PC samples and disabled assembly-cache rejection
diagnostics. It therefore establishes that the path is in use, not that these
instructions are an Android bottleneck. Broader pure integer SIMD coverage is
a bounded way to admit additional blocks without introducing a guest FP
environment transition. No Android boot speedup is inferred from coverage.

Validation commands:

- `sh scripts/run-assembly-simd-logic-regressions.sh`
- `sh scripts/run-assembly-simd-logic-regressions.sh --ubsan`
- `PINECONE_BENCHMARK_SIMD=1 sh scripts/run-assembly-simd-logic-regressions.sh`

The correctness fixture passes 43,398 differential cases against C: all nine
families and both widths, distinct random/zero bit patterns, source/destination
aliases including V31, direct entry into every instruction of a mixed block,
all prefix budgets, stale guards, unchanged guest state outside the operation,
and preserved host FPCR/FPSR. Both optimized and UBSan runs pass.

The optional benchmark alternates assembly disabled/enabled in the same
binary. Its 16-instruction loop has 15 vector EORs and one branch; both
configurations retire six million guest instructions per sample. It verifies
final state and prints actual assembly-step deltas and C superblock dispatches.
It runs two API modes:

- Checkpointed production slices, allowance 4096 and checkpoint interval 64.
  Existing C superblock priority takes over the warmed loop: after the first
  16 assembly instructions, subsequent samples execute zero assembly steps.
  Thus this mode provides no evidence of a SIMD handler speedup.
- Bounded 16-instruction slices through the noncheckpointed cached-chain API.
  Both configurations make the same 375,000 calls and execute six million
  instructions per sample. Every enabled sample verifies six million assembly
  steps; disabled samples verify zero. Nine samples after warm-up gave medians
  39.446 ms C and 26.552 ms assembly, about 32.7% less time (48.6% higher
  throughput) on the local Apple Silicon Mac. This includes the adapter and
  cache lookup, not just a standalone NEON instruction.

These synthetic tests do not establish an Android or end-to-end UI speedup.
No C superblock priority or executor defaults change. The runner removes its
temporary build artifacts on exit; no guest disk copies or logs are retained.
