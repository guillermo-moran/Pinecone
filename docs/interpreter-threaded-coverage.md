# Musttail Coverage Expansion

## Scope

Task 3 extends the **current integrated** prototype, not its earlier standalone
version. The input report was `docs/interpreter-simulator-performance-2026-10-26.md`:
0.392-0.438% primary instruction coverage and a 35.031615-second Settings
request-to-surface diagnostic. No new guest coverage percentage, throughput gain,
or UI latency result is established by this work.

Only these five paths are owned/changed:

- `Sources/ARM64VizNative/ARM64VizThreadedPrototype.c`
- `Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h`
- `scripts/threaded-prototype-harness.c`
- `scripts/run-threaded-prototype.sh`
- `docs/interpreter-threaded-coverage.md` (new)

Existing dirty/user/other-agent work is preserved. There are no edits to
ARM64VizNative.c, ARM64VizNative.h, block cache, guest memory, Swift, Package.swift,
or existing reports. No JIT, Swift fallback, QEMU, runtime-default/CPU/RAM changes,
guest-image builds, Swift/Xcode builds, or device/Simulator operations were used.

## Register Coverage

New 32/64-bit forms, in addition to the integrated immediate/branch subset:

- ADD/ADDS/SUB/SUBS shifted register: LSL, LSR, ASR, every valid shift amount.
- ADD/ADDS/SUB/SUBS extended register: unsigned/signed byte, halfword, word;
  64-bit extensions in 64-bit operations; shifts 0-4.
- ADC/ADCS/SBC/SBCS with carry input, width-correct carry/overflow and NZCV.
- AND/ANDS/ORR/EOR and inverted BIC/BICS/ORN/EON shifted register, including ROR.

SP is permitted only in the extended forms' base and non-flag-setting destination
positions. Shifted, carry and logical operands use XZR/WZR at register 31.
Flag-setting destination 31 discards the value without losing flags. All W
results are zero-extended. Non-NZCV PSTATE bits and unrelated CPU state are
preserved. Logical flag-setting clears C/V. Aliases such as MOV, CMP and TST
inherit these encoding semantics, without a separate alias interpreter.

Operand width, arithmetic/flag handler, register offsets, rotation, retained-bit
mask and sign-fill mask are specialized at preparation. Extended operands use a
predecoded mask/sign bit and shift. Runtime shift handling is not a new opcode
switch. ADD's reserved ROR encoding, oversized W shifts, extended shifts >4,
nonzero extended-form bits 23:22, and all other excluded forms exit before effects.
For a deliberately bounded subset, 32-bit extended forms with option 3/7 remain
excluded, even when accepted by the reference decoder.

The parent's `avz_tp_supports_instruction` and cache-adapter declaration remain
present. The support predicate now admits these register forms but **still
rejects all memory**. Existing integrated block selection therefore gains only
the proven register coverage automatically, without requiring memory wiring.

## Explicit Memory API

New declarations are confined to the prototype header:

```c
int avz_tp_supports_instruction_with_memory(
    const AVZNativeInstruction *instruction);
AVZNativeBlockResult avz_tp_run_with_memory(
    const AVZThreadedPrototype *program,
    uint64_t max_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryFastPath *memory);
```

The optional subset is unsigned-immediate scalar STRB/STRH/STR W/STR X and
LDRB/LDRH/LDR W/LDR X. Base SP, data XZR, scaled offsets, and address addition
wrap are handled. Signed loads, pre/post-indexing, register-offset accesses,
pairs, SIMD/FP, exclusives, atomics and acquire/release forms remain excluded.

`avz_tp_create` can prepare those scalar operations, but existing `avz_tp_run`
continues to side-exit before them. Passing NULL memory to the new API is exactly
that same no-memory behavior. Disabled builds keep all old stubs and provide
stubs for both new APIs; they cannot allocate or execute a program.

Memory handlers call **only** `avz_native_fast_memory_read/write`. There is no new
MMU, raw guest-pointer access, private memory helper, relaxed atomic/lock path, or
independent dirty/exception implementation. Existing helpers retain translation,
permissions, host observation locks, dirty tracking, write generations, callback
and pending-fault behavior.

Every memory operation ends the run:

| Outcome | Result | Architectural state |
| --- | --- | --- |
| No memory context | Native UNSUPPORTED | Access not attempted; raw word reported |
| Helper succeeds; budget remains | `AVZ_TP_STATUS_REVALIDATE` (258) | Access retired once; PC advanced |
| Helper succeeds; budget exhausted | Native MAX_STEPS | Access retired once; PC advanced |
| Helper fails | `AVZ_TP_STATUS_MEMORY_FAULT` (259) | Access not retired; CPU/PC not written back |

Only the completed prefix is counted on fault. Helper-owned effects, including
partial slow-device effects and fault reporting, are not rolled back. Memory
failure is **not** an unsupported-op request to retry the access. The raw
unsupported-instruction field remains zero for memory faults.

Metadata needed for retirement is copied before calling the helper. No program
or operation metadata is read afterwards: a store or callback may invalidate
and destroy the snapshot. There is no tail successor after memory, including
after a read whose slow callback changes mappings. CPU and fast-memory context
must stay alive. The caller owns CPU access and must synchronize its existing
translation/architectural context before entry.

### Parent Integration Requirements

No parent-owned runtime/cache code has been wired by this workstream. Memory
integration needs **both** memory-aware eligibility and the new run call, not
just replacing `avz_tp_run`:

1. Opt memory-enabled block eligibility into the new predicate; keep the old
   predicate for callers without a valid native fast-memory context.
2. Preserve the existing one-block instruction cap and the minimum remaining
   timer/checkpoint/deadline budget. Every register handler still checks the
   exact per-instruction budget; memory returns after at most one access.
3. On REVALIDATE, discard cached local program assumptions, process required
   checkpoints and validate/reacquire code/mappings before resuming at current PC.
   Do the same existing host-boundary work on a budget-ending memory access.
4. On MEMORY_FAULT, use existing fault-delivery machinery with PC at the failed
   instruction; do not fall back and execute a potentially side-effecting access
   a second time. Account only the completed prefix.
5. Audit program/cache lifetime across callbacks with the validation owner.
   This API does not relax executable-page, mapping, shared-generation or
   cross-vCPU validation requirements.

The support predicates require public-decoder-produced operands. Preparation
always decodes raw words itself. It remains an immutable predecoded snapshot;
there is no guest fetch, interrupt injection, or standalone live-code validation
inside the prototype. Those remain parent integration contracts.

## Correctness And Code Shape

Host compiler: Apple Clang 17.0.0 (`clang-1700.6.3.2`), arm64 Darwin. The frozen
reference public switch and existing-threaded APIs are compiled without the
integrated prototype enabled, so the differential oracle is not circular.

Final normal run: **507,430 cases passed at -O3 and -O0 with
-fno-optimize-sibling-calls**. Disabled-mode checks passed. The test coverage
includes:

- Every legal shifted-register shift count/kind, varied register indices and
  XZR positions, aliased operands, W upper bits, and preserved PSTATE fields.
- ADC/SBC operand-edge cross products with all 16 starting NZCV combinations;
  signed extension boundaries including 0x80/0x8000/0x80000000.
- Mixed new-family sequences with taken/untaken conditional branches and every
  short budget, plus existing entry/exit, malformed encoding and long-loop tests.
- Scalar widths, SP/XZR/base-data aliases, scaled offset/address wrap, aligned,
  unaligned and page-crossing accesses, RAM-end faults and host-observed memory.
- Full CPU state, RAM bytes, dirty ranges, page write generations, slow-callback
  counts and native translation-fault reports compared with frozen public APIs.
- Invalid native page tables and valid EL1 read-only block mappings: loads
  succeed, stores permission-fault, and pending native faults do not fall through
  to slow callbacks.
- Successful and failing slow callbacks that destroy the active program;
  retirement uses captured operands and never executes the following instruction.
- All four serial-benchmark workloads receive bounded correctness tests even
  when benchmark timing is not requested.

Final `--ubsan` run: **507,430 cases passed**, using
`-O1 -g -fsanitize=undefined -fno-sanitize-recover=all`; disabled-mode checks also
passed. Both final test commands exited 0. There were no unexpected compilation
or correctness failures in this pass; the intentionally unsupported-musttail
compile is a checked negative test, not an implementation failure.

Emitted LLVM IR at -O0 contains **48 mandatory tail-call sites**. At
`-O3 -fno-optimize-sibling-calls`, all **48 register handlers** have an indirect
tail branch and **zero ordinary calls**. The **two memory handlers** call the
native memory helper and return with **no indirect tail successor**. The runner
checks these shapes explicitly and also checks the expected compile failure
when musttail support is forced unavailable. Unsupported compilers do not get
an ordinary-recursion fallback. Disabled mode compiles without musttail support.

No timing benchmarks were executed in this concurrent-agent pass. ASan was not
run: this request permits bounded normal/UBSan runs, and the earlier host ASan
initializer hang remains an unresolved validation limitation. This is not an
ASan/multicore/end-to-end UI signoff.

## Reproduction And Evidence

All commands run from `/Users/gmoran/Documents/Projects/arm64viz`. The runner
defaults to the provided immutable baseline, refuses a missing baseline instead
of silently using the working tree, copies a small C-only dependency set to a
temporary build directory, prints hashes, and deletes temporary builds on exit.

```sh
sh scripts/run-threaded-prototype.sh --verify
sh scripts/run-threaded-prototype.sh --test > /tmp/pinecone-threaded-coverage-test.log 2>&1
sh scripts/run-threaded-prototype.sh --ubsan > /tmp/pinecone-threaded-coverage-ubsan.log 2>&1
```

Exact **parent-only serial benchmark command** (not executed here):

```sh
AVZ_TP_REFERENCE_DIR=/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative sh scripts/run-threaded-prototype.sh --benchmark > /tmp/pinecone-threaded-coverage-serial-benchmark.log 2>&1
```

The benchmark compares the frozen switch/existing-threaded public executors
against the current prototype using four prepared workloads: 31 ADD + B,
ADD/SUBS/B.NE, shifted/logical/carry, and extended/32-bit carry. It alternates
execution order for six rounds of 30 million instructions after warmup, records
every raw sample, validates complete CPU state, and reports preparation cost
separately. It does not compare live integrated cached-chain behavior or the old
prototype's unsupported forms; there is no scalar-memory timing workload yet.
Do not extrapolate these loops to guest coverage or the 35-second Settings
launch. The parent owns captured-trace/serial integrated/UI measurement.

Frozen dependency hashes (directory is never written):

```text
/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative
ARM64VizNative.c                    d4409d07012afe1563c3137c2a29d0d57df7d48bd3be5a575914134258a2617c
ARM64VizBlockCache.c                c8d181bad0da1bb89f39ab77d9f8cb988d9c97fad65222210d3acc995b8e7122
ARM64VizGuestMemory.c               cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f
ARM64VizGuestMemoryInternal.h       33a2e4771c8da43800357e022cfafdd1aa289b5fcca53b9c95b5ae37d35c3622
include/ARM64VizNative.h            84282bcf7003e189937b6e126b8c572eeb30cf9fc72120ed19981aa7240e9ae4
ARM64VizThreadedPrototype.c         cfe4fcd11bef6c7b67d54edd3c3d30b3b936a29d4c883315cd382c6a91623a74
include/ARM64VizThreadedPrototype.h ff907cadecc4f3188bf5222e637f1890cba009d39a707bb28d3fb7a5a4100f44
```

Candidate hashes for the final test inputs:

```text
Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
7f98e86d96da7cddbcd6d5c794e760273568ab27e8e587af11c7e5d396a499ac
Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h
569fb6866aded277bf521453bf8b7f75c5f1a88d360d748557da008dbb8009cb
scripts/threaded-prototype-harness.c
ed92b6bac50541028c4ebdfc5a8cb2f6079665e4d267017e3bc0510fe5eea3b9
scripts/run-threaded-prototype.sh
817fadc1d3c06f30bfd0f6ee32fe1d5f76c8fe5d00c693b1746730fdcfa03255
```

## Remaining Limits

Logical immediate, bitfield/extract, conditional select/compare, variable shifts,
multiplication/division, indirect branches, SIMD/FP and all other excluded
families still side-exit. Paired memory remains with its existing executor and
separate owner. The new memory API is intentionally one-access-at-a-time; any
future continuation after memory must add the parent's validated lifetime and
generation protocol, not remove this boundary for speed. Extra predecoded fields
also increase per-program storage, which requires integrated cache-cost review.

## Narrow Store Callback Fix (Pending Validation)

Review found that scalar stores passed the full X-register value to the native
memory helper. RAM stores truncated it, but slow/physical device callbacks could
observe upper bits that the reference executor masks out. Store preparation now
specializes a width mask, applied before the helper call; the 64-bit case keeps
all bits. Terminal boundaries and successful-store exclusive clearing remain
unchanged.

The harness now records slow-write callback address, width and full value before
failure handling or RAM truncation. These observations are compared in all
existing memory cases. An additional 192 differential cases cover four widths,
four source values (including nonzero upper bits), normal/XZR sources, successful
and failing callbacks, and budgets 0/1/2. They assert the literal masked callback
value, single/no callback invocation, full CPU state, precise retirement/status,
and RAM/dirty-generation equivalence. Physical callback routing is not newly
tested by this addition; masking occurs before either helper route.

No compiler, correctness, sanitizer, emitted-code or timing run was performed for
this fix: execution is deferred until the parent completes Simulator ABBA.
The earlier counts and hashes above describe earlier inputs, not this revision.
Parent commands after ABBA (from the repository root):

```sh
sh scripts/run-threaded-prototype.sh --test > /tmp/pinecone-threaded-store-mask-test.log 2>&1
sh scripts/run-threaded-prototype.sh --ubsan > /tmp/pinecone-threaded-store-mask-ubsan.log 2>&1
```

Parent follow-up: both commands were rerun against the corrected implementation.
All **507,622 cases** passed at -O3, unoptimized musttail and UBSan, plus disabled
mode and machine-code checks. Actual logs are
`/tmp/threaded-coverage-parent-final.log` and
`/tmp/threaded-coverage-parent-final-ubsan.log`. Integrated results, the exclusive
state oracle correction, and the decision to keep optional memory disabled are
in `interpreter-four-agent-integration-2026-10-26.md`.
