# Native Validation Spans: 2026-10-26

## Status

Implementation complete; standalone correctness and UBSan tests pass. No timing
claim, integrated application gain, or Settings-launch improvement is established.
The parent owns serial benchmarking, prototype API integration, full builds, and
guest/UI validation. No Swift, shared public header, BlockCache, GuestMemory, or
ThreadedPrototype file was edited by this workstream. Existing prototype
integration and the prior add/sub optimization remain intact.

Changed files:

- `Sources/ARM64VizNative/ARM64VizNative.c`
- `scripts/native-validation-span-harness.c`
- `scripts/native-validation-span-run.py`
- `docs/interpreter-validation-span-performance.md`

No cross-file API additions are needed.

## Cold Revalidation Follow-Up

The initial integrated candidate regressed the parent's actual Phosh workload.
The implementation below corrects two deterministic sources of unnecessary exits;
it does not establish recovery of that real-workload regression.

- A code epoch can change inside lookup/fetch before execution. Previously the
  pre-lookup epoch snapshot forced a zero-instruction host return even when the
  selected block was valid. The executor now attempts bounded cold revalidation.
- Unrelated executable-page writes or unchanged translation invalidation no
  longer unconditionally fragment an active resident block or copied trace.
  Revalidation uses the existing page/mapping/trace validators and resumes at
  the same instruction index only when validation succeeds.
- Resident callback boundaries check the selected entry's captured serial token
  instead of querying the global residency mutation epoch. Unrelated evictions
  therefore do not end a still-valid resident block. Same-pointer recycling
  still exits, and callback instruction snapshots remain intact.

Cold validation captures reset, residency, local-code and shared-code epochs,
checks the original key and serial (or all required trace backing entries), and
requires all captured epochs to remain stable across validation callbacks.
Actual changed code/mappings, selected-entry reuse, resets, and validation-time
mutation still exit. No retry loop, public API, eligibility-priority change,
deadline change, or removal of a validation boundary was introduced. The old
private mapped-executor interface remains available for existing test harnesses.

Final normal-run evidence is `/tmp/native-validation-span-cold-final-o3/`;
the corresponding sanitizer run is
`/tmp/native-validation-span-cold-final-ubsan/`. Both use immutable frozen cache
and memory sources, with a snapshotted current public header for the candidate
and pre-fix reference because the parent has integrated prototype declarations.
Every input, compiler invocation, stdout/stderr and exit code is recorded in
`sha256.json`, `commands.json`, individual logs and `results.json`.
All 12 candidate groups pass in both runs, with no UBSan diagnostics.

The added groups exercise eight cold/warm combinations of unrelated local/shared
code writes, actual cache eviction, and unchanged remapping; lookup-induced epoch
changes through both public cached-chain APIs; and mutation during validation
plus exact load-fault PC/retirement. The old nine groups remain unchanged. The
pre-fix candidate fails all three new groups. The frozen baseline additionally
retains its four known invalidation failures. An initial test incorrectly expected
UNSUPPORTED for a load fault; the established executor contract is OUTSIDE_BLOCK.
That assertion was corrected without changing execution code; the initial raw
failure remains in `/tmp/native-validation-span-cold-o3/`.

Follow-up source identities (superseding the historical identities below):

```text
candidate ARM64VizNative.c bb31de5856dab033aa4ac30e8178538e307782addc76b2460ef7f00249bd6347
pre-fix ARM64VizNative.c   de77d923f66e1b1f14fd7771ff28a442f1d725e31a58b8cec63430c5a5bbec16
harness                   ebee4e1136c56e028c58e7a17530d781e03d8224467725fd0472c001e8c77907
runner                    98a6faff9dbe13cd2f0f43af481fdc7f6b344679092952bf0a71d4ca87673b35
```

Exact correctness commands (use new output directories when repeating):

```sh
python3 scripts/native-validation-span-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-validation-span-cold-final-o3 --reference-source /tmp/native-validation-span-before-cold-20261026.c --rounds 0
python3 scripts/native-validation-span-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-validation-span-cold-final-ubsan --reference-source /tmp/native-validation-span-before-cold-20261026.c --rounds 0 --ubsan
```

No timing, Simulator, Swift build, or prototype-enabled test was run in this
follow-up. Parent owns serial integrated verification and profiling. The serial
benchmark command in Reproduction remains available but was not executed.

## Validation Sequencing

Previously, superblock construction followed the same recent-successor edge
repeatedly in cyclic traces. A 32-block trace of a two-block loop performed 31
recent-successor lookups, each of which validates source/target entries. The
candidate reuses an edge already established in the *same composition attempt*.
Cache generation, residency mutation, local code epoch, and shared code epoch
must remain unchanged. Source pointer/serial pairs identify reusable edges.
The first block is explicitly checked, and the complete span is checked again
after copying instructions. Published trace epochs are the captured validated
epochs, not fresh values sampled after the checks. Existing translation
validation remains in the cache owner and is not bypassed across an epoch change.

When a saved superblock needs changed-epoch validation, each resident serial is
checked before consulting its block pointer. Repeated occurrences of the same
block then share one code/mapping validation. A recycled slot cannot validate
replacement code on behalf of an old copied trace. Same-source/target direct
links likewise need only one code check after both serial checks succeed.

Investigation exposed four correctness gaps in the frozen baseline. The patch
also closes them rather than extending validation reuse across unsafe boundaries:

1. A pre-execution host checkpoint could invalidate a block already selected for
   execution. The chain now restarts lookup after either pre-execution checkpoint.
2. Changed-epoch superblock validation could consult a recycled cache entry's new
   code instead of the old trace's code. Serial checks now precede that access.
3. A memory callback could change instructions still pending in a decoded block
   or mapped trace. Cached execution carries its selection epoch into the mapped
   executor; callback-capable handlers and semantic-helper returns check that
   epoch before another dispatch. Internal mapped block boundaries also check the
   shared epoch, so another vCPU's code change does not silently span the trace.
4. A callback could recycle the resident instruction currently completing, causing
   its post-callback register/operand accesses to read replacement fields. Only
   resident callback-capable instructions are copied to a local snapshot before
   the callback. Copied superblocks already own their instruction storage.

Pure ordinary arithmetic handlers do not gain a per-instruction epoch check.
Callback checks compare epochs, not page tables. Standalone non-cache decoded
execution remains supported. The portable dispatch alternative checks at each
iteration and snapshots its current instruction.

Instruction budgets, partial mapped-block accounting, checkpoint totals, and
native IRQ/timer accounting are retained. No CPU/RAM defaults, guest images,
executable-page permissions, invalidation producers, or JIT policy changed.

## Evidence

Both final runs use Apple clang 17.0.0, native arm64 macOS, and the exact frozen
directory `/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative`, never
`git HEAD`. Each arm links the same frozen cache/memory implementations and
headers. The runner saves copies, compiler version, exact command arrays,
SHA-256 manifests, and separate raw stdout/stderr for every case.

Final raw evidence:

- `/tmp/native-validation-span-acceptance-o3/`
- `/tmp/native-validation-span-acceptance-ubsan/`
- `/tmp/native-validation-span-acceptance-overhead/`

The candidate passes all nine validation groups at `-O3` and with
`-O1 -fsanitize=undefined -fno-sanitize-recover=all`:

| Group | Coverage |
| --- | --- |
| budgets | 1,940 actual warmed cached-chain comparisons to decoded single-step execution; arithmetic/memory, partial instruction/block/checkpoint limits |
| stale | local and shared-memory code writes, full clear, same-key remap/translation invalidation, TTBR/ASID-bearing key change |
| checkpoint | invalidate a selected WFI block at its pre-execution checkpoint; replacement arithmetic must run without WFI |
| recycling | real cache eviction and same-pointer/different-serial reuse on different physical code pages, followed by shared-code invalidation |
| self-modifying | cold and warm chains; writes change the current or later block |
| callback-recycling | load callback clears and refills the identical cache slot; original destination register must receive the result |
| exception | exact retired count and freshly decoded target after synchronous-exception callback |
| timer | 17 exact native timer deadlines; externally pending IRQ masked/unmasked |
| counts | same retired instructions/checksum for two-block and self-loop compositions |

The frozen baseline fails `checkpoint`, `recycling`, `self-modifying`, and
`callback-recycling` at explicit architectural-state assertions in both runs.
These are preserved failures, not discarded samples. The remaining baseline
groups pass. There are no UBSan diagnostics in either arm; baseline failure
exit codes are the harness assertions. Early development fixture failures
(ASID-only keys canonicalizing to one key, absent timer translation callback,
and treating timer assertion as the external pending-IRQ field) were corrected;
their earlier logs remain under `/tmp/native-validation-span-first` through
`/tmp/native-validation-span-fourth` and are not acceptance results.

The existing execution-overhead correctness harness is also run with `--rounds 0`
against frozen dependencies. It covers 153,239 cases, including 144,405 host ARM64
arithmetic checks, with matching state/checkpoint digest `80802c368e2a2e20`.

Non-timing instrumentation of actual cached-chain composition reports:

| Shape | Retired steps | Baseline recent-successor calls | Candidate calls | Baseline/candidate checksum |
| --- | ---: | ---: | ---: | ---: |
| Two-block memory loop | 224 | 31 | 2 | 32832 |
| Self-loop memory block | 224 | 31 | 1 | 32824 |

The candidate adds one explicit first-block validation per composition (baseline
zero in this counter). These counters wrap executor calls, not all cache-internal
checks. They prove redundant edge lookups were removed, **not a wall-time gain**.
The added correctness checks can offset the saved validation cost, especially in
steady-state mapped execution, and must remain enabled in comparisons.

## Exact Inputs

SHA-256 identities for the accepted source and harness:

```text
candidate ARM64VizNative.c 5483b90280edf64869af9339ec939e5af3e4d83273a3860fd2f979df023e9c90
baseline ARM64VizNative.c  d4409d07012afe1563c3137c2a29d0d57df7d48bd3be5a575914134258a2617c
harness                    6081fa031cf704dc0b369b94a53f9174ccb870ab916cd0b9cedb6acafac5b337
runner                     72d7df7e0b9f84678112711122d0a73ed4cb87f802f711455f7b0d3d981d6c82
frozen BlockCache.c        c8d181bad0da1bb89f39ab77d9f8cb988d9c97fad65222210d3acc995b8e7122
frozen GuestMemory.c       cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f
frozen GuestMemoryInternal.h 33a2e4771c8da43800357e022cfafdd1aa289b5fcca53b9c95b5ae37d35c3622
frozen ARM64VizNative.h    84282bcf7003e189937b6e126b8c572eeb30cf9fc72120ed19981aa7240e9ae4
```

## Reproduction

Run from the repository root; output directories must be new. Correctness:

```sh
python3 scripts/native-validation-span-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-validation-span-review-o3
python3 scripts/native-validation-span-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-validation-span-review-ubsan --ubsan
```

Exact **parent-owned serial benchmark command**, after other workers stop:

```sh
python3 scripts/native-validation-span-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-validation-span-serial-ab --rounds 6 --iterations 10000
```

The command first runs all correctness cases, then alternates baseline/candidate
order across six rounds. Four workloads cover arithmetic and mixed load/store
chains in both steady state and forced recomposition. Every pair must match
retired steps and architectural checksum. Raw outputs include time and validation
counts. There are no flags disabling invalidation or epoch guards. Prototype
dispatch is disabled at compile time in both arms to isolate this executor work;
enabled-prototype integration belongs to the parent. No timing run was performed
by this agent, and no concurrent-worker timing is offered as evidence.

Scope limits: shared-vCPU publication and TLBI effects are tested deterministically
through their code-generation/translation-invalidation interfaces, not concurrent
race stress or a complete guest page-table workload. The portable dispatch branch
has not been separately executed in this pass. Full prototype-enabled builds,
multi-vCPU integration, and guest/Settings measurements remain parent-owned.
