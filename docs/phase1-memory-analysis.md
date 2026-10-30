# Phase 1: Scalar Memory Analysis

Status: read-only source investigation, October 28 benchmark baseline. No fixes,
compilation, tests, new timing, Simulator actions, runtime flag changes, app
changes, or disk changes were performed. Only this report was written. Parent
owns timing and review; dispatch and validation attribution remain with their
respective investigators. This is not completion of the roadmap's measured-cost
and annotated-assembly exit gate.

## Conclusions

1. The prototype already uses the established executor's **same always-inline
   hot RAM read/write helpers**. It is not doing a virtual callback or page walk
   on each warmed scalar access. The surrounding execution machinery differs;
   sharing C helpers does not prove identical generated instructions or cost.
2. The measured fixture is a single aligned 64-bit location in callback-mapped
   RAM, with **no attached AVZGuestMemory**. Shared translation/code epoch loads,
   host/DMA/exclusive observations, dirty-page epochs, native page walks, and
   page-stripe contention cannot explain this fixture's steady-state regression.
3. There is nevertheless a recurring external helper on stores: with no
   AVZGuestMemory, the inline commit helper calls `commit_write_span`, which
   reaches block-cache invalidation checking. The data page is not code, so the
   check skips. This happens in both executors; its ABI/register-allocation
   interaction is a hypothesis, not a demonstrated differential cost.
4. Non-hot access completion always ends the prototype invocation, even if the
   complete helper merely refills the TLB or services observed RAM successfully.
   Established C can continue after its callback validation. This is important
   for real workloads, but the saved memory log shows only **247 versus 245
   checkpoints**, consistent with the first read and first write being cold.
   There is no evidence here for persistent MMIO/miss/observer exit traffic.
5. Investigate recurring executor entry/accounting/validation and generated
   memory-handler code first. The arithmetic regression independently makes a
   memory-only explanation implausible. Neither benchmark identifies a cost
   percentage, and subtracting their totals does not isolate memory overhead.

## Evidence Index

Line numbers refer to the inspected working tree, not pristine HEAD. The root
[roadmap](/Users/gmoran/Documents/Projects/arm64viz/roadmap.md) and
[benchmark report](/Users/gmoran/Documents/Projects/arm64viz/docs/executor-benchmark-2026-10-28.md)
define the scope and supplied measurements. Source IDs below make subsequent
`ID:line-line` references unambiguous.

| ID | File |
| --- | --- |
| TP | [ARM64VizThreadedPrototype.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c) |
| H | [ARM64VizGuestMemoryInternal.h](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h) |
| M | [ARM64VizGuestMemory.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizGuestMemory.c) |
| N | [ARM64VizNative.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c) |
| B | [ARM64VizBlockCache.c](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizBlockCache.c) |
| F | [threaded-runtime-regression.c](/Users/gmoran/Documents/Projects/arm64viz/scripts/threaded-runtime-regression.c) |
| R | [run-threaded-runtime-regressions.sh](/Users/gmoran/Documents/Projects/arm64viz/scripts/run-threaded-runtime-regressions.sh) |
| C | [threaded-memory-continuation-regression.c](/Users/gmoran/Documents/Projects/arm64viz/scripts/threaded-memory-continuation-regression.c) |
| P | [threaded-prototype-harness.c](/Users/gmoran/Documents/Projects/arm64viz/scripts/threaded-prototype-harness.c) |
| E | [EmulatorBackend.swift](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/EmulatorBackend.swift) |

## Exact Benchmark Representation

F:221-249 creates a fresh context, cache, and fast path for each sample. Its four
words are `ldr x0,[x10]; add x0,x0,#1; str x0,[x10]; b #-12`, at PC `0x8000`.
`x10=0x100000`; RAM is an 8192-byte in-struct array, initially zero. A million
instructions means 250,000 loads, adds, stores, and branches; the assertion checks
one million steps, MAX_STEPS, and final RAM value 250,000. These timed assertions
are narrower than full architectural-state differential tests (F:169-218).

F:127-134 supplies identity translation for this range and ignores the access
direction. The fast path still keeps separate read/write TLBs. Code comes from
the separate `Fixture.code[]` fetch callback (F:18-24), outside this RAM range.
Thus the data page has no tracked code reference. The array is naturally aligned
in this fixture's native struct layout, but a future diagnostic should assert
the actual host pointer alignment rather than rely on the layout assumption.

F:159-166 uses the explicit fast-memory checkpointed entry, which sets
`uses_fast_memory_context=1` (N:15217-15247). The interval is 4096 steps, block
checkpoint interval 10000, total block limit budget+1. The checkpoint checks the
step bound and returns the same limit; mutation is zero (F:34-43). Modes are
established (0), register prototype only (1), and prototype plus memory (2).
The entire four-instruction block is memory-eligible only in mode 2.

Important inclusions and omissions:

- Allocation/setup are outside the clock interval, but first decode, prototype
  preparation, code-cache/trace setup, and first read/write TLB fills are inside
  `memory_run` (F:224-239). This is not a strictly prewarmed handler-only test.
- `fast_path_create` uses calloc and enables detailed memory statistics
  (M:3613-3636). F never attaches guest memory or enables native translation.
  Consequently the fixture has no guest-memory observation arrays, dirty/code
  tokens, exclusive generations, or shared translation journal. Native
  translation is unavailable, not an explicitly configured MMU-off guest.
- Statistics are per-access work: a hot load increments `read_tlb_hits` and
  `read_hits`; stores increment the analogous pair (H:270-273,429-432).
  These are ordinary per-context increments, not atomic RMWs. By contrast E:81
  initializes detailed statistics false and E:2195-2198 applies that selection
  to app sessions. Do not silently equate harness instrumentation to app mode.
- The real app attaches AVZGuestMemory, native translation state, instruction
  translation, and physical device callbacks (E:2168-2213,1395-1410). These
  absent dimensions materially change the path, not just its data values.
- R compiles at `-O3`, with prototype support enabled, from the harness including
  N plus separate B/M/TP translation units. It has no explicit LTO option. The
  `AVZ_RUNTIME_NATIVE_SOURCE` override must be recorded in a future manifest.
  No build from this investigation was made or assumed to match old artifacts.

The existing [memory log](/tmp/pinecone-executor-benchmark-20261028/memory-microbenchmark.log)
has nine samples per variant: every mode-0/1 sample reports 245 checkpoints and
every mode-2 sample reports 247. Median supplied times are 8.019, 8.020, and
20.433 ms, respectively. The memory regression is 12.414 ms per million guest
instructions, about 2.548x elapsed time. The existing
[arithmetic log](/tmp/pinecone-executor-benchmark-20261028/dispatch-microbenchmark.log)
supports the supplied 5.410 versus 16.290 ms (about 3.011x); it reports 7781
superblock hits in established mode and zero in prototype mode.

These are prior measurements, not new runs. The memory log does not print hot
miss reasons, translation callbacks, prototype entries, or superblock counts.
Two additional checkpoints are consistent with two cold memory completions;
they do not independently prove the full expected event ledger below. The
arithmetic loop uses ADD/ADC/AND/branch, not the memory loop with only loads and
stores removed (F:252-269). In particular, the 1.534 ms difference between the
two regression gaps is NOT an estimate of memory-helper overhead.

## Hot Path Comparison

### Scalar Handler And Continuation

TP:389-394 accepts only unsigned-immediate scalar load/store encodings with
flags 0/1 and widths 1/2/4/8. TP:498-504 prepares base/register offsets, width,
mask, and load/store handler. It excludes sign-extending loads, register-offset
and pre/post-indexed forms, pairs, vector memory, exclusive instructions,
acquire/release instructions, and barriers. Ineligible blocks use established
native execution; expanding eligibility is not part of this investigation.

TP:244-278 reads the base plus immediate, attempts the H hot helper, and calls
M's complete helper only on failure of that hot proof. After success it commits
the destination or clears the CPU-local exclusive reservation, then writes the
next PC. Hot completion uses TP_NEXT; non-hot success retires exactly one step
and returns REVALIDATE. Failure returns MEMORY_FAULT without counting the failed
instruction or advancing its PC. Callback side effects are not rolled back.

N:12521-12560 computes the same address and dispatches through the always-inline
wrappers N:93-134. With the fixture's fast-memory mode these attempt **the same
H helpers**, followed by the same M complete helpers. Established stores also
clear all four local reservation fields (N:83-87). Established execution copies
callback-sensitive instruction metadata when needed, then validates at
`callback_step` and may continue without returning to the chain
(N:11182-11203). This callback-labelled path also runs after hot memory success;
the label does not imply a slow callback actually happened.

The prototype instead updates result/budget and checks program retirement plus
local/shared code and translation tokens after every successful hot instruction
(TP:66-75,100-113). Its runtime entry is bounded to one decoded block's
instruction count, even for backward branches; it increments two atomic
prototype counters per invocation (N:13749-13775). Its eligibility bypasses
superblock composition (N:14830-14853). These are real structural differences,
but their costs belong in the combined dispatch/validation attribution, not a
claim that RAM translation itself is different.

### Shared Hot Read Proof

H:180-274 checks pointer/width validity, then, if guest memory is attached, a
relaxed shared translation epoch load against the locally observed epoch. It
rejects page crossing, indexes the 1024-entry direct read-hot array using virtual
page XOR context bits, and checks valid, hot generation, span, virtual page,
context tag, non-null host page, and RAM bounds. Host observation is checked
with an acquire load when present. Naturally aligned widths use relaxed atomic
host loads; an unaligned wider access declines the hot path. No lock, walk, or
virtual callback is required on a successful ordinary hit.

### Shared Hot Store Proof And Commit

H:332-433 makes analogous write-hot checks, but rejects **any** page observation
flag, not just HOST. Its aligned host store is relaxed atomic. It then calls the
inline commit routine H:287-324:

- Attached, unobserved, non-code RAM: load code bits/current dirty epoch; if the
  per-context dirty-hot slot already matches page+epoch, return. Otherwise
  release-store the page epoch and cache that dirty proof. This is not a global
  atomic ticket increment on every ordinary store.
- Code page, missing metadata, or no guest memory: call the external
  `avz_native_fast_memory_commit_write_span` (M:4682-4694).
- In this benchmark `guest_memory==NULL`, so every hot store takes that external
  call. `avz_fast_mark_dirty` returns immediately (M:1520-1522), but
  `avz_fast_invalidate_code_after_write` still calls the block cache
  (M:1569-1586). B:1423-1426 increments invalidation-check/skip statistics and
  returns because the tracked data page has no code reference
  (B:556-585; RAM binding M:3637-3648).

A successful hot store can perform a code commit and still return `hot=1`.
"Hot" therefore means an accepted access path, not a promise of no external
helper or no code invalidation. TP_NEXT must still validate before the successor.

## Miss, Permission, And Exit Contracts

The complete read/write helpers (M:3941-4065) call `avz_fast_translate`
(M:2286-2351). It synchronizes pending shared translation state, retries the hot
lookup, then uses a four-way, 4096-set per-access TLB on a cold miss
(M:2116-2280; H:10-19). A wider TLB hit must have matching mapping/context and
current ASID/TLBI metadata (H:163-168; M:2170-2177). A true miss invokes native
stage-1 translation, or the RAM translator callback when native translation is
unavailable (M:2084-2113). Successful entries fill only the requested read/write
cache, carrying physical/host page and access-specific proof.

Permission is not re-walked on every hot hit. The native leaf validator checks
AF, read-only AP for writes, and PXN/UXN for instruction fetch
(M:1893-1934). A read cache hit cannot serve as a write permission proof. The
context hashes SCTLR, TCR, TTBR output-address bits, and current EL; ASID is
handled separately (M:1782-1815). ASID changes clear hot generations, and wider
TLB entries use ASID/global plus invalidation metadata. Translation-state changes
invalidate decoded mappings; geometry changes also clear TLB generations
(M:3757-3794). These are the implementation's checks, not a claim of complete
architectural permission coverage. For example, this leaf routine does not
validate EL0 AP[1] or inherited table permissions, and the shown native state
does not carry all PSTATE access controls. Shared-helper differential agreement
cannot independently certify those controls. Review them separately before
declaring a future inline proof architecturally complete.

| Non-hot reason | Authoritative completion | Prototype consequence |
| --- | --- | --- |
| Empty/conflicting hot slot, stale generation, or insufficient span | Wider TLB/walker/callback lookup, then RAM or physical result | Even successful RAM fill returns REVALIDATE after the instruction |
| Shared translation epoch differs | Synchronize journal under publication lock; invalidate local translation/decoded mappings as needed | Entry/next guard may exit before a memory access; a complete helper success also ends the run |
| Host-observed or unaligned RAM load | Full read uses page stripes when guest memory exists, then aligned atomic or byte loads | Completed instruction, then REVALIDATE |
| Host/bulk/exclusive-observed or unaligned RAM store | Full store refines observation, locks if needed, stores, commits tracking, unlocks | Completed instruction, then REVALIDATE |
| Cross-page scalar access | Native scalar translator declines it; virtual slow callback owns splitting and faults | Completion exits; failure is MEMORY_FAULT |
| Translated device/non-RAM address | Physical callback when configured; otherwise virtual callback path | Callback completion/failure exits; no hot continuation |
| Translation fault | Set pending fault and report it; do not fall through to slow callback | Faulting instruction is not retired |

Full RAM reads lock for host observation or unaligned access
(M:3961-3986). Full stores lock for unaligned access or relevant host, retained
bulk-reader, or exclusive observation (M:3004-3035); a page-level flag can cause
the hot rejection even when refined checks find no overlapping observer.
Cross-page app callbacks split accesses in E:1524-1570 and E:1619-1670. Those
helpers, not TP_MEMORY, determine partial effects if a later byte faults. Do
not infer transactional multi-byte rollback from a precise faulting PC.

Physical callbacks return their success/failure directly and must not be
retried via the virtual callback because device side effects may already have
occurred (M:3990-4004,4044-4056). The chain maps REVALIDATE to an outside-block
continuation, clears predecessor linking, and forces a checkpoint; MEMORY_FAULT
also forces a checkpoint and breaks instead of retrying
(N:15022-15107). In the app, virtual callbacks can enter Swift memory/MMIO and
fault-reporting code (E:3622-3649,3809-3835); that is not Swift *instruction*
fallback and is not exercised by this native RAM fixture.

## Observation, Invalidation, And Synchronization

Host and bulk observation flags are release-published (M:240-311) and consumed
with acquire loads. Host-range registration takes page stripes, publishes
observation, executes a seq_cst fence, and releases the stripes
(M:379-402). Its documented ownership boundary matters: a flag alone is not a
proof that arbitrary new observers can safely race earlier unobserved accesses.
This analysis does not prove registration races or mapping lifetime safe.

Exclusive reads take stripes, publish page/16-byte-granule observations, load
the value, and capture the write generation (M:3312-3360,1077-1112;
H:24). Later ordinary stores to those pages decline the hot store proof. The
full commit updates observed granule generations even for a same-value write
(M:1115-1167,1559-1560). Exclusive stores lock and compare generations before
storing (M:3445-3499). Clearing CPU-local reservation fields after an ordinary
store does not replace this shared monitor. None of that generation/lock work
exists in the measured fixture, whose CPU reservation is initially zero.

Code-page marking is shared through code bits (B:410-411; M:945-959). A code
store updates page write generations and the shared code-mutation epoch, then
invalidates the local block cache (M:1539-1586,989-1061). The shared epoch uses
acq_rel publication; consumers acquire-load it. B:1409-1485 either bumps tracked
code-page/local epochs or invalidates overlapping entries. TP pins the immutable
program for the run, checks retirement/epochs, and only frees a retired program
when its last active run ends (TP:55-63,564-596). This permits callback-driven
retirement without using its old successor; it is not permission to mutate a
peer's private cache concurrently. With attached guest memory, the block-cache
shared-code token and TP memory-code token resolve to the same underlying
code-mutation epoch (B:1877-1882; M:1015-1020; TP:577,583). Whether the generated
code issues redundant loads, and their cost, belongs to validation attribution.

TLBI publication serializes a 64-entry shared journal and release-stores its
epoch (M:1364-1379). Synchronization copies records under the publication lock,
applies local invalidation, falls back to full invalidation on overflow/wrap,
and updates the observed epoch (M:1708-1745). Applying scoped invalidation
invalidates hot generations; wider entries can revalidate against scoped epochs
(M:1599-1607,1637-1690). Chain time advancement also synchronizes translation
state, including register-only work (M:3895-3921). Neither the lock nor a changed
epoch is present in the timing fixture.

Ordinary hot RAM loads/stores use relaxed atomics, not guest acquire/release
semantics. Established acquire/release instruction handlers add fences
(N:12411-12444); TP's subset excludes those instructions. Locks and epoch loads
must not be indiscriminately removed or replaced with plain data accesses.
Cache and fast-path structures are vCPU-confined; guest RAM and its publication
metadata are the intended shared layer. This pass traces that design, not a
formal memory-model or cross-vCPU lifetime proof.

## Ranked Attribution Hypotheses

Ranking is investigation priority based on source reachability, not measured
fractions of time. The supplied medians prove regression only.

| Rank | Hypothesis and evidence | What would support or reject it |
| --- | --- | --- |
| 1 | Recurring executor entry/accounting/guard costs dominate the difference despite shared RAM helpers. TP has per-instruction checks and per-block entry/counters; eligible blocks bypass superblock composition. Arithmetic is also slower. TP:66-113; N:13749-13775,14830-14853. | Parent's matched entry/validation variants and generated code must explain a material fraction of both loops; memory-body-only comparison must not reproduce the whole gap. Do not assign this rank a percentage yet. |
| 2 | Store commit-call ABI interaction, handler-local register pressure, PC/state materialization, or dynamic width branches make the same helper more costly in TP. Every fixture store reaches an external commit/invalidation check. H:287-324,332-433; TP:244-278. | Annotated hot-path assembly and call-preserving versus call-eliding offline controls show differential spill/reload/body cost. Equal call counts alone neither prove nor refute it. |
| 3 | Detailed per-access memory statistics and surrounding loads/branches interact differently with the two executors. Both enable the same counters here, unlike the app default. M:3635; H:270-273,429-432; E:81. | Matched statistics-on/off fixtures change the executor gap, with unchanged hit/exit counts in separate diagnostic runs. A common absolute speedup alone is not differential attribution. |
| 4 | Cold decode/preparation and the first read/write fills contribute to sample totals. F:237-239; saved checkpoint delta is two. | Separate cold and fully prewarmed runs quantify the intercept. A persisting warmed gap rejects cold setup as the principal cause. |
| 5 | Real-workload observer/TLB/MMIO/unaligned exits amplify TP overhead by forcing chain checkpoints and losing continuation. TP:273-275; N:15065-15107. | Controlled misses and actual workload reason counts demonstrate frequency and incremental cost. Not an explanation of this fixture's steady state without contrary event evidence. |

Not plausible explanations for the current fixture: shared page-table walking
per instruction; continuous translation shootdowns; exclusive-generation ticket
contention; renderer/host page locks; native physical MMIO callbacks; guest code
writes on the data page. These paths are absent by setup, not measured to be
"cheap." The ordinary relaxed RAM atomics and block-cache invalidation-skip
checks are present in both modes and cannot be called prototype-only costs.

## Exact Offline Experiments For The Parent

None were implemented or run here. Use disposable native-only source snapshots
outside the runtime checkout, retain their diffs and identities, and never
install diagnostic binaries or change app defaults. Any check omission below
is limited to a single-thread synthetic fixture with fixed code/mappings and no
observers. It is not a proposed production fix.

### A. Freeze Identity And Verify The Event Ledger

Use F/R as the fixture/build specification. Record compiler executable/version,
target, optimization/aliasing/LTO flags, source hashes including the override,
binary hash, and host architecture. Collect a diagnostic **untimed** million
steps per mode with counters emitted only after execution. Count separately:
hot read/write successes, reason-coded hot failures, complete helpers, wider
TLB hits/misses, translation callbacks, virtual/physical callbacks, commit-span
calls, invalidation checks/skips/actual invalidations, TP entries/steps/statuses,
superblock entries/steps, semantic fast steps, and checkpoints.

Expected source-derived ledger, to test rather than assume: 250,000 reads and
stores each; one cold read and one cold write; 249,999 hot successes per access
type; two data translation callbacks; zero virtual/physical data callbacks;
249,999 hot-store commit-span calls plus one full cold-store commit;
250,000 block-cache invalidation checks/skips, no code epoch changes; two
memory-caused REVALIDATE completions in mode 2 and no memory faults. Instruction
translation activity must have separate counters. Preserve final PC/registers,
memory, step, and status assertions. Any unexpected recurring failure changes
the hypothesis ranking before timing is interpreted.

Existing `read_hits`/`write_hits` include RAM completions inside full helpers;
`*_tlb_hits` conflate direct-hot and wider-TLB hits. They cannot replace explicit
inline-success counters. `threaded_memory_boundaries` counts all prototype
REVALIDATE returns, including guards, not exclusively memory-helper misses.

### B. Separate Preparation, Cold Fills, And Warm Execution

Compare the original cold F run with three explicit offline preparations:
decoded/program prepared only; prepared plus read/write TLB warmed; and the
entire chain/trace warmed by an excluded 8192-step run. For the last arm, reset
CPU architectural state, the data value, and observation counters outside the
clock interval while retaining code/TLB/trace caches. Restore data through the
same valid helper, not by resetting cache metadata. Keep code words, interval
4096, budget 1,000,000, and executor selections identical. Time preparation
separately rather than silently moving it out of the result.

Run A's event ledger on each arm first; the warmed arm should show zero data
translation callbacks and zero memory-caused REVALIDATE events. Parent then
collects at least nine alternating samples per arm without concurrent builds,
VMs, or instrumentation runs. Report all samples, medians and spread, not a best
sample. Retain the original total for comparability; differences of medians
are experimental contrasts, not automatically additive component costs.

### C. Resolve The Recurring Store Call

Inspect generated code for `tp_load`, `tp_store`, and the established
unsigned-immediate handler with the **same** compiler/options/source snapshot.
Annotate only the observed warmed width-8/no-guest-memory branch: instruction
bytes, conditional branches, helper calls, stack stores/loads, CPU/operation
loads, PC/reservation writes, validation, and counter writes. Separate rare
helper branches from executed paths. Inspect emitted code or a provenance-
matched existing binary; do not assume C `inline` determines register traffic.

In an isolated fixed-RAM/no-code-data snapshot, compare three matched modes:
original commit helper; an external noinline no-op with the same signature;
and elision of that call at its fixture-only call site. Keep the actual RAM
store and all TP/executor guards/accounting. Verify disassembly retains the
external call in the second mode; do not allow LTO to erase it. The first-to-
second contrast estimates commit body plus interactions; second-to-third
exposes call/ABI consequences. Run both executors for every variant and report
the change in their gap, not just each absolute improvement. Assert data never
overlaps decoded code and no code/translation mutation occurs. These unsafe
generalizations must not leave the disposable harness.

Also compare an otherwise identical, attached AVZGuestMemory fixture using its
own allocated RAM and `set_guest_memory`. This should replace the steady
external commit with the dirty-hot check, while adding shared epochs and
observation loads. Treat that as a **bundle** of changes; it cannot by itself
isolate the commit helper. Test dirty-epoch unchanged versus advanced once per
4096-step checkpoint to distinguish the dirty-hot hit from first-write work.

### D. Statistics And Handler-Only Controls

Run original and fully warm F with detailed statistics explicitly on/off for
both executors via the existing setter in the offline harness. Hold all other
state fixed. Diagnostic event counts belong in separate runs, because extra
instrumentation perturbs the target cost. Report whether the *gap* changes.

For a handler-only control, prepare the same four decoded operations and TP
program, warm RAM, and execute matching budgets through direct executor APIs
outside the chain. Use the same cache guard availability and memory attachment
in both arms; record any unavoidable contract difference. Separately run an
identical noinline helper loop with 250,000 read/add/write iterations using H's
helpers and a consumed final value. This establishes a memory-body reference,
not an emulator score (it has no guest branch/PC/retirement work). Coordinate
with the dispatch/validation owners so changing entry frequency or token
availability is never mislabeled a memory optimization.

### E. Controlled Miss And Observation Matrix

Starting from attached, warmed RAM, change exactly one condition at a time:
width 1/2/4/8; host offset +1; a width-8 address at page offset 4093; registered
host observation; a real retained bulk reader; prior exclusive read of the same
16-byte granule; cold read/write entries; native stage-1 writable versus read-
only mapping; and physical device callback success/failure. Use public observer
APIs, not just a page flag, when testing synchronization cost. For direct-hot
conflicts expand the offline RAM allocation and alternate same-context addresses
4 MiB apart (1024 pages), which collide in the hot index; distinguish wider-TLB
hits from actual walks. Read/write caches do not conflict with one another.

Record exit reasons, retired prefixes, callback count, lock acquisitions, and
architectural/memory state before considering timing. Reject double device
callbacks, changed fault PC, stale code, or incorrect dirty/exclusive state.
For each non-hot feature compare normal TP exit behavior against its own warm
control and established C's matching feature. Do not extrapolate to Phosh
without measured frequencies for that feature in the real workload.

### F. Shared-State And Invalidation Representation

Use two native workers with separate fast paths/caches and shared AVZGuestMemory,
as C does. Publish one scheduled peer code write or TLBI after the first visible
data store; collect retired prefix and exit reason. Test data-only stores,
self-code stores, other-code-page stores, ASID/VA/global/all invalidation, and a
register-only tail after a memory instruction. Test callback retirement and
remapping at the same boundaries. Measure event-service bounds only in a later
parent-owned run; absence of crashes is not a visibility proof. Any proposed
check-amortization control needs the validation owner's lifetime/ordering
contract first. No global disabling of code, observation, or exclusive tracking
is justified by the synthetic median.

## Existing Coverage And Limits

Tests were inspected, not executed or certified in this pass:

- P:684-765 covers widths, SP/XZR/alias registers, offset extremes, host-observed
  memory, unaligned/cross-page/end-of-RAM accesses, translation faults, EL1
  read-only mappings, and callbacks destroying the program. Much of this
  intentionally forces a complete-helper boundary; it is not a warmed throughput
  measurement or independent walker specification.
- C:146-184 checks warmed continuation across widths/SP/XZR/budgets against
  established C, including memory and dirty ranges. C:187-279 covers callback
  failure/success, physical MMIO once-only, retirement/eviction, code writes,
  remapping, and pending TLBI. C:282-316 checks same-value exclusive invalidation,
  host observation, unaligned/cross-page stores, and translation faults.
- C:292-294 sets only a bulk page-observation flag. That proves hot-path rejection,
  not retained-reader synchronization or a concurrent DMA lifecycle. C:336-374
  checks concurrent shootdown exits including register-only tails, but only
  requires stopping before a very large instruction budget, not a tight latency
  bound. C:387-412 checks twelve exact timer boundaries in the native chain.
- [ThreadedMemoryFaultTests.swift](/Users/gmoran/Documents/Projects/arm64viz/Tests/ARM64VizCoreTests/ThreadedMemoryFaultTests.swift:37)
  has VM-facing load/store retired-prefix fault tests. Native fixture callbacks
  and these tests still do not cover all device side effects or cross-page
  second-page faults and partial writes.

The timing workload says nothing directly about page-table working sets, ASID
turnover, TLB conflict rates, cache pressure from real operation streams,
observation publication races, code marking races, concurrent remapping,
exclusive fairness, all permission combinations, DMA retention, or host memory
reclamation. It also omits pair/vector/atomic/acquire-release instructions and
bulk semantic fast paths. Matching two executors that share a helper can hide
a common helper bug. Full-system/native permission auditing and validation
proofs remain separate work. No conclusion here promotes the prototype or
weakens the existing correctness checks.

## Source Snapshot

HEAD was `c3b3e957a9ee27bdcbe37c42925d98cf4563b19c`, with pre-existing dirty
runtime files. This report analyzes those working files; HEAD alone cannot
reproduce it. The saved timing logs do not themselves bind their binaries to
these hashes, so source-to-timing identity still needs the parent's manifest.

| Source ID | SHA-256 at inspection |
| --- | --- |
| TP | `5fd3ae108b6f860d698e3a7998743eb72f2725b75f7d8ed87678905fb3b07416` |
| H | `ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9` |
| M | `d2233c3b054b0cbffcd28e36ceb46451a2424ed4b3db590f2be1841994649266` |
| N | `a1f6ca7ce718bbc7eb271ca3153d935b671d8e7bb502960982020466f108269f` |
| B | `5153bd7b2c98007d0c80b10de11a45eb87a48e797f204025a5ed92b82e591992` |
| F | `79545f80af49ce93c60fa231c049fd0b9b714afbcca1f88bdbf87c3f6a5fee41` |
| R | `c57fdd8c5359155cc5ed39260f4f7404bfbd817c607f41c5067163107e5604c7` |

All pre-existing dirty files were left untouched. No claim of passing tests,
generated-code attribution, or a specific regression cause is made.
