# Phase 1: Host ARM64 Dispatch Analysis

Scope: current dirty checkout, static inspection only. No runtime code, flags,
guest images, Simulator state, or app installation were changed. No benchmark,
test executable, or application was run. Static compilation finished before
this report was written; the parent was notified in the task conversation.
This is a Phase 1 evidence contribution, not completion of Phase 1's measured
cost-attribution gate and not authorization to implement later phases.

## Findings

1. **Block entry/exit is the leading regression hypothesis.** The prototype
   wrapper caps each invocation to the decoded block's instruction count,
   even for an internal backward branch. The arithmetic fixture has four
   instructions. Its successful no-memory wrapper plus guarded entry/exit
   executes 160 static host instructions, including nine call instructions
   and two atomic read-modify-writes, before counting the handlers, other
   callee bodies, or the outer cache/checkpoint machinery. The established
   single-block executor can loop internally until its requested budget.
2. **Tail calls work; accumulating handler stack frames do not explain this
   build.** All 48 register handlers have an indirect `br`, no `bl`/`blr`, and
   no `sp` reference. The prototype still reloads architectural state and
   stack-resident execution metadata across those tail branches.
3. **Per-instruction validation/accounting is substantial, but not a complete
   explanation.** A continuing shifted-register ADD has 51 instructions,
   23 load instructions and three stores with the arithmetic harness's one
   non-null token. With all four tokens it has 63 instructions, 29 loads and
   three stores, including three acquire loads. These are counts, not cycles.
4. **The established arithmetic handler is not uniformly smaller.** Its
   shifted-register ADD path has a 54-instruction ordinary flag-helper call;
   its body plus next single-block dispatch totals 140 instructions. The
   prototype's smaller handler therefore cannot by itself explain the
   reported overall slowdown. Entry frequency and surrounding work matter.
5. **The prototype adds an operand stream rather than replacing decoded data.**
   `TPOperation` is 80 bytes versus a 32-byte established decoded instruction.
   Four operations plus sentinel/header allocate 432 bytes in addition to
   the existing cache block. Cache pressure is plausible, not measured here.

## Source Map And Provenance

References below use these exact files and line numbers in the inspected tree:

| Alias | File |
| --- | --- |
| TP | [ARM64VizThreadedPrototype.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c) |
| N | [ARM64VizNative.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c) |
| BC | [ARM64VizBlockCache.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizBlockCache.c) |
| H | [ARM64VizNative.h](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/include/ARM64VizNative.h) |
| R | [threaded-runtime-regression.c](/Users/gmoran/Documents/Projects/arm64viz/scripts/threaded-runtime-regression.c) |

Repository HEAD: `c3b3e957a9ee27bdcbe37c42925d98cf4563b19c`; this is NOT
a clean-tree source identity. All pre-existing changes were preserved.
The full native C/header and harness/script hash manifest is
[/tmp/arm64viz-phase1-dispatch.GtPQ5W/source-sha256.txt](/tmp/arm64viz-phase1-dispatch.GtPQ5W/source-sha256.txt).
It includes every repository source/header compiled or included here, plus
the cache/memory units and harness build scripts for context. Important hashes:

```text
a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f  ARM64VizNative.c
5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416  ARM64VizThreadedPrototype.c
79545f80af49ce93c60fa231c049fd0b9b714afbcca1f88bdbf87c3f6a5fee41  threaded-runtime-regression.c
ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9  ARM64VizGuestMemoryInternal.h
c6455e5d203cd1f84e0d31a999dfda66a7b402b5c82799b421de079b2c702de7  ARM64VizNative.h
94758ebdf1db44d4c97ae23b4973abd90ae6a0a92a5e7bd8a01f6b4b2ad1934a  ARM64VizThreadedPrototype.h
```

Compiler: Apple clang 17.0.0 (`clang-1700.6.3.2`), default target
`arm64-apple-darwin25.5.0`, from
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin`.
Host reports `Darwin arm64`. Assembly declares macOS deployment 26.0, SDK 26.2.
Compiler output is retained in `compiler.txt`; SDK system-header content was
not independently hashed. Hashes were captured immediately after compilation,
not from a versioned pre-build snapshot. Recheck them before reproducing.

All three assembly outputs use the same current compiler, C11, `-O3`, and
`AVZ_THREADED_PROTOTYPE_ENABLE=1`. No LTO, sanitizer, profile-guided optimization,
linking, or benchmark execution was requested. `runtime.s` compiles the actual
runtime harness translation unit, which includes N via R:3-6. `native.s`
compiles N separately. Their mapped-span executor, prototype wrapper, and
flag helper have identical emitted instruction text in this inspection;
`count-paths.pl` checks this. This is not a whole-binary identity test.

The runtime runner's actual command is at
[run-threaded-runtime-regressions.sh:23](/Users/gmoran/Documents/Projects/arm64viz/scripts/run-threaded-runtime-regressions.sh:23).
It compiles the harness, cache, guest memory and prototype as separate C
translation units at `-O3`, without explicit LTO. This inspection instead
emits assembly without linking, uses the harness's default include path for N
instead of defining the same absolute path, and does not compile cache/memory
implementation units. Thus helper internals outside these units are not counted.
[Package.swift:22](/Users/gmoran/Documents/Projects/arm64viz/Package.swift:22)
enables the prototype at build time and requests `-O3`; runtime selection is
separate. Existing `.build/release.yaml` contains an older macOS build command
with `-target arm64-apple-macosx13.0`, `-O2` followed by `-O3`, module/PIC/debug
flags, and no prototype unit/define. It is not proof of the installed iOS
Simulator build's flags and was not used as a build manifest here.

The prior benchmark reports arithmetic 5.410 ms established versus 16.290 ms
prototype, and memory 8.019 versus 20.433 ms. These are inherited measurements
from [executor-benchmark-2026-10-28.md:120](/Users/gmoran/Documents/Projects/arm64viz/docs/executor-benchmark-2026-10-28.md:120),
not reruns. Parent review found the microbenchmark log lacks source hashes
and compiler identity. The boot executable/disk identities do not repair
that gap. Neither this source nor these assembly files are established as
byte-identical to the earlier harness or installed executable. In particular,
the dirty guard/continuation changes are material. Build target, compiler,
LTO/whole-program treatment, SDK, and current source may change code generation.

The older standalone runner defaults to a frozen `/tmp` reference, compiles
a different harness, and verifies its own tail sites. Its timings are not
production comparisons. See
[run-threaded-prototype.sh:15](/Users/gmoran/Documents/Projects/arm64viz/scripts/run-threaded-prototype.sh:15).
It was read, not run.

## Representative Emitted Paths

The established executor already has indirect jump-table dispatch and semantic
fast paths. More precisely, current N:11507-11519 uses a C `switch` with local
label destinations, not a literal GNU label-address `goto *` expression.
Clang emits a computed indirect `br x10`; the benchmark's shorthand
"computed-goto" must not be misread as a switch-versus-threading experiment.
`runtime.s:13886` (`LBB37_614` and bb615):

```asm
add  x24, x19, x4, lsl #5  ; 32-byte decoded instruction
ldrh w9, [x24, #4]         ; instruction kind
sub  w8, w9, #1
cmp  w8, #104
b.hi LBB37_807             ; generic path outside dispatch table
adrp x12, lJTI37_0@PAGE
add  x12, x12, lJTI37_0@PAGEOFF
adr  x10, LBB37_616
ldrh w11, [x12, x8, lsl #1]
add  x10, x10, x11, lsl #2
br   x10
```

The dispatch table at `runtime.s:19375` maps kind 9 to `LBB37_733`
(shifted-register ADD) and kind 10 to `LBB37_693` (B/BL). N:11686-11730
implements the former; the no-flags 64-bit, zero-left-shift, non-XZR path
still calls `_add_with_carry_nzcv` at `runtime.s:16376` and reloads state
afterward. The helper has 54 instructions, one store, no loads, and `ret`.
The B path loads current PC and flags, skips link-register write, adds the
decoded signed offset, writes PC and steps, then returns to local dispatch
(N:11733-11741; `runtime.s:14328`, `16511`, `17459`).

The matching prototype shifted ADD begins at `prototype.s:2335`:

```asm
ldr  x8, [x0]              ; execution->cpu
ldrh w9, [x1, #60]         ; source byte offset
mov  w10, #65535
cmp  x9, x10
b.eq LBB21_6               ; XZR sentinel
ldr  x9, [x8, x9]
; source2 and destination have analogous offset/sentinel checks
ldrb w12, [x1, #68]        ; rotate, even when decoded shift is zero
ror  x12, x10, x12
ldr  x13, [x1, #48]        ; mask
and  x12, x12, x13
ldr  x13, [x1, #72]        ; sign fill
and  x10, x13, x10, asr #63
orr  x10, x12, x10
add  x9, x10, x9
str  x9, [x8, x11]         ; architectural destination
```

TP:164-172 precomputes a general rotation/mask/sign-fill representation, not
a separate zero-shift handler. TP:181-209 specializes arithmetic width and
flags, avoiding the established flag helper. Following semantic work:

```asm
ldr  x9, [x1, #24]
str  x9, [x8, #768]        ; architectural PC
ldr  x1, [x1, #8]          ; next operation
ldur q0, [x0, #8]          ; remaining, result.steps
adrp x8, lCPI21_0@PAGE
ldr  q1, [x8, lCPI21_0@PAGEOFF] ; vector {-1,+1}
add.2d v0, v0, v1
stur q0, [x0, #8]          ; commit both counters
ldr  x8, [x0, #72]
ldrb w8, [x8, #17]         ; program->retired
cbz  w8, LBB21_8
; local/shared/translation/memory-code token tests follow
; each non-null token adds load value, load expected, compare, branch
; the last three use ldapr for value loads in this target
ldr  x8, [x0, #8]          ; reload remaining
cbz  x8, LBB21_18          ; status=MAX_STEPS, ret
ldr  x2, [x1]
br   x2                   ; mandatory tail successor
```

TP:100-113 and 66-75 are the source for this repeated tail. The B handler
at `prototype.s:6396` performs two loads and one PC store, loads `taken`,
then executes the same accounting/validation sequence. Even the last
budgeted instruction validates generations before checking remaining.

## Static Counts

Counts follow selected successful paths, not all branches in a function.
One emitted ARM64 mnemonic is one instruction; a vector/pair load or store
counts once, even if it moves multiple words. Counts include explicitly
listed branches and helper instructions, not speculation, micro-ops, cache
misses, memory transactions, or CPU cycles. No cycle attribution was measured.

Prototype assumptions: all register operands/destination are ordinary
registers, no retirement or invalidation, and remaining budget is nonzero
after the instruction unless marked exit. One-token means only local code
epoch is non-null: R's arithmetic cache has no bound guest memory and passes
no memory context. Four-token means all pointers are present and current;
this is a full-system configuration model, not the arithmetic fixture.

| Prototype path, handler entry through tail branch/return | Instructions | Loads | Stores | Acquire loads (included) |
| --- | ---: | ---: | ---: | ---: |
| ADD immediate 64, one token | 40 | 19 | 3 | 0 |
| ADD shifted 64, one token | 51 | 23 | 3 | 0 |
| ADC 64, one token | 47 | 21 | 3 | 0 |
| AND shifted 64, one token | 52 | 23 | 3 | 0 |
| B, one token, continuing | 28 | 15 | 2 | 0 |
| B, one token, budget exit | 29 | 14 | 3 | 0 |
| ADD shifted 64, four tokens | 63 | 29 | 3 | 3 |
| B, four tokens, continuing | 40 | 21 | 2 | 3 |

For the source arithmetic fixture `ADD; ADC; AND; B` (R:252-277), a successful
four-step prototype invocation therefore traverses 179 handler instructions,
81 load instructions and 12 stores, using the budget-exit B row. It does not
execute four tail branches: the final B returns. All-null-token counts are
also in `counts.txt` but are not the current integrated harness configuration.

Established scope: ordinary semantic-candidate byte zero; valid single-block
PC; `instruction_pcs == NULL`; no halt, side exit, or exhausted budget;
64-bit non-XZR ADD operands with flags disabled and left shift zero; B not BL.
These are not mapped-superblock counts. Initial entry/validation and exits
are excluded. The dispatch row ends at the next handler's `br` target.

| Established selected path | Instructions | Loads | Stores | Ordinary calls |
| --- | ---: | ---: | ---: | ---: |
| Common next single-block ordinary dispatch | 28 | 5 | 1 | 0 |
| B body + commit only | 13 | 5 | 2 | 0 |
| B body + commit + next dispatch | 41 | 10 | 3 | 0 |
| ADD immediate body + commit + next dispatch | 70 | 17 | 6 | 0 |
| ADD shifted body + commit + next dispatch, including flag helper | 140 | 22 | 6 | 1 |

Reproducible basic-block sequences are encoded in `count-paths.pl`:
common dispatch `22,23,40,41,42,44,45,614,615`; B body
`693,1103,1279,1280,1281`; ADD immediate body
`757,759,1070,1277,1278,1279,1280,1281`; shifted ADD body
`733,734,735,957,958,959,960,961,1078,1079,1081,1082,21`, plus the full
`_add_with_carry_nzcv` helper. These labels refer to `runtime.s`, not source
line numbers. The count includes each selected basic block's branch mnemonic.

This evidence rules out the simple claim that every prototype handler executes
more host instructions. It does not establish that a prototype handler is
faster: load dependencies, branch prediction and instruction-level parallelism
are not captured by counts. Both executors write PC/step state in this output;
do not claim the established implementation keeps all such state in registers.

## Entry, State, And ABI

TP:94-113 gives every handler the same two-pointer C signature. In emitted
ARM64 `x0` holds `TPExecution *`, `x1` the operation pointer, and scratch
registers are reused. No dedicated guest-register cache is carried between
handlers. The 48 register handlers have zero stack adjustment, zero ordinary
calls, and one indirect successor site each. The unoptimized LLVM output
contains 50 `musttail call void %` sites, including load/store continuation
sites, even with `-fno-optimize-sibling-calls`. These facts concern emitted
code; no long-run stack stress test was executed here.

`avz_tp_run_guarded` reserves 224 bytes, including 144 bytes for TPExecution
and 80 bytes of saved registers; its normal handler entry is one `blr`.
The integrated wrapper reserves another 96 bytes. These frames are multiples
of 16 and do not grow per tail dispatch. The established mapped-span function
reserves 896 bytes once on entry (96 + 800); larger frame size alone is not
the relevant frequency comparison. Memory handlers have helpers/frames and
are deliberately excluded from the register-only no-call claim.

N:13749-13775 limits the prototype to one block and increments block/step
statistics with two relaxed atomics. Emitted `runtime.s:9775` and `9778`
use `ldadd`, not a mutex and not a retry loop on this target. There are
additional conditional boundary/fault counters on other paths. In the
four-step fixture the source implies 250,000 prototype invocations and
500,000 ordinary block/step atomic updates per million completed steps,
assuming unchanged code and no additional exits. This is a source-derived
frequency, not a newly observed counter sample.

The successful no-memory wrapper path has 65 instructions, six `bl` calls
(two epoch getters, program lookup, PC getter, count getter, guarded run),
and the two `ldadd`s. Guarded entry/exit has 95 instructions and three calls
(two token getters and handler `blr`), excluding all their callees. Together
160 instructions per invocation are additional to the 179 handler instructions
above. The 339 total is only a lower-level subtotal, not the full integrated
four-step cost: it omits getter/lookup bodies and all outer-chain work.
Paths and assumptions are captured in `count-paths.pl`.

By contrast N:11202-11249 can continue an internal single-block backward
branch without exiting. R:254 sets checkpoint limit 4096; N:14883-14910
calculates the remaining checkpoint budget. An established entry can cover
up to 4096 steps on this self-loop rather than the prototype's four. Exact
observed call counts and superblock selection require parent instrumentation.
Do not equate the theoretical 1024:1 budget ratio with a speed ratio.

Generation validation in TP:66-75 reloads token pointers and expected epochs
after every instruction. The established single-block path validates at entry
and callback transitions (N:11149-11159, 11194-11201), with additional mapped
trace boundary checks (N:11226-11238), not this same four-token tail. If cache
and fast memory bind the same guest memory, shared code token and memory-code
token can address the same epoch (BC:1877-1882;
ARM64VizGuestMemory.c:1015-1020; TP:580-585), causing two acquire reads of that
epoch in the four-token tail. Whether those checks can safely be amortized
is a correctness-contract question, not permission to remove them.

## Preparation And Footprint

BC:1511-1570 first checks entry identity/validity and code currency, then
negative eligibility or a cached program slot. A warm hit returns the program;
it does not re-decode or allocate and does not touch the LRU on that hit.
A miss scans decoded eligibility, copies raw words, and calls `avz_tp_create`.
TP:412-529 allocates `32 + 80*(count+1)` bytes and decodes each word again,
precomputing handlers, register offsets, branch pointers and conditions.
`tp_lookup` (TP:347-352) is arithmetic bounds/alignment checking, not a hash
probe or linear scan; emitted entry uses multiply-add by 80. Memory helper
internals are outside this report's scope.

The outer checkpointed chain prepares eligibility at N:14833-14834; the
wrapper prepares again at N:13757-13758 because a checkpoint may invalidate
the earlier selection. Both warm lookups still validate currency. The gate
also suppresses superblock composition for eligible blocks (N:14836-14855).
That can matter on real workloads independently of arithmetic dispatch.
Semantic fast paths remain in the established executor (N:11252-11499).
An eligible prototype block bypasses that executor's semantic selection;
ineligible work still uses native C, not Swift fallback. Coverage and lost
semantic/superblock opportunities need dynamic counts, not assumptions.

R:237-239 and R:266-268 start timing before the first chain run on a new cache.
Thus existing harness timings include first decode/eligibility/preparation,
although allocations of the context/cache occur outside the timed region.
They are not explicitly warmed-execution-only timings. The tiny single-block
loop should amortize initial preparation over many executions, but its time
share has not been measured. Larger-workload eviction behavior is unknown.

Compiler record-layout measurements (`layouts.txt:291-386`):

| Item | Bytes | Scope |
| --- | ---: | --- |
| Established decoded instruction | 32 | No per-block metadata |
| Prototype operation | 80 | Includes handler, next/taken pointers, PC/immediates |
| Prototype program header | 32 | Followed by operations plus one sentinel |
| Prototype execution state | 144 | Per invocation, stack resident |
| Four-operation prototype program | 432 | Header + 5 operations |
| Sixteen-operation prototype program | 1392 | Header + 17 operations |

The established decoded block is retained, including its 16-instruction
array (BC:49, H:182); these prototype bytes are incremental. The cache owns
at most 256 programs (BC:171-175, 1557-1558), yielding at most 356,352 bytes
of program payload at sixteen operations each, excluding allocator overhead,
slot metadata and temporarily pinned retired programs. This is not an RSS
measurement. The standalone API permits larger programs than integrated blocks.

Static emitted instruction bytes (four per instruction, all control-flow
paths counted once; excludes alignment, literals, jump tables, linker changes,
and separately emitted callees):

| Emitted scope | Instruction bytes |
| --- | ---: |
| 48 prototype register handlers combined | 15,008 |
| Prototype shifted ADD / ADC / AND / B individually | 320 / 304 / 324 / 184 |
| Prototype load / store handlers | 888 / 1,060 |
| Entire prototype translation unit | 20,064 |
| Established mapped-span function alone | 30,976 |

This is not a like-for-like replacement code-size comparison: the established
function covers many more instruction kinds and semantic paths, has additional
callees, and remains linked in hybrid mode. The prototype adds code; duplicating
the validation tail across 48 handlers is visible. No I-cache/D-cache miss
rates or linked section sizes were measured. Layout and working-set effects
remain hypotheses.

## Ranked Experiments, Not Implementations

| Rank | Hypothesis and evidence | Parent-owned experiment and discriminating result |
| --- | --- | --- |
| 1 | Repeated four-step entry/exit, lookup, and counters dominate arithmetic regression. Source cap plus 160-instruction entry/exit subtotal supports this; no isolated timing yet. | Capture actual invocation/lookup/checkpoint counts. On a separately approved offline variant, vary the self-loop execution budget while preserving state/step assertions and bounded checkpoints; compare with unmodified established C. A gain tracking reduced entries supports this cause. Any validation changes need a distinct experiment. |
| 2 | Per-instruction metadata traffic and generation checks are costly, particularly with shared memory. Static tails perform 0-3 acquire loads depending on configuration. | Separately time pre-created guarded programs with one versus four valid tokens; record retired instructions/cycles and loads where available. Any omit-check variant must be an explicitly approved, offline diagnostic with no mutation/concurrency claim. Keep entry frequency fixed. |
| 3 | Lost superblock/semantic execution and negative eligibility work magnify real-workload cost. Eligibility gates composition, and warm lookups still check currency. | Gather block-size, eligibility, cache creation/hit/negative-hit, superblock and semantic-fast-step distributions on parent-controlled workloads. Separate first preparation, warm execution and eviction-heavy runs. Do not compare old standalone results to production. |
| 4 | Operation-stream and duplicated-tail working sets harm cache locality. 80-byte operations and additive code footprint establish size, not misses. | Sweep an approved synthetic working set through several block counts, keeping guest instructions and semantic mix fixed. Measure cache misses/CPU time and actual allocations. No compact-stream optimization is implemented here. |
| 5 | Generic zero-shift specialization leaves avoidable handler work. Rotation/mask/sign-fill remain at shift zero, but prototype ADD is already smaller than established ADD. | Only after ranks 1-3 are separated, compare approved offline operand-form variants under identical entry/validation policy; verify full guest state. Do not infer production benefit from raw opcode counts. |

Missing evidence: cycle/sample attribution, exact prior microbenchmark source
identity, installed executable disassembly/build flags, observed cache and entry
counts, warmed-only costs, and hardware cache events. This report therefore
cannot assign percentages of the 3.01x/2.55x regressions to individual causes.
It does not propose weakening generation or checkpoint correctness contracts.

## Commands And Artifacts

All command paths below are relative to the explicitly selected repository
unless absolute. These are the exact static generation commands used, with
the resulting temporary directory substituted. Do not rerun compilation while
the parent owns an active timed run. No benchmark runner was invoked.

```sh
cd /Users/gmoran/Documents/Projects/arm64viz
pwd
git status --short
git rev-parse HEAD
clang --version
uname -sm
xcrun --show-sdk-path
mktemp -d /tmp/arm64viz-phase1-dispatch.XXXXXX
# Returned /tmp/arm64viz-phase1-dispatch.GtPQ5W
clang -std=c11 -O3 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I Sources/ARM64VizNative/include -I Sources/ARM64VizNative -S Sources/ARM64VizNative/ARM64VizThreadedPrototype.c -o /tmp/arm64viz-phase1-dispatch.GtPQ5W/prototype.s
clang -std=c11 -O3 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I Sources/ARM64VizNative/include -I Sources/ARM64VizNative -S scripts/threaded-runtime-regression.c -o /tmp/arm64viz-phase1-dispatch.GtPQ5W/runtime.s
clang -std=c11 -O3 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I Sources/ARM64VizNative/include -I Sources/ARM64VizNative -S Sources/ARM64VizNative/ARM64VizNative.c -o /tmp/arm64viz-phase1-dispatch.GtPQ5W/native.s
clang -std=c11 -O0 -fno-optimize-sibling-calls -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I Sources/ARM64VizNative/include -I Sources/ARM64VizNative -S -emit-llvm Sources/ARM64VizNative/ARM64VizThreadedPrototype.c -o /tmp/arm64viz-phase1-dispatch.GtPQ5W/prototype.ll
clang -std=c11 -O3 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I Sources/ARM64VizNative/include -I Sources/ARM64VizNative -Xclang -fdump-record-layouts -fsyntax-only Sources/ARM64VizNative/ARM64VizThreadedPrototype.c > /tmp/arm64viz-phase1-dispatch.GtPQ5W/layouts.txt
shasum -a 256 Sources/ARM64VizNative/*.c Sources/ARM64VizNative/*.h Sources/ARM64VizNative/include/*.h scripts/threaded-runtime-regression.c scripts/threaded-prototype-harness.c scripts/run-threaded-runtime-regressions.sh scripts/run-threaded-prototype.sh Package.swift > /tmp/arm64viz-phase1-dispatch.GtPQ5W/source-sha256.txt
clang --version > /tmp/arm64viz-phase1-dispatch.GtPQ5W/compiler.txt
shasum -a 256 /tmp/arm64viz-phase1-dispatch.GtPQ5W/prototype.s /tmp/arm64viz-phase1-dispatch.GtPQ5W/runtime.s /tmp/arm64viz-phase1-dispatch.GtPQ5W/native.s /tmp/arm64viz-phase1-dispatch.GtPQ5W/prototype.ll /tmp/arm64viz-phase1-dispatch.GtPQ5W/layouts.txt > /tmp/arm64viz-phase1-dispatch.GtPQ5W/emitted-sha256.txt
perl /tmp/arm64viz-phase1-dispatch.GtPQ5W/count-paths.pl > /tmp/arm64viz-phase1-dispatch.GtPQ5W/counts.txt
grep -c 'musttail call void %' /tmp/arm64viz-phase1-dispatch.GtPQ5W/prototype.ll
shasum -a 256 -c /tmp/arm64viz-phase1-dispatch.GtPQ5W/source-sha256.txt
git diff --check -- docs/phase1-dispatch-analysis.md
```

Read-only exploration used `cat`, `nl -ba`, `sed -n`, `head`, `grep -n/-A/-B`,
`find .build`, and `git diff -- Sources/ARM64VizNative/ARM64VizNative.c` on the
referenced files. `rg` was attempted but is unavailable on this shell, so grep
was used. The report and temporary counting script were written via
`apply_patch`. All five static compiler invocations returned exit status zero.

Complete generated artifact set, all under
[/tmp/arm64viz-phase1-dispatch.GtPQ5W](/tmp/arm64viz-phase1-dispatch.GtPQ5W):

- `prototype.s`: current prototype optimized ARM64 assembly.
- `runtime.s`: current runtime harness optimized ARM64 assembly.
- `native.s`: separate native executor optimized ARM64 assembly.
- `prototype.ll`: unoptimized mandatory-tail LLVM IR.
- `layouts.txt`: compiler record-layout output.
- `compiler.txt`: compiler version/target/path.
- `source-sha256.txt`: repository source/header/build-script hashes.
- `emitted-sha256.txt`: hashes of the five compiler outputs.
- `count-paths.pl`: deterministic selected-path and footprint counter, with
  checks for 48 register handlers, no register-handler calls/SP references,
  and an indirect tail branch in each register handler.
- `counts.txt`: complete counter output, including all-null-token paths,
  entry/exit counts, and native-versus-harness instruction-text comparison.

No binary, object, Simulator artifact, runtime flag modification, or new timing
sample was produced. Temporary artifacts are not durable repository storage;
the parent should retain them with the Phase 1 evidence bundle.
