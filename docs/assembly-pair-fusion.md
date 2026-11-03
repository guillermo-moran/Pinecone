# Assembly instruction-pair fusion

Current performance status: the expanded implementation has **no demonstrated
speedup**. A later same-executable comparison did not reproduce the historical
7.5% immediate-CMP result below. The iOS app now enables assembly by user request;
this is not a demonstrated performance promotion. The CLI remains opt-in.

The existing prototype caches predecoded operations pointing to precompiled
ARM64 assembly handlers. Its bounded graph adapter can chain guest blocks
within one assembly entry, with C service callbacks at required boundaries.
The iOS default can be disabled with `PINECONE_ASSEMBLY_EXECUTOR=0`; the CLI
enables it with `=1`. Graph chaining still requires
`PINECONE_ASSEMBLY_CHAINING=1`. The pair-fusion implementation itself did not
enable these defaults or install a simulator build.

Pair fusion supports 32-bit and 64-bit SUBS/CMP immediate and shifted-register
forms followed by B.cond. Immediate shifts and register LSL/LSR/ASR are covered.
Preparation replaces only the arithmetic handler. The branch remains an
independent operation for direct entry and budget stop/resume. The fused
handler publishes the destination, guest PC and NZCV, retires SUBS/CMP, checks the original code and
translation guards and instruction budget, then enters the branch using the
NZCV nibble retained in a scratch register. It avoids the indirect dispatch and
the branch's flag reload/extraction. SP sources and XZR destinations retain
their architectural meanings. No operation layout or cache lifetime changes.

Address/load and load/conditional-branch fusion are not implemented here.
Memory pairs need particular care around authoritative memory helpers, faults,
MMIO, and invalidation. Existing C semantic accelerators retain priority.

Validation:

- `sh scripts/run-assembly-runtime-regressions.sh`: existing runtime coverage
  plus 1,331,712 fused/unfused differential cases covering all conditions, both
  widths, SP/XZR, aliased destinations, overflow inputs, internal/external
  targets, direct branch entry, budgets 0–8, and stale guards. An instruction
  that changes its own local guard through NZCV deterministically verifies
  revalidation after exactly one instruction, before the fused branch.
- The same script with `--ubsan` checks undefined behavior.
- `sh scripts/run-assembly-dispatch-regressions.sh`: production selection,
  chaining, timer, invalidation, and concurrent publication coverage.

For a focused benchmark run
`PINECONE_BENCHMARK_FUSION=1 sh scripts/run-assembly-runtime-regressions.sh`.
It alternates fused and unfused programs within the same executable, running
12 million guest instructions per sample with a live local guard. On the local
Apple Silicon Mac, nine samples after the first warm-up gave median times
23.589 ms unfused and 21.823 ms fused: about 7.5% less time (8.1% higher
throughput). This is a tiny compare/branch loop, not an Android boot benchmark.
Removing dispatch alone was effectively neutral; forwarding the flags produced
the measured gain. `AG_COMPARE_BRANCH_FUSION=0` disables preparation fusion at
compile time for independent comparisons.

The benchmark now includes independent immediate CMP, destination-writing
immediate SUBS, and register CMP loops. The historical timing above measures
only the original immediate CMP implementation; use fresh results for the
expanded implementation and compare each pattern separately.

The final expanded build produced these median times over nine samples after
warm-up (12 million guest instructions/sample):

| Pattern | Unfused | Fused | Interpretation |
| --- | ---: | ---: | --- |
| Immediate CMP + B.cond | 23.648 ms | 24.185 ms | 2.3% slower in this run |
| Immediate SUBS + B.cond | 23.627 ms | 23.611 ms | effectively neutral |
| Register CMP + B.cond | 25.474 ms | 25.428 ms | effectively neutral |

The host was shared with other development/validation activity, so these are
diagnostics rather than an isolated performance acceptance test. An earlier
expanded run was within 0.3% for all three patterns. Correctness coverage passed
in both optimized and UBSan builds, including the FP transfer integration.
The added patterns should not be promoted based on the old isolated-loop gain.
