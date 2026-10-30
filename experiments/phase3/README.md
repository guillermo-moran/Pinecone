# Phases 3-6: Isolated ARM64 Gadgets

The canonical executor now lives in `Sources/ARM64VizNative/Assembly` and is
linked by SwiftPM/iOS. The files here forward to that same implementation for
offline testing; they are not a second copy. The VM adapter is opt-in through
`PINECONE_ASSEMBLY_EXECUTOR=1`. It dispatches supported blocks and retains native
C for other blocks. No guest image, Swift fallback policy or production service
window changes. Phase 4 additionally fixes a leaf-permission bug in the shared
C walker. See the historical [Phase 3 results](../../docs/phase3-gadget-results.md)
and [Phase 4 results](../../docs/phase4-memory-results.md). Bounded chaining is
documented in the [Phase 5 report](../../docs/phase5-chaining-results.md).
Phase 5's offline gate now passes two accepted repeat cohorts. Its benefits are
measured at windows of 64 or more instructions; four-instruction calls remain
slower through the chain API. This is not an app-integration/default change.
Phase 6's first hot-form expansion and its remaining gates are documented in
the [Phase 6 progress report](../../docs/phase6-hot-work-results.md).
The next batch extends [scalar addressing](../../docs/phase6-addressing-results.md).
The following batch adds [scalar pairs](../../docs/phase6-pair-results.md).
[Indirect branches](../../docs/phase6-indirect-results.md) now resolve through
pinned operation ranges. That audit also fixes BLR x30 ordering in the shared
C core; neither assembly integration nor app defaults change.
The [short-entry follow-up](../../docs/phase6-entry-results.md) inlines memory
preparation only in standalone entry and fixes the dispatch region's alignment.
Short scalar calls improve in repeat cohorts; longer scalar/chain controls
remain mixed, so this does not pass a general no-regression or promotion gate.
The [conditional follow-up](../../docs/phase6-conditional-results.md) adds
same-binary entry attribution and conditional selects/compares. Independent
flag tests, three C references and existing-path controls pass; the installed
executor was unchanged at that report's measurement time. See the
[VM integration report](../../docs/phase7-assembly-integration.md) for current status.

## Scope

Precompiled Darwin ARM64 handlers execute a prepared, immutable operation stream
without JIT or recursive C calls. The current subset includes:

- Exact NOP, ADD/SUB immediate (32/64-bit, with/without flags), including CMP/CMN.
- ADD/SUB register with LSL/LSR/ASR and ADC/SBC (32/64-bit, with/without flags).
- AND/ORR/EOR/ANDS with all four shifts and inverted operands (BIC/ORN/EON/BICS).
- Logical-immediate masks, including SP destinations for non-flag-setting forms.
- MOVN/MOVZ/MOVK, ADR/ADRP, B/BL, B.cond, CBZ/CBNZ and TBZ/TBNZ.
- BR/BLR/RET with bounded lookup in the current program or validated chain.
  Pointer-authenticated branches remain outside this subset.
- CSEL/CSINC/CSINV/CSNEG and register/immediate CCMP/CCMN in W/X forms.
- Scalar byte/halfword/word/doubleword loads/stores with unsigned-immediate,
  unscaled, pre/post-index and register-offset addressing (UXTW/LSL/SXTW/SXTX).
- Sign-extending scalar loads to W/X destinations, through `ag_run_memory`.
  The register-only entry still rejects memory.
- Scalar LDP/STP and LDNP/STNP (32/64-bit), and LDPSW, with offset and valid
  pre/post-index modes. SIMD pairs remain excluded.

SP/XZR roles, zero-extension, flags and decoded operands are specialized during
preparation. Extended forms outside this list, other memory forms, atomics, hints
other than NOP, barriers and privileged instructions exit before execution with
the original instruction and exact retired prefix. This subset is deliberately
not a complete ARM64 interpreter. LDTR/STTR unprivileged forms and pre/post-index
overlaps between Rt and Rn (except SP/XZR) are deliberately rejected, not given
ordinary privileged or arbitrary writeback semantics. The existing C executor
remains the production path and correctness reference.

Host arm64e and other platforms fail closed in `ag_available`; the assembly file
emits no handlers on incompatible targets. There are no guest-to-host executable pointers:
handler targets are symbols in the precompiled host binary.

Scalar address metadata fits within the original 48-byte operation. Register
address preparation and immediate entries share the validated RAM body. Signed
results and writeback are decode-selected handlers; ordinary loads/stores do
not test a writeback flag on each access. Writeback commits only after success.
The terminal helper captures the original base before calling out; callbacks
may retire the program, but cannot free its pinned operation until return.
Pair metadata also fits in 48 bytes. The inline pair path requires the entire
span to be on one validated RAM page, aligned to the element width, with the
same observation/code safeguards as scalar accesses. Other pairs terminate in
the memory helper. Loads commit neither destination on a second-access fault;
stores preserve a completed first callback write if the second callback fails.
PC/base writeback occurs only after both succeed. Duplicate load destinations
and non-SP writeback aliases with either pair register exit before execution.

Indirect branches capture their source before any LR write, commit PC and
retire once, validate generations/budgets, then resolve only to pinned entries.
Single-program entries are operations; chain entries are service gates, even
for self-loops or interior targets. Missing/misaligned targets exit with the
target PC preserved for the outer fetch/fault boundary. No guest address is
cast to an executable host pointer. A sorted range table uses bounded binary
search (at most 256 blocks); no C lookup/helper call is added.

## Files

| File | Responsibility |
| --- | --- |
| `gadget.h` | Caller ownership and bounded-run API |
| `gadget_internal.h` | 48-byte operations and run layout |
| `gadget.c` | Decode through the existing decoder, specialize operands, validate arguments |
| `chain.c` | Owner-pinned immutable block graph, cached code-page proofs and bounded chain entry |
| `chain_tests.c` | Cross-block differential/lifetime tests, throughput and event-service cohorts |
| `offsets.c` | Generate assembly offsets and C static assertions from the same types |
| `gadget_arm64.S` | One entry/exit frame, direct-threaded register and inline scalar RAM handlers |
| `memory.c` | Capture owner-confined mapping metadata; authoritative terminal access/commit helpers |
| `memory_tests.c` | Differential RAM, permission, observer, callback, SMP and timing fixtures |
| `abi_probe.S` | Seed/check callee-saved host registers, vectors, FP control/status and stack/frame |
| `reference.c` | Test-only access to the unchanged production direct-CPU C core |
| `harness.c` | Three-reference differential checks, exit/ABI/invalidation tests and timing fixtures |
| `run.sh` | Build, inspect emitted dispatch/CFI, run enabled and disabled checks |
| `measure.py` | Load-gated sample collection with optional reversible Simulator-process pause |
| `test_measure.py` | Compiler/test interference, Simulator-state and load-threshold checks |
| `profile_coverage.py` | Classify retained hot-PC prefixes with the actual decoder/preparer; no dynamic-coverage inference |

## Execution Contract

The [Phase 2 contract](../../docs/phase2-execution-contract.md) remains governing.
The private register convention uses x19 for CPU, x20 for the operation pointer,
x21 for remaining allowance, x22 for retired steps, x23 for control/result and
x24 for the memory view.
Guest architectural state is committed in `AVZNativeCPU` at each instruction.
Host x18 and vector state are not used by the executor. All paths share one
64-byte executor frame; hot handlers tail-branch without calling C. Only the two
terminal memory exits call C (with ordinary helper frames), then return without
using a cached continuation proof.

Mach-O handler labels are alternate entries within the same unwind range, not
independent functions. CFI describes prologue, active frame and restored epilogue.
The assembly probe checks preservation across budget, outside, unsupported and
revalidation exits, including a million-instruction run. Callback tests clobber
volatile registers and the volatile upper halves of v8-v15, verify the actual
C ABI's d8-d15 preservation, and unwind through the assembly frame. Emitted-code
inspection permits only the two named terminal helper calls and rejects x18
references. Asynchronous exception/signal-unwind integration and arm64e remain
unverified.

The caller owns the immutable snapshot for the complete call and serializes its
creation/destruction. Each run pins the program; callback destruction retires
it, with reclamation deferred to the final owner return. Callbacks must not
destroy the memory context, RAM, CPU or guard storage. `ag_chain_run` pins an
entire immutable graph of private programs, so direct successors cannot dangle
during owner callback retirement. A production cache adapter is still absent.

Optional guards include one owner-local epoch and three shared atomic epochs,
corresponding to local code, shared code, translation and memory-code validity.
The assembly checks supplied guards before entry and after every retirement.
Shared tokens use acquire loads. A mismatch wins over budget exhaustion and
returns a precise `REVALIDATE`; entry mismatch retires zero instructions.
The tests publish each shared token during a register-only loop and compare the
returned prefix with an independently calculated result. This proves rejection
of changed tokens in these cases, not complete ARM TLBI/barrier semantics.

`NULL` guards are allowed only for caller-guaranteed immutable code/context in
this offline harness. This is not a production "disable validation" setting.
Guard storage and CPU/program allocations must remain live for the whole call.
Peer threads may update only the shared atomic tokens, never the local token,
CPU, operation stream or allocation lifetime.

Budget zero/halted/invalid entry follows Phase 2 precedence. Every other exit
publishes the next architectural PC, full state and exact retired count. No
faulting or unsupported instruction is consumed. Unsupported operations can be
passed once to the authoritative C executor by a future adapter; this experiment
does not invoke a Swift fallback or retry completed memory operations.

The memory entry captures owner-confined TLB metadata once per invocation.
`ag_run_memory_control` is a test-only out-of-line preparation control. The
`--benchmark-entry` suite compares it with inline preparation at identical
handler addresses, using one common indirect call site and paired rounds.
ASID/privilege/translation context changes require an owner helper transition,
and every helper transition is terminal. Shared translation and code epochs
are acquired at entry and every retirement, including register-only tails.
Pending shared TLBI at entry returns before executing. Hot RAM checks mirror
`ARM64VizGuestMemoryInternal.h`: separate read/write hot tables, tag, context,
generation, contiguous span, RAM bounds, host alignment and page observation.
Permission validation stays in the shared C walker that creates those entries.

Ordinary aligned accesses use host atomic-width loads/stores. Stores clear the
local exclusive reservation and publish dirty epochs with release ordering.
Executable stores, MMIO, unaligned/cross-page accesses, retained observers,
misses and faults use C. A post-store code check also handles a page becoming
executable during the access, completing accounting without a second write.
Detailed-statistics mode and detached RAM conservatively use C as well.

The caller bounds execution by its next service allowance. There is no native
timer/VM scheduler integration here. Benchmark windows of 64/256/4096 do not
approve those production windows.

## Phase 5 Chain Contract

`ag_chain_create` takes sorted, disjoint basic blocks (1-16 instructions, each
within one code page). A branch must be the final instruction. Every branch
target, including a middle-of-block loop, and every fallthrough passes through
an assembly service gate. The graph owns its code allocations and pre-resolved
targets; it never turns a guest address into a host executable pointer.

`AGGuards.shared[0]` is the aggregate code epoch and `shared[1]` the translation/
context epoch. Both are mandatory. Each block supplies the page generation
captured when its bytes were validated. The caller must enroll executable pages
and publish page generations before the aggregate code epoch. Code-page proofs
are reused only while that epoch is unchanged. Unrelated code changes trigger
a page rescan; touched pages and changed contexts reject execution. No epoch
reset/identity reuse is allowed without quiescence and destruction of dependent
chains. `AGChainStats` records proof hits/scans, page checks, entries, polls,
yields, revalidation, retirement and final reclamation.

`AGLimits` bounds global retirement, next event/deadline retirement allowance
and block entries separately. Zero in any allowance is invalid. CPU state,
retirement and generation checks remain per instruction. An optional atomic
event word is polled on every block entry: nonzero yields without acknowledging
the event. A chain can therefore execute at most the rest of its current
16-instruction block before observing a new event, with earlier exits for
helpers, guards and exhausted allowances. The caller is responsible for
converting real scheduling deadlines into these allowances. Revalidation or a
fault still takes precedence over exhausted budget; service-budget exhaustion
yields, while an earlier global-budget exhaustion returns `MAX_STEPS`.

Do not run, destroy or mutate a chain from a peer thread. Owner callbacks may
retire it; active-run pinning defers freeing **all** its programs and gates until
return. Reentrant execution is rejected. Peer threads may publish atomic tokens
and events only. The owner can transfer after joining/quiescing the old owner.
Optional diagnostic storage must survive the final deferred free. Tests cover
retirement with 300 replacement allocations and concurrent peer publication.

The current graph uses one 48-byte entry gate per possible instruction entry,
trading data-cache footprint for stable direct targets. The chain benchmark
reports that cost at 2/8/32/128 blocks. Very short calls are an overhead control,
not a reason to replace the existing single-program API.

## Reproduce

From the repository root on a Darwin ARM64 host with Xcode tools:

```sh
sh experiments/phase3/run.sh --test
sh experiments/phase3/run.sh --ubsan
```

UBSan instruments C preparation/harness/reference code, not assembly loads and
stores. No ASan/TSan claim is made. Both commands inspect dispatch and unwind
metadata; the normal run also leaves an enabled test binary when a build folder
is supplied:

```sh
AG_BUILD_DIR=/tmp/pinecone-phase3-build sh experiments/phase3/run.sh --test
python3 experiments/phase3/measure.py \
  --binary /tmp/pinecone-phase3-build/test-enabled \
  --output experiments/phase3/results/new-cohort
```

Timing requires Pinecone to be stopped or absent. `--pause-simulator-pid PID`
optionally suspends only the explicitly identified Pinecone Simulator process,
rejects an already-suspended process, and resumes that same process identity in
`finally`, including ordinary errors and SIGTERM. It does not reset the guest.
SIGKILL/host failure cannot execute cleanup; do not forcibly kill the controller
while it owns a pause. Results and build products are not source-controlled.

Use `--suite chain` with `measure.py` for 480 interleaved throughput samples plus
404 event-publication samples. Mode 0 returns from guarded assembly at every
four-instruction block; mode 1 chains the same handlers and checks to the stated
service window. Event tests compare equal four- and sixteen-instruction block
cadences. Raw event samples are preserved in `stderr.txt`, summarized in
`report.json`. Host scheduling is included; these are not guest UI latencies.

## Benchmark Interpretation

Every sample runs 1,048,576 guest instructions after an 8,192-instruction warmup.
Five modes rotate through every ordering slot over 15 rounds, across arithmetic
and branch loops and four invocation windows. The full resulting CPU is checked
against established C, outside timing. The per-invocation result/budget checks
inside timing are identical across modes.

| Mode | Entry |
| --- | --- |
| 0 | Older public C register API with copy-in/copy-out; diagnostic only |
| 1 | Existing predecoded C threaded prototype, immutable caller context |
| 2 | Assembly gadgets, immutable caller context |
| 3 | Assembly gadgets, all four epoch guards present and unchanged |
| 4 | Established direct-CPU C execution core, no public register-copy adapter |

These fixtures exclude VM cache lookup, host scheduling, timers, devices, Swift
crossings and cache-provided semantic hints. They are not a replacement for the
Phase 1 runtime baseline. Mode 4 provides a better core control than mode 0, but
neither is a full production-chain workload. Mode 3 validates per-instruction
guard overhead; live invalidation is tested separately, not timed as throughput.
Differences between modes 2 and 3 include branch-prediction effects and should
not be interpreted as the isolated cost of an acquire load.

Use `--suite hot` for 480 interleaved samples over two synthetic loops made from
observed shift/logical operands. Mode 1 is explicitly excluded: the older C
prototype cannot execute logical-immediate masks. Modes 0/2/3/4 retain identical
budgets and state checks; there is no fallback to complete an unsupported loop.
`run.sh --benchmark-hot` is the unqualified diagnostic equivalent. Neither loop
replays complete guest blocks, memory traffic or application control flow.

After building an enabled binary, classify saved diagnostic JSON with:

```sh
python3 experiments/phase3/profile_coverage.py \
  --binary /tmp/pinecone-phase3-build/test-enabled profile.json
```

The tool validates input words and classifies through the same preparation path
used by assembly execution. It counts unweighted retained prefix occurrences,
not sampled-counter weights or retired instructions. A supported memory handler
still requires a valid memory context and runtime proof; full prefix eligibility
does not prove that the whole block runs in assembly.

Preparation is outside warmed timing. The CSV records the one-shot preparation
time and allocation size; it does not establish cold-cache/decode performance.
Operation-stream and emitted-text sizes are documented in the result report.

## Memory Benchmark

```sh
AG_BUILD_DIR=/tmp/pinecone-phase4 sh experiments/phase3/run.sh --test
python3 experiments/phase3/measure.py --suite memory \
  --binary /tmp/pinecone-phase4/test-enabled \
  --output experiments/phase3/results/new-memory-cohort
```

The memory suite rotates three modes over 15 rounds, four windows and three
64-bit loops (load, store, mixed). Mode 0 is the established direct-CPU core,
mode 1 is threaded C with memory, and mode 2 is guarded assembly with memory.
The latter two check the same cache and shared memory epochs. CPU and all RAM
bytes are checked outside timing against the C reference after each sample.
All modes have detailed memory statistics disabled and equally warmed TLBs.
This measures hot single-page RAM, not TLB misses, real guest working sets,
graphics observers, VM block chaining or end-to-end Phosh responsiveness.

Use `measure.py --suite address` (or the unqualified diagnostic
`run.sh --benchmark-address`) for the new forms. It collects 360 samples across
unscaled 64-bit, pre/post-index 64-bit, and signed-byte register-offset loops.
Mode 0 is direct C; mode 2 is guarded assembly. The old threaded C prototype
does not implement these forms and is explicitly excluded, with no fallback.
Every sample checks full CPU and RAM state, including base writeback and sign
extension. Benchmark preparation remains outside warmed execution timing.

Use `measure.py --suite pair` / `run.sh --benchmark-pair` for offset 64-bit,
pre/post-index 64-bit and signed-word pair loops (360 samples). Mode 0 explicitly
enables the production C core's paired-RAM helper; it is not the historical
generic-callback scalar control. Mode 2 uses guarded assembly and the old C
prototype is excluded. Both modes check complete CPU/RAM equality.

Use `measure.py --suite indirect` / `run.sh --benchmark-indirect` for warmed
register-branch and BLR/RET loops (480 samples). Modes match the hot-form suite:
0 public C wrapper, 2 unguarded offline assembly control, 3 guarded assembly,
4 direct C core. Mode 1 is excluded. These are single-program loops, not a
measurement of large target tables or application-level branch behavior.

`--asan` is available, but this host's Apple ASan runtime deadlocks while
initializing shadow memory before `main`. Optimized and UBSan coverage is not
a substitute for completing ASan/TSan on a working toolchain.
