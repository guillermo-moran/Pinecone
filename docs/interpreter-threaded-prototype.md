# Isolated Musttail Interpreter Prototype

## Scope And Opt-In

This is an experimental, no-JIT, predecoded tail-call interpreter. The original
agent implementation was standalone. The subsequent Simulator integration below
connects its supported subset to the native cached-chain executor. It does not
enable Swift fallback or use QEMU.

## Simulator Integration

The Swift package compiles the prototype, and Simulator backend instances enable
it by default. `PINECONE_THREADED_PROTOTYPE=0` disables runtime use; physical-device
and CLI runtime defaults remain unchanged. This is not a complete replacement
interpreter or an Android compatibility claim.

Only fully supported decoded blocks of at least two instructions qualify. The
block cache owns at most 256 auxiliary programs per vCPU, keyed by decoded-entry
serial and revalidated against code and translation generations. Cache clear and
destruction release them; collision/replacement releases the previous program.
Memory/system/vector/unsupported blocks and existing mapped superblocks retain
the current native C execution path. No Swift fallback is introduced.

Each invocation retires at most one decoded block's instruction count, including
backward branches, before returning to the existing native timer/IRQ and host
checkpoint machinery. Eligibility is rechecked after any host checkpoint. State
remains architectural at every exit. Primary-vCPU runtime usage is exported as
`threadedPrototypePrimary` in the performance JSON (enabled, blocks, steps).

`scripts/run-threaded-runtime-regressions.sh` compares enabled/disabled runtime
execution across mixed blocks, budgets, checkpoint-triggered code invalidation,
128 cache-clear/invalidation replacements, and runtime opt-out. `--ubsan` repeats
the tests with undefined-behavior checking. Standalone prototype timings below
do not measure this integrated selection policy or Phosh responsiveness.

The new translation unit defaults to disabled stubs. Explicitly compile it with
`-DAVZ_THREADED_PROTOTYPE_ENABLE=1` to enable it. An enabled build requires
compiler-enforced `__attribute__((musttail))`; lack of support is a hard compile
error, not ordinary recursion, a central switch, or an alternate executor.

Files owned by this workstream:

- `Sources/ARM64VizNative/ARM64VizThreadedPrototype.c`
- `Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h`
- `scripts/threaded-prototype-harness.c`
- `scripts/run-threaded-prototype.sh`
- `docs/interpreter-threaded-prototype.md`

## Representation And Execution

`avz_tp_create` copies raw words into an opaque immutable program, using the
existing public C decoder and specializing the decoded operands. It accepts
1-4096 aligned, contiguous instructions and rejects a wrapped source range.
Preparation prelinks fallthrough and branch-target operation pointers, resolves
SP/XZR register offsets, chooses width/arithmetic/flag-specific handlers,
precomputes move masks and PC-relative values, and builds a condition truth table.
No instruction decoding or opcode switch occurs during execution. The switch in
`avz_tp_create` runs only during preparation.

Each of 16 executing handlers has exactly the same C signature and mandatory
indirect tail-calls the next predecoded handler. The caller-owned CPU is updated
after each complete instruction, including PC and NZCV. A per-instruction budget
check occurs before dispatch. There is no architectural state hidden in a host
register cache. Two nonexecuting terminal handlers report outside-program and
unsupported-subset exits. The public entry function's ordinary call owns one
execution frame; the handler chain does not grow the stack.

Supported forms:

- Exact architectural NOP (`0xd503201f`), not arbitrary hints.
- 32/64-bit ADD, ADDS, SUB, SUBS immediate, both immediate shifts; SP source,
  SP destination for non-flag forms, XZR destination for flag-setting forms.
- 32/64-bit MOVZ, MOVN, MOVK, all valid halfword positions, including W-register
  zero extension and XZR discard.
- ADR and ADRP, including XZR discard.
- Immediate B/BL, including LR update and targets inside or outside the program.
- B.cond (all 16 conditions), 32/64-bit CBZ/CBNZ, and all TBZ/TBNZ bit positions.

Reserved add-immediate bit 23 is rejected even though the current reference
decoder accepts it. Invalid move-wide encodings are also unsupported. All other
instructions side-exit *before execution*, with unchanged PC pointing at the
excluded instruction, its raw word in `unsupported_instruction`, and only the
completed prefix counted in `steps`. This is a subset exit, not a claim that the
reference executor cannot execute that word.

Budget exhaustion takes precedence over dispatching an excluded/outside target.
Thus a budget ending immediately before an excluded instruction returns
MAX_STEPS; resuming at that PC with a positive budget returns UNSUPPORTED and zero
steps. Zero budget also precedes initially halted/outside state. An initially
halted CPU with positive budget returns HALTED. HALT itself is excluded. Invalid
API inputs do not mutate CPU state. Disabled builds return DISABLED, allocate no
program, and do not execute. `generic_dispatches` reports retired handler count;
no semantic fast-path or block-cache counters are claimed.

## Synchronization Boundary

This API takes an immutable standalone code snapshot, **not live guest memory**.
Its caller must own the CPU exclusively and guarantee snapshot validity for the
run. There is no MMU, instruction fetch, executable-page generation token,
interrupt/checkpoint, shared-memory, exception-delivery or self-modifying-code
integration. Do not connect it to a running guest without implementing those
contracts. The harness's source-word mutation test verifies ownership of the
snapshot, not live-code invalidation.

Every load/store, exclusive, atomic, barrier, cache/system operation, exception,
wait and register-indirect branch is deliberately excluded. No memory or
exception synchronization is elided for speed. The fault-handoff tests first
execute a supported prefix, then resume the **existing public C executor** at the
side-exit PC; its callbacks perform/fail the memory operation. The prototype does
not itself deliver memory faults. Guest fetch faults cannot be tested through
this snapshot API and are not claimed covered.

## Reproduction

From `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
sh scripts/run-threaded-prototype.sh --test
sh scripts/run-threaded-prototype.sh --ubsan
sh scripts/run-threaded-prototype.sh --sanitize
sh scripts/run-threaded-prototype.sh --benchmark
sh scripts/run-threaded-prototype.sh --verify
```

Each run makes a small temporary copy of only the reference C dependencies and
headers, prints compiler/host information and SHA-256 hashes, and removes its
build products on exit. `CC` selects the compiler. Set `AVZ_TP_REFERENCE_DIR` to
an already captured native-source directory to keep the same dirty-tree reference
across runs. `AVZ_TP_EMIT_DIR` optionally retains LLVM IR, assembly and the negative
compiler-test log. No compiled guest code is generated or mapped executable.

The initial dirty/untracked status was read before any edit. Before adding the
prototype, the current native source directory was copied to:

```text
/tmp/arm64viz-threaded-prototype-baseline.bI2z60/ARM64VizNative
```

The measured reference is that dirty snapshot, not git HEAD. Its key hashes are:

```text
ARM64VizNative.c  9432c35819bbd69653195c2db2151a6996195ecead85209161eb23cb3d3ecced
ARM64VizNative.h  8742cb9002492a359b01bf09c3637c4f6a8f934b81416b75520c5ec9ed9a1d12
```

Commands used against that fixed snapshot:

```sh
env AVZ_TP_REFERENCE_DIR=/tmp/arm64viz-threaded-prototype-baseline.bI2z60/ARM64VizNative AVZ_TP_EMIT_DIR=/tmp/arm64viz-threaded-prototype-emitted sh scripts/run-threaded-prototype.sh --test
env AVZ_TP_REFERENCE_DIR=/tmp/arm64viz-threaded-prototype-baseline.bI2z60/ARM64VizNative sh scripts/run-threaded-prototype.sh --sanitize
env AVZ_TP_REFERENCE_DIR=/tmp/arm64viz-threaded-prototype-baseline.bI2z60/ARM64VizNative sh scripts/run-threaded-prototype.sh --ubsan
env AVZ_TP_REFERENCE_DIR=/tmp/arm64viz-threaded-prototype-baseline.bI2z60/ARM64VizNative sh scripts/run-threaded-prototype.sh --benchmark
```

## Correctness And Emitted Code

Host: Darwin arm64, Apple Clang 17.0.0 (`clang-1700.6.3.2`), target
`arm64-apple-darwin25.5.0`. CPU model lookup through sysctl was sandbox-denied;
no particular Apple CPU model is assumed.

Initial `--test` results: **271,772 cases passed** at both `-O3` and
`-O0 -fno-optimize-sibling-calls`. Disabled-mode checks passed, including no CPU
mutation. The harness compares full CPU state against the public
`avz_native_run_decoded_block_registers` and, for nonhalted entry, also
`avz_native_run_threaded_decoded_block_registers`. Pre-halted behavior is compared
only to the former because the existing threaded API does not inspect it.

Coverage includes all source/destination register indices for immediate
arithmetic, boundary and seeded random register values, carry/overflow and upper
PSTATE preservation, all move-wide positions, all NZCV/condition combinations,
SP/XZR/W semantics, branch/link/PC wrap, every TBZ bit, deterministic mixed
sequences, budget limits, unsupported boundaries, invalid inputs, owned-snapshot
behavior, maximum program size, and callback success/fault handoff. Unrelated
SIMD/FP/exclusive state is checked unchanged. A 1,000,001-instruction loop also
runs in the unoptimized configuration to exercise bounded-stack dispatch.

`--ubsan` also passed **271,772 cases** and the disabled-mode checks with
`-O1 -g -fsanitize=undefined -fno-sanitize-recover=all`. **ASan is unvalidated**:
the combined address/undefined build linked, but the host ASan runtime hung
before `main`. A one-second `sample` of the identified harness showed recursive
`__asan::AsanInitInternal` via `InitializeShadowMemory` / `get_dyld_hdr` /
`_Block_copy` / malloc, spinning in `StaticSpinMutex::LockSlow`. Only that harness
was terminated (exit 143). This is not a passing memory-safety test. The sample is
at `/tmp/arm64viz-threaded-prototype-sanitize-sample.txt`. The `--sanitize` runner
now bounds each harness process with a 60-second alarm; the alarm survives exec
and cannot select unrelated agents' processes.

Verification detects **16 mandatory tail-call sites** in LLVM IR emitted at
`-O0 -fno-optimize-sibling-calls`. In `-O3 -fno-optimize-sibling-calls` AArch64
assembly, all 16 executing handler bodies contain indirect `br` dispatch and
**zero ordinary call instructions**. For example, `_tp_add64` ends its continuing
path with:

```asm
ldr x2, [x1]
br x2
```

The script fails unless every executing handler meets that machine-code check.
Forcing the compiler-support predicate to zero in an enabled build is verified
to fail with the explicit musttail diagnostic. Disabled mode compiles with that
predicate forced to zero. Actual execution has only been tested on this arm64
Clang host; the verifier understands x86-64 indirect jumps but that does not
constitute tested x86-64 or iOS support.

## Measurement Method

Benchmarks prepare both representations outside the timed region and execute
30,000,000 guest instructions per sample, six samples per executor/workload,
after a 1,000,000-instruction warmup per executor. Each round alternates order
between reference-switch / existing-threaded / prototype and its reverse.
Every sample checks completed steps/status, prints a checksum and fast-path step
count, and compares complete CPU state across all three implementations.
Preparation allocation/decode/free cost is measured separately over 10,000 runs.

Workloads are a 31-ADD + backward-B loop and a three-instruction ADD/SUBS/B.NE
loop. The reference uses the same predecoded public APIs as correctness testing,
not cached-chain/production mapped-superblock execution. Entry copying differs
between public wrappers and this direct-CPU API but occurs only once per
30-million-instruction run. The comparison includes operand specialization and
prelinked successor lookup savings, not just the dispatch instruction itself.

These are **rough initial microbenchmarks**, with five concurrent workstreams
and likely compilation noise. The parent should rerun serially before drawing
performance conclusions. They measure neither UI latency, guest boot, Phosh
responsiveness, nor production chain throughput. Memory is not supported, so no
memory throughput result is reported.

## Initial Results

All 36 timed samples retired exactly 30,000,000 instructions, reported zero
semantic fast-path steps, and agreed on complete CPU state. Checksums were
`927758e3b90fdd72` (31-ADD loop) and `d0ca1d0fa6c68ebe` (conditional loop).
Times below are seconds; median is the mean of the middle two of six samples.

| Workload | Executor | Median | Minimum | Maximum |
| --- | --- | ---: | ---: | ---: |
| 31 ADD + B | Reference switch | 0.275039 | 0.271631 | 0.290873 |
| 31 ADD + B | Existing threaded | 0.244299 | 0.235802 | 0.271917 |
| 31 ADD + B | Musttail prototype | 0.110174 | 0.109273 | 0.116990 |
| ADD/SUBS/B.NE | Reference switch | 0.234308 | 0.226732 | 0.239703 |
| ADD/SUBS/B.NE | Existing threaded | 0.255750 | 0.246994 | 0.290469 |
| ADD/SUBS/B.NE | Musttail prototype | 0.112697 | 0.109584 | 0.114308 |

Median elapsed-time ratios (reference / prototype): **2.496x switch and 2.217x
existing-threaded** for 31 ADD + B; **2.079x switch and 2.269x existing-threaded**
for ADD/SUBS/B.NE. These are not estimates of production speedup.

Raw alternating rounds, with columns reordered here for comparison:

| Round | ALU switch | ALU existing | ALU prototype | Conditional switch | Conditional existing | Conditional prototype |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.290873 | 0.271917 | 0.116990 | 0.226732 | 0.290469 | 0.109584 |
| 2 | 0.283199 | 0.245615 | 0.114570 | 0.227797 | 0.246994 | 0.109612 |
| 3 | 0.274949 | 0.244130 | 0.110742 | 0.236907 | 0.260540 | 0.114308 |
| 4 | 0.275129 | 0.244467 | 0.109605 | 0.231709 | 0.251731 | 0.112722 |
| 5 | 0.274545 | 0.236486 | 0.109295 | 0.239348 | 0.255909 | 0.114074 |
| 6 | 0.271631 | 0.235802 | 0.109273 | 0.239703 | 0.255591 | 0.112673 |

Separate 10,000-iteration create/decode/free measurements were **534.7 ns** per
32-instruction program and **71.9 ns** per three-instruction program. Allocation
size was respectively **2,392 bytes** and **304 bytes** (72 bytes per predecoded
operation, one terminal sentinel, 16-byte header). These preparation figures
are single rough measurements, not latency percentiles or a cache break-even
analysis. The source snapshot occupies approximately 904 KiB; retained emitted
code occupies approximately 136 KiB. Temporary builds are removed by the runner.

## Remaining Work

No production-backend selection is proposed. A larger subset would need
register ALU/shift/logical operations, indirect branches, memory callbacks with
precise faults and existing synchronization, system/exception exits, and SIMD/FP.
Production integration additionally needs code-fetch and mutation/translation
validation, cache ownership/lifetime rules, bounded interrupt/checkpoint cadence,
multicore safety, memory observability and all current exception contracts.
Those requirements cannot be replaced with this API's immutable-snapshot
precondition. A realistic next evaluation would use captured traces, measured
subset side-exit rates and preparation/cache costs, then serial end-to-end UI
measurements owned by the parent.
