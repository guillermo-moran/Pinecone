# Phase 1: Validation, Accounting, and Chain Boundaries

## Scope and Evidence Status

Analysis only, against the existing dirty worktree at HEAD
`c3b3e957a9ee27bdcbe37c42925d98cf4563b19c`. Only this report was written.
No compilation, assembly generation, tests, timed benchmarks, runtime edits,
flag changes, guest-image changes, app installation, or Simulator operations
were performed. Parent owns timing; there is no compilation from this worker
to wait for. This report does not satisfy the roadmap's measured-cost or
annotated-assembly exit gate, and does not define or implement Phase 2.

Labels used below:

- **Code fact:** observed source behavior, not an emitted-instruction count.
- **Retained measurement:** existing benchmark/log evidence, not a new run.
- **Hypothesis:** a possible cost requiring controlled attribution.

References use file aliases with exact line numbers in the inspected snapshot:

| Alias | File |
| --- | --- |
| TP | `Sources/ARM64VizNative/ARM64VizThreadedPrototype.c` |
| Native | `Sources/ARM64VizNative/ARM64VizNative.c` |
| Cache | `Sources/ARM64VizNative/ARM64VizBlockCache.c` |
| Memory | `Sources/ARM64VizNative/ARM64VizGuestMemory.c` |
| Hot | `Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h` |
| Backend | `Sources/ARM64VizCore/EmulatorBackend.swift` |
| Host | `Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift` |
| Harness | `scripts/threaded-runtime-regression.c` |

All paths resolve beneath `/Users/gmoran/Documents/Projects/arm64viz`.

## Main Findings

1. **Code fact:** prototype execution pays one retirement/epoch validation at
   entry and another after each successful hot-path instruction, including
   the instruction exhausting its budget (TP:66-75,100-113,564-596). The
   established executor's ordinary arithmetic path does not perform that
   validation after every instruction; it validates entry, mapped block
   boundaries, and callback/semantic-helper transitions
   (Native:11146-11247,11460-11475). This is a concrete structural difference,
   not yet a measured allocation of the slowdown.
2. **Code fact:** the production wrapper limits a prototype invocation to
   `min(decoded instruction count, requested steps)` and repeats eligibility
   lookup before execution (Native:13738-13774,14833-14854). It cannot run a
   backward loop indefinitely or directly link into another prototype program.
   Eligible blocks also bypass new established superblock composition.
3. **Code fact:** the measured arithmetic and memory harness fixtures do not
   attach `AVZGuestMemory` (Harness:221-238,252-267). Their per-instruction
   validation therefore does **not** load shared code or translation atomics.
   The production fast-memory path can do three acquire loads per validation,
   including two reads of the same shared code epoch. Two-vCPU shared-epoch
   contention cannot explain the isolated fixture regressions on this evidence.
4. **Retained measurement:** the memory log reports 245 checkpoints in both
   established/memory-ineligible modes and 247 in threaded-memory mode.
   A large increase in host-checkpoint count is not present in that workload.
   This does not measure checkpoint cost, block-boundary cost, or production
   Swift callback cost.
5. **Code fact:** retirement, precise PC/steps, memory fault exits, and bounded
   checkpoints have different correctness owners. Removing them together
   would conflate lifetime safety, stale-code detection, exact memory effects,
   and host/IRQ service. Any diagnostic omission belongs only in an isolated
   offline fixture, never a production default.

## Established Measurements

`docs/executor-benchmark-2026-10-28.md:119-136` reports nine alternating samples
per mode at one million guest instructions, with expected-state/step checks:

| Workload | Established C | Prototype | Ratio |
| --- | ---: | ---: | ---: |
| Register arithmetic/branch | 5.410 ms | 16.290 ms | 3.01x |
| Load/add/store/branch, memory enabled | 8.019 ms | 20.433 ms | 2.55x |
| Memory workload, prototype enabled but memory ineligible | 8.019 ms | 8.020 ms | approximately 1x |

Read-only inspection of `/tmp/pinecone-executor-benchmark-20261028/` confirms:

- `dispatch-microbenchmark.log`: every established sample prints 7,781
  `superblocks` (the harness prints `result.superblock_dispatches`, not a
  unique-superblock count); every prototype sample prints zero superblock
  dispatches and 1,000,000 prototype steps (Harness:270-273).
- `memory-microbenchmark.log`: every variant 0/1 sample prints 245 checkpoints;
  every variant 2 sample prints 247. These are callback counts, not costs.

No new timing or exhaustive correctness claim follows from reading these
files. Old standalone handler-versus-switch results are not production
comparisons. Established C, already described as computed-goto with semantic
fast paths in the benchmark/roadmap, remains the baseline; the prototype is
a hybrid subset, not the first threaded executor.

**Provenance caveat:** the inspected Native:11506-11569 spells ordinary dispatch
as a standard C `switch` targeting labels inside the
`!AVZ_DISABLE_COMPUTED_GOTO` path, with a comment about prior label-address
dispatch. Do not turn this textual observation into a new switch-versus-threaded
benchmark claim or silently replace the supplied baseline. Parent should
reconcile measured-binary identity and annotated lowering. No generated code
was inspected here. Dirty runtime changes and the absence of retained native
harness binaries also prevent proving that this source snapshot is byte-for-byte
the source of the retained measurements.

## Validation and Correctness Ownership

### Prototype Entry and Per-Instruction Validation

`avz_tp_run_guarded` checks program/CPU pointers, zero budget, and halted state
before pinning (TP:568-574). It obtains token addresses and snapshots, validates
once, resolves the starting PC by alignment/range, and invokes the handler
(TP:347-352,576-591). Pin decrement/free occurs only after the handler returns
(TP:593). Internal outside/unsupported sentinels do not retire an instruction
(TP:115-125).

On a successful `TP_NEXT`, order is: commit architectural effects and PC in
the handler, increment result steps, decrement remaining, validate, check
zero remaining, then musttail-dispatch (TP:100-113,149-150,197-199,295-321).
Thus invalidation wins over budget exhaustion when both occur on the last
instruction; the completed instruction is still counted exactly once.

| Check, in short-circuit order | Storage and owner | Purpose and mismatch behavior |
| --- | --- | --- |
| `!program->retired` | Ordinary byte; vCPU-confined program/cache. `active_runs` is also non-atomic (TP:55-63). | Reentrant cache clear/eviction can drop ownership during a helper. Pin protects allocation lifetime; retirement stops successor execution. Returns `REVALIDATE`. |
| `!code_token || *code_token == code_epoch` | Ordinary vCPU-local cache-wide code epoch, not a per-page generation token (Cache:1885-1888). | Local executable writes, translation mapping invalidation, and cache reset can invalidate the selected proof. Returns `REVALIDATE`. |
| Optional `shared_code_token`, acquire load | Shared guest-memory code mutation epoch through cache (Cache:1869-1882; Memory:1006-1020). | Detect code writes observed through shared memory, including another vCPU/device. Returns `REVALIDATE`. |
| Optional `translation_token`, acquire load | Shared guest-memory translation epoch; compare against fast path's already observed epoch (TP:580-582). | A pending TLBI cannot be acknowledged just by sampling a fresh epoch; fast path must actually synchronize its mappings. Returns `REVALIDATE`. |
| Optional `memory_code_token`, acquire load | `memory->guest_memory->code_mutation_epoch`, snapshotted with acquire at entry (TP:583-585). | Detect shared code mutation after entry snapshot; returns `REVALIDATE`. Normally aliases the cache's shared code token when both bind the same guest memory. |

Cache binding shares the guest-memory object with the fast path at
Memory:3701-3715. Consequently the last and third checks often read the same
atomic, but their expected epochs are captured at different points: wrapper
before preparation (Native:13755-13758), versus after pinning (TP:584-585).
This is source-level duplicated polling, not proof that either observation
can be deleted without reviewing entry races and the required visibility bound.

The ordinary-byte retirement protocol is **not** a cross-thread reclamation
scheme. It relies on the stated vCPU confinement (TP:59-60); peers share RAM
and publication epochs, not the private cache/program. Cache slot release
calls destroy and clears ownership (Cache:247-269); destroy marks retired and
frees only with no active run (TP:532-536). Cache clear retires all 256 slots
and advances generation/mutation/code/reset epochs (Cache:942-955). Removing
the pin exposes helper-return operation pointers to use-after-free; removing
retirement can continue an intentionally invalidated snapshot even when memory
is still allocated.

### Generation Publication Versus Selection

Do not conflate cache `generation`, local code epoch, per-page write generation,
shared code epoch, translation epoch, or entry serial. `TP_NEXT` polls the
coarse epochs and retirement, not the page-generation arrays or cache generation.

- Local executable-range invalidation advances applicable tracked page
  generations and then the local code epoch (Cache:1433-1455). Translation
  mapping invalidation advances translation and code epochs without rewriting
  physical code contents (Cache:1101-1107).
- Shared writes mark dirty/exclusive state and, when the range may contain
  code, update page-write generations then the code epoch
  (Memory:1230-1252; device writes at 1255-1277). Code epoch publication uses
  acq_rel fetch-add, with release wrap handling (Memory:989-1003).
- TLBI publication writes its journal under `translation_lock` and publishes
  `translation_epoch` with release (Memory:1364-1379). Synchronization checks
  the epoch, locks/copies pending entries, applies them to the private TLB,
  invalidates decoded mappings, then updates the observed epoch
  (Memory:1708-1745). A comparison alone is not translation synchronization.
- Cache entry validation first checks the shared epoch; on change it checks
  acquire-loaded shared page generations. On local code-epoch change it
  validates changed translation mappings, checks the epoch again after mapping
  callbacks, then checks local page generations (Cache:484-553). This can
  preserve an unaffected entry after an unrelated coarse epoch change.
- Successor reuse checks source validity/serial/current code, then target
  serial/current code and matching PC/context (Cache:1690-1732). Serials stop
  a recycled cache slot from masquerading as the old block. Established span
  revalidation also checks reset/serial/key and rechecks epochs after callbacks
  (Native:11088-11103,14134-14168).

### Established Executor Comparison

The established entry validates its execution span (Native:11146-11154).
Ordinary handlers update PC and `result.steps`, then dispatch; the budget is
tested before the next instruction (Native:11173-11180,11205-11208).
Mapped traces validate expected PC at entry and terminators, and code currency
at subsequent mapped-block boundaries (Native:11209-11238). Nonmapped execution
checks PC alignment/range each dispatch (11240-11247). Callback transitions
validate span and, where needed, cache mutation after counting completed work
(11191-11203); semantic helpers have a corresponding validation/accounting
path (11460-11475). These are not equivalent to the prototype's validation
after every ordinary arithmetic instruction.

Both paths write architectural PC and count guest work. The extra prototype
remaining decrement and noinline handler ABI may change load/store traffic,
but only generated code can establish spills, reloads, or register residency.
Semantic accelerators add equivalent `fast_steps`; a host handler invocation
is not necessarily one guest instruction (Native:11460-11475).

## Budget, PC, and Memory Boundaries

| Event | PC and completed steps | Correctness owner |
| --- | --- | --- |
| Ordinary instruction / taken branch | Commit next/target PC, one step, remaining minus one. Validate before next handler. | Prototype handler and `TP_NEXT` (TP:100-113,295-321). |
| Unsupported operation / no memory object | Leave current instruction uncounted; preserve its PC; return raw instruction for unsupported. | TP:121-125,246-249. Cache eligibility normally excludes it. |
| Hot RAM access succeeds | Commit load/store, clear local exclusive state on store, advance PC, then normal `TP_NEXT`. | TP:244-275 plus existing memory helpers. |
| Complete memory helper succeeds after hot miss | Commit effect and next PC, add one step, return `REVALIDATE` immediately. No remaining decrement is needed because invocation ends. | TP:259-275. Cold RAM, observer, or MMIO behavior must not execute twice on resume. |
| Complete memory helper fails | Return `MEMORY_FAULT`, no PC advance and no step for the failed instruction. Previous successful instructions remain counted. | TP:261-263; memory/Swift own fault details and exception delivery. |
| Budget expires after a hot instruction | PC already names next instruction; return `MAX_STEPS` unless validation first demands `REVALIDATE`. | TP:100-110. |
| Native chain return | Sum completed block steps, advance native time, aggregate checkpoints; preserve precise resident CPU. | Native:15021-15040. |
| Swift checkpoint translation fault | Adds one attempted fault step to completed native steps, except blocked pinned-device early-return handling. | Backend:1036-1057. This is not a strict hardware retired-instruction counter. |

Hot memory continuation is conditional on the existing proof: context/tag,
generation, address/width/page bounds, valid host pointer, observer state,
alignment, and shared translation state (Hot:180-268,332-428). Missing a proof
means use the authoritative helper, not declare a fault. Loads/stores perform
relaxed atomic RAM access; observer checks are acquire loads. Stores also
perform dirty/code bookkeeping: noncode warm stores inspect code bits and dirty
epoch, code stores use the full commit path (Hot:277-324). These checks cannot
be replaced by assuming every writable page is plain RAM.

The production wrapper never passes a budget larger than one decoded block's
instruction count, even for internal backward branches (Native:13761-13767).
The checkpointed chain treats `MAX_STEPS` as a local invocation limit and can
continue. By contrast, the noncheckpointed API breaks on a block result of
`MAX_STEPS` or `REVALIDATE` (Native:14638-14644). A standalone call to
`avz_tp_run` with a huge budget is therefore not a faithful production chain
comparison.

## Chain Entry, Eligibility, and Checkpoints

### Selection and Exit

The checkpointed chain validates nonzero limits/callbacks, uses live PC/EL to
construct a canonical key, snapshots local/shared epochs, and prefers an
existing superblock, embedded successor, direct link, then decode
(Native:14696-14829). Cached links are still validated; they do not bypass
currency checks. It creates a selected execution span and probes eligibility
(14830-14834). A prototype-eligible block bypasses new superblock composition
(14835-14854); an already found superblock uses established execution.

Eligibility has these gates (Cache:1511-1570; TP:357-394):

- Valid owned entry, nonzero serial, at least two decoded instructions, and
  current code. Runtime enable is an atomic relaxed read; memory enable is
  another relaxed read only when memory is allowed (Native:13738-13746).
- Whole block must be in the register subset, or in the narrowly supported
  unsigned-immediate scalar load/store subset with memory enabled. System,
  vector, general addressing, and unsupported blocks stay on established C.
- Negative eligibility/OOM results are cached; a positive cached program is
  reused. New preparation scans the block, allocates from an ownership pool
  capped at 256 programs, copies raw words, and decodes/prepares operations
  again (Cache:1533-1569; TP:412-529). Cold preparation is not steady-state
  handler work. No test run here establishes allocation-failure behavior beyond
  the visible fallback selection.
- Before invocation, wrapper snapshots epochs, repeats preparation lookup and
  checks CPU PC equals selected block start (Native:13754-13760). Successful
  wrapper returns update two relaxed atomic statistics via fetch-add; revalidate
  and fault exits have additional counters (13768-13774). `generic_dispatches`
  is zeroed here, so it must not be interpreted as all native instruction work.
  `threaded_memory_boundaries` also counts register-program revalidation.

After invocation, the chain updates steps/blocks, synchronizes native time and
translations, maps `REVALIDATE` to outside-block for chain status, and maps a
due native IRQ to yielded except halt/unsupported/memory fault
(Native:15021-15040). It drops the previous link on a chain barrier,
revalidation, or fault (15065-15069). The wrapper does not directly chain
operation pointers across program allocations.

### Checkpoint Cadence

Chain barriers and host-checkpoint barriers are distinct metadata
(Cache:81-115). System-register reads and exception return break chaining but
do not automatically require a host checkpoint. Writes, PSTATE changes,
wait/halt, and selected system/exception operations do. The SVC and coherent
cache-maintenance cases have explicit exceptions; not every barrier or system
operation is an identical host boundary.

Before a host-checkpoint-barrier block with accumulated work, the chain flushes
that work and **reselects** after the callback, since host code can clear or
remap the entry (Native:14859-14883). It also checkpoints/reselects on a depleted
step budget (14885-14907). Requested steps are the minimum of remaining global
steps and remaining checkpoint allowance (14908-14910); fused established
blocks are additionally bounded by global/checkpoint block allowances
(14913-14926).

After a block, checkpoint triggers are precisely: accumulated step limit,
block interval, revalidation, memory fault, halt, unsupported, yielded, zero
progress, global max steps, or host-checkpoint barrier
(Native:15073-15083). A remaining partial batch is flushed at chain exit
(15111-15121). Revalidation need not end the whole checkpointed chain if the
callback grants more work; faults/zero progress and other terminal conditions
do end it (15098-15107). Merely returning from a prototype invocation does not
mean crossing into Swift.

Production Swift grants at most 65,536 steps initially, timer-bounded, and at
most 65,536 subsequently (Backend:3026-3056,1095-1099,2265-2302). The VM default
block interval is 1,024 (`VirtualMachine.swift:522`), but the mobile host sets
4,096 initially (Host:1230), and policy uses 4,096 for touch/normal versus
8,192 for application launch (Host:2173-2189). Do not label the VM default as
the measured app's universal interval. The native chain block cap is 262,144
(Backend:86), independent of checkpoint cadence.

At Swift checkpoints, translations are synchronized, steps/fault attempts
accounted, requested stop and host-preemption generation tested, deadline
checked when due, fault/context-change/global budget handled, and pending IRQ
tested (Backend:1031-1099). `nextDeadlineCheckStep = totalSteps + 4096` is a
threshold evaluated **at checkpoints**, not a guarantee of polling every 4,096
instructions. With a four-instruction block, a 4,096-block interval is 16,384
instructions before other earlier triggers; long blocks can hit the 65,536
step limit instead. Neither is a wall-time guarantee.

Native time advancement synchronizes shared translations even for
register-only chains; with a shared clock it refreshes the counter after an
accumulated 1,024 instructions, at invocation boundaries, then checks IRQ/timer
state respecting the IRQ mask (Memory:3895-3921). Removing short prototype
returns or increasing checkpoint spacing therefore changes event-service
cadence, not just dispatch cost.

## Static Frequency in the Representative Loops

**Code-derived counts, not measured CPU loads/cycles.** Consider a warm,
unchanged, four-instruction program, entering at its start with at least four
steps left, all memory accesses hot, and no earlier short-circuit exit.
Arithmetic words are ADD-register, ADC, AND, branch-back
(Harness:253); memory words are LDR, ADD-immediate, STR, branch-back
(Harness:222). Each iteration commits four guest instructions.

| Per four-instruction prototype invocation | Arithmetic fixture | Warm memory fixture | Production fast-memory path with shared guest memory |
| --- | ---: | ---: | ---: |
| PC commits / step increments / remaining decrements | 4 / 4 / 4 | 4 / 4 / 4 | 4 / 4 / 4 |
| `tp_is_current` evaluations: entry plus after each instruction | 5 | 5 | 5 |
| Retirement reads / local cache-epoch reads within those evaluations | 5 / 5 | 5 / 5 | 5 / 5 |
| Acquire shared code-token reads within those evaluations | 0 | 0 | 5 |
| Acquire translation-token reads within those evaluations | 0 | 0 | 5 |
| Acquire memory-code-token reads within those evaluations | 0 | 0 | 5 |
| Initial acquire memory-code snapshot outside evaluations | 0 | 0 | 1 |
| Handler-to-handler tail transitions (fourth instruction exits on limit) | 3 | 3 | 3 |
| Pin increment/decrement | 1 / 1 | 1 / 1 | 1 / 1 |
| Wrapper prototype block/step atomic fetch-adds | 2 | 2 | 2 |

The production column also applies to a **register-only** eligible block in
the fast-memory chain: the wrapper receives the fast-memory object regardless
of whether this program uses loads/stores (Native:14983-14990). The table
excludes selection/preparation validation, initial shared-epoch snapshots,
statistics-enable loads, native time advancement, and memory-helper atomics.
For production hot LDR/STR, the helpers add two relaxed shared translation
loads, two acquire page-observation loads, RAM load/store atomics, and store
bookkeeping. In the measured fixtures `guest_memory == NULL`, so these shared
metadata loads are absent too. Hot memory fallback/commit work can still exist.

For the ideal four-instruction arithmetic fixture, one million steps imply
250,000 prototype invocations, 1,250,000 validation evaluations, and 500,000
wrapper statistics fetch-adds. Those are source-level consequences under the
stated path assumptions, not instrumented counters. The block interval is
10,000 and step interval 4,096 in this harness, so an uninterrupted run yields
`ceil(1,000,000 / 4096) = 245` checkpoints (Harness:34-51). The observed memory
prototype's two extra checkpoints are consistent with initial load/store
hot misses forcing revalidation; their individual causes were not logged, so
that explanation remains a hypothesis. Do not apply warm full-block counts
unchanged to cold misses, interior-PC resumes, or arbitrary production blocks.

For an established mapped four-instruction block, ordinary execution still
has four PC/step updates and four budget/dispatch entries, but no
`tp_is_current` or program pin; span validation occurs at mapped block
boundaries, entry, and helper transitions, not four times per block. Superblock
packing amortizes chain-level selection and time advancement. The retained
7,781 established superblock dispatches versus the prototype's zero establishes
different execution shapes, not how many milliseconds each shape costs.

## Contention: What Is and Is Not Supported

**Code facts:** local epoch/retirement fields are not atomics. Shared epoch
loads are reads, not a lock or RMW on every instruction. Shared code epoch
changes only on relevant executable writes, not every ordinary data store
(Memory:1239-1251; Hot:302-318). Its struct has 128-byte padding on each side and
offset assertions separating write-ticket and translation traffic
(Hot:69-92). A blanket claim that every RAM write false-shares the code epoch
is contradicted by this layout. Translation epoch remains adjacent to its
publication lock/journal, and those can change during shootdowns.

**Unmeasured hypotheses:** repeated acquire loads can add instruction/dependency
cost even with no writer; a peer publishing code mutations/TLBI can cause
coherence traffic, more early exits, and journal synchronization. Broad code
epochs can force a prototype exit for an unrelated executable page; the cache
can then discover that this block is unchanged. Wrapper statistics RMWs are
per-context, not necessarily shared between the two vCPUs; telemetry readers
or same-line state may still affect coherence. None of these effects has a
measured event rate, cache-miss attribution, or cycle share in this report.
The isolated slowdown already exists without shared-epoch polling, so that
mechanism cannot be its sole explanation or a demonstrated production cause.

## What Cannot Simply Be Removed

- Allocation pin and ownership/serial checks: protect against reentrant helper
  invalidation, cache recycling, and operation-pointer use after free.
- Epoch/publication and mapping checks: preserve local/peer executable writes
  and shared TLBI visibility; replacing observed translation state with a fresh
  sampled value can bless mappings that were never synchronized.
- Precise PC and completed-step accounting at faults/unsupported/helper exits:
  prevent skipped or duplicated guest operations and wrong timer/budget state.
  A budget-ending invalidating store must retain its revalidation boundary.
- Slow-memory exit and helper ownership: preserve exact-once MMIO/observer
  effects, translation faults, exclusive state, dirty tracking, and self-code
  modification. A hot miss is not proof of ordinary RAM.
- Bounded native/host checkpoints: preserve stop/preemption/IRQ/deadline and
  input-service opportunities. A throughput-only improvement can hide worse
  responsiveness.

This identifies current reasons for the checks, not a new contract prescribing
their future cadence. Existing test *source* covers width/SP/XZR/budgets,
callback clear/evict/remap, code writes, pending TLBI, observers/faults,
concurrent shootdowns, and chain deadlines
(`scripts/threaded-memory-continuation-regression.c:146,187,225,258,282,336,387`).
Host-preemption/IRQ checkpoint expectations appear in
`Tests/ARM64VizCoreTests/HostPreemptionCheckpointTests.swift:56-93`.
These tests were not executed by this worker; their presence is not a pass.

## Proposed Offline Attribution Experiments

Priority here is an investigation order, **not** a ranked measured cost table.
Parent alone schedules compilation and serial timing. Use disposable native
fixtures/artifact directories, immutable input words, equal budgets, full-state
and step assertions, fixed compiler/target/options, retained assembly and raw
results, and alternating matched runs. Do not install variants or modify app
defaults. An omission experiment is not a candidate for production promotion.

| Priority | Isolated experiment, not implemented | What it can distinguish / required controls |
| --- | --- | --- |
| 1 | Warm prepared four-instruction program vs production wrapper/chain on the identical loop; measure preparation separately. Preserve checks in both. | Separates setup, repeat eligibility, pin/unpin, counters, and chain exits from handler time. Report result steps, invocations, checkpoints, superblock dispatches, and all state. Standalone result must remain labeled standalone. |
| 2 | Offline immutable single-owner register fixture: one variant at a time suppress only post-instruction validation, or only wrapper statistics updates; keep entry validation, step cap, and result assertions. Inspect generated code as well as timing. | Tests check/branch versus statistics overhead without pretending shared contention. No helpers, invalidation, publication writers, production linkage, or guest runtime allowed for omitted checks. Retain unmodified control and do not sum isolated deltas as independent costs. |
| 3 | Full-check fixture matrix: no guest-memory attachment; attached but quiescent shared memory; a separate writer publishing controlled TLBI/code events. Use separate private caches and controlled code pages. | Separates optional-load cost from real coherence and revalidation/locking. Record publication rate, exits, mapping synchronization, and observer completion. Writer is part of one controlled experiment, not a concurrent independent benchmark. Never run the check-omission variant with that writer. |
| 4 | Offline accounting/state-traffic diagnostic on pure immutable arithmetic: inspect instruction-level PC/steps/remaining accesses, then independently try deferred PC or budget bookkeeping in a scratch variant with exact reconstruction at every possible stop offset. | Tests handler ABI/materialization hypothesis. Not safe for helper/fault/shared-memory cases. Compare all partial budgets and branch targets; retain original state writes at observation boundaries. No Phase 2 ABI or runtime implementation authorized. |
| 5 | Count hot misses and revalidation reasons in a separate instrumented run; time uninstrumented matched controls. Separate cold allocation/decode from warmed memory loop and sweep only native invocation size or checkpoint interval in offline copies. | Distinguishes early cold helper exits, block return overhead, and checkpoint service. Preserve all checks for cadence tests; report maximum callback delay and steps, not throughput alone. Changing both chain size and check density in one variant is confounded. |
| 6 | Compare established execution with existing semantic fast paths/superblocks intact; add a separately labeled diagnostic without superblock composition only in scratch code. | Isolates the lost packing opportunity suggested by 7,781 versus zero dispatches. Diagnostic baseline is not the production baseline and must never replace it in reported wins. |

Parent reproduction entry points, **not executed here** (these scripts compile
and run, so schedule only outside any other timed workload):

```sh
cd /Users/gmoran/Documents/Projects/arm64viz
sh scripts/run-threaded-runtime-regressions.sh --dispatch-benchmark
sh scripts/run-threaded-runtime-regressions.sh --benchmark
sh scripts/run-threaded-runtime-regressions.sh --sanitize
```

The runner uses `-O3` for timing and compiles the actual native/cache/memory/TP
translation units (script:23-31); its temporary binary is deleted on exit
(script:4-5). Parent should preserve build identity and binaries in its own
authorized artifact workflow before claiming matched generated-code evidence.
The measured loops include first-run decode/preparation within the timer
(Harness:237-239,266-268); they are not prewarmed handler-only measurements.

## Blockers and Handoff

No blocker to delivering this static report. Remaining blockers to *causal
performance attribution* are unmeasured emitted-code/state traffic, absent
per-reason exit rates/costs, unmeasured shared writer contention, and unproven
identity between dirty source and retained harness builds. No cycle ranking,
production optimization, broad correctness certification, or Phase 1 completion
is claimed. Parent timing coordination: no build/test process was launched or
left running by this worker.

## Source Identity

SHA-256 captured read-only during inspection:

```text
f08cc580a4d866ef18adcc0dae15cb8b8c67b763110eb29561e76e4f77e80724  roadmap.md
f1f8a4ca7981f29e8a01c651554c44e49625cc79ba42c679d3ad4e9d90cda509  docs/executor-benchmark-2026-10-28.md
5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416  Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f  Sources/ARM64VizNative/ARM64VizNative.c
5153bd7b2c98007d0c80b10de11a45eb87a48e797f204025a5ed92b82e591992  Sources/ARM64VizNative/ARM64VizBlockCache.c
d2233c3b054b0cbffcd28e36ceb46451a2424ed4b3db590f2be1841994649266  Sources/ARM64VizNative/ARM64VizGuestMemory.c
ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9  Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h
fe3be0d9bb03d423f4a72eff9479a22b8a31223c306ff8b84c2a7caad85dfc68  Sources/ARM64VizCore/EmulatorBackend.swift
5ceedd746d979dd370dd82cd3e399b8473f087111368133d9d7d72c7a0b06ed1  Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift
79545f80af49ce93c60fa231c049fd0b9b714afbcca1f88bdbf87c3f6a5fee41  scripts/threaded-runtime-regression.c
0f68d6425e6741f28bfb3f92f16c9634b8f6a1834ade88dfec38105b7bf93ef1  scripts/threaded-memory-continuation-regression.c
```

## Commands and Artifacts

Only generated artifact: `docs/phase1-validation-analysis.md`, created with
`apply_patch`. No compiler output, executable, new timing log, or test artifact.
Existing benchmark log paths are listed above. Read-only command ledger below
groups repeat inspections; commands ran from the workspace root. `rg` was not
installed (three attempted searches exited 127); `grep` was used instead.
One guessed `ARM64VizMemoryFastPath.c` path did not exist; the actual helper
definitions were then located in `ARM64VizGuestMemoryInternal.h`.

```sh
pwd
git status --short
cat roadmap.md
cat docs/executor-benchmark-2026-10-28.md
rg -n 'generation|retir|budget|checkpoint|chain|eligible|validate|steps|pc' Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
rg -n 'generation|retir|checkpoint|threaded|execute_chain|step_budget' Sources/ARM64VizNative/ARM64VizBlockCache.c
rg -n 'checkpoint|threaded|execute_chain|generation|retir' Sources/ARM64VizNative/ARM64VizNative.c
grep -nE 'generation|retir|budget|checkpoint|chain|eligible|validate|steps|pc' Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
grep -nE 'generation|retir|checkpoint|threaded|execute_chain|step_budget' Sources/ARM64VizNative/ARM64VizBlockCache.c
grep -nE 'checkpoint|threaded|execute_chain|generation|retir' Sources/ARM64VizNative/ARM64VizNative.c
nl -ba Sources/ARM64VizNative/ARM64VizThreadedPrototype.c
sed -n '13735,13780p;14650,15130p' Sources/ARM64VizNative/ARM64VizNative.c
nl -ba Sources/ARM64VizNative/ARM64VizThreadedPrototype.c | sed -n '525,610p'
nl -ba Sources/ARM64VizNative/ARM64VizBlockCache.c | sed -n '45,115p;460,525p;1415,1468p;1500,1580p;1820,1895p'
grep -nE 'epoch|generation|atomic|try_read_hot|try_write_hot|advance_time' Sources/ARM64VizNative/ARM64VizMemoryFastPath.c
grep -nE 'checkpointBlock|Checkpoint|checkpoint|nativeBlock|stepLimit' Sources/ARM64VizCore/VirtualMachine.swift
grep -R -nE 'nativeCheckpointBlockInterval|checkpointBlockInterval|func.*[Cc]heckpoint|avz_native_fast_memory_try_read_hot|avz_guest_memory_code_mutation_epoch_token' Sources Tests/ARM64VizCoreTests/HostPreemptionCheckpointTests.swift
nl -ba Sources/ARM64VizNative/ARM64VizNative.c | sed -n '11106,11320p;13738,13777p'
grep -nE 'epoch|AVZ_DISPATCH|goto \*|result.steps|cpu.pc|remaining' Sources/ARM64VizNative/ARM64VizNative.c | awk -F: '$1>=11106 && $1<=12935'
find scripts -iname '*thread*' -o -iname '*benchmark*'
nl -ba Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h | sed -n '1,75p;165,250p;326,435p'
grep -nE 'translation_epoch|code_mutation_epoch|page_write_generations|advance_time|synchronize_shared' Sources/ARM64VizNative/ARM64VizGuestMemory.c
nl -ba Sources/ARM64VizCore/EmulatorBackend.swift | sed -n '1000,1200p;2960,3075p'
nl -ba scripts/threaded-memory-continuation-regression.c | sed -n '1,250p'
find /tmp/pinecone-executor-benchmark-20261028 -maxdepth 2 -type f -name '*.[cs]'
nl -ba Sources/ARM64VizNative/ARM64VizGuestMemory.c | sed -n '989,1022p;1220,1280p;1345,1395p;1708,1750p;3895,3965p'
nl -ba Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h | sed -n '69,105p;270,325p'
grep -nE 'nativeCheckpointBlockInterval|nativeChainBlockLimit|nativeStepLimitBeforeTimerDeadline|hostPreemption' Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift Sources/ARM64VizCore/EmulatorBackend.swift
find /tmp/pinecone-executor-benchmark-20261028 -maxdepth 2 -type f | head -60
nl -ba scripts/benchmark-native-dispatch.c | sed -n '1,240p'
nl -ba Sources/ARM64VizNative/ARM64VizBlockCache.c | sed -n '518,555p;1060,1117p;1680,1785p'
nl -ba Sources/ARM64VizNative/ARM64VizNative.c | sed -n '14040,14180p;11505,11580p;11925,11985p'
cat /tmp/pinecone-executor-benchmark-20261028/dispatch-microbenchmark.log
cat /tmp/pinecone-executor-benchmark-20261028/memory-microbenchmark.log
nl -ba Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift | sed -n '2173,2195p'
nl -ba Sources/ARM64VizCore/EmulatorBackend.swift | sed -n '2265,2315p'
git diff -- Sources/ARM64VizNative/ARM64VizNative.c
grep -nE 'benchmark|1000000|checkpoint|uint32_t.*\[\]|4096' scripts/threaded-runtime-regression.c scripts/threaded-memory-continuation-regression.c scripts/run-threaded-runtime-regressions.sh
nl -ba Sources/ARM64VizNative/ARM64VizNative.c | sed -n '11000,11105p;11740,11825p;14545,14655p'
git rev-parse HEAD
shasum -a 256 roadmap.md docs/executor-benchmark-2026-10-28.md Sources/ARM64VizNative/ARM64VizThreadedPrototype.c Sources/ARM64VizNative/ARM64VizNative.c Sources/ARM64VizNative/ARM64VizBlockCache.c Sources/ARM64VizNative/ARM64VizGuestMemory.c Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h Sources/ARM64VizCore/EmulatorBackend.swift Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift scripts/threaded-runtime-regression.c scripts/threaded-memory-continuation-regression.c
nl -ba scripts/threaded-runtime-regression.c | sed -n '1,58p;150,173p;221,295p'
nl -ba scripts/run-threaded-runtime-regressions.sh | sed -n '1,80p'
nl -ba Sources/ARM64VizNative/ARM64VizNative.c | sed -n '11827,11880p;11618,11660p'
nl -ba Tests/ARM64VizCoreTests/HostPreemptionCheckpointTests.swift | sed -n '50,110p'
nl -ba docs/executor-benchmark-2026-10-28.md | sed -n '112,143p'
nl -ba Sources/ARM64VizNative/ARM64VizGuestMemory.c | sed -n '3675,3725p;2865,2910p'
nl -ba Sources/ARM64VizNative/ARM64VizBlockCache.c | sed -n '247,271p;939,969p'
grep -nE 'chain_budget|checkpoint|static void|int main' scripts/threaded-memory-continuation-regression.c | tail -20
git diff --check -- docs/phase1-validation-analysis.md
git diff --no-index --check /dev/null docs/phase1-validation-analysis.md
wc -l docs/phase1-validation-analysis.md
```

Tool metadata was also searched for an agent/parent notification tool; no
applicable parent-agent messaging API was exposed. Compilation status was
communicated in commentary and is repeated in this handoff. Final checks are
documentation whitespace/status checks, not runtime validation.

Verification results: tracked-path `git diff --check` exited 0; because this
report is untracked, the no-index check against `/dev/null` was also used and
printed no whitespace errors (exit 1 denotes the added-file difference).
Repeated source SHA-256 values matched those above. Final `git status --short`
had the same pre-existing dirty entries plus this report only. No existing
change was reverted or incorporated into a new runtime edit.
