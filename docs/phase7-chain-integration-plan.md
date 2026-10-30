# Phase 7 Bounded Assembly Chaining: Manager Review

Date: 2026-10-29. Status: readiness design, **not authorization to enable longer
production assembly runs**. Established C and the current opt-in single-block
adapter remain unchanged. No speedup claim, Simulator run, full build, timed
benchmark or commit belongs to this task.

Follow-up: the separately opt-in production adapter and resident service veneer
are now implemented. See [integration results](phase7-production-chaining-results.md):
functional checks pass, but the native cost screen fails. This historical plan
does not authorize default promotion or imply that chaining is faster.

Read together with [Phase 2](phase2-execution-contract.md),
[the current adapter](phase7-assembly-integration.md), and the Phase 7 work order
in [roadmap.md](../roadmap.md). The roadmap's older introductory statement that
assembly is not linked is superseded by the adapter document and current source;
it must not be read as evidence that production multi-block assembly exists.

## Decision Summary

Do not replace `avz_native_run_assembly_block` with `ag_chain_run` and merely
increase its allowance. The offline API lacks native timer service, per-call
visit accounting, production cache/context enrollment and semantic admission.
The new tests below make the first three distinctions executable. Keep the
decoded-length cap until the later stages pass production-path tests.

The first proposed graph is owner-private, immutable, strictly dependent on
resident decoded-entry identities, and conservatively invalidated on any proof
change. It copies operations; it does not patch FIFO-owned `AGProgram` objects.
No proof reuse across unrelated writes, new shared graph cache, or larger
retention policy is necessary for initial correctness.

## Source Boundaries

Symbol names are the review anchors because the cache diagnostics owner is
changing line numbers concurrently. The source reads include that worker's
uncommitted changes; this task does not edit or claim ownership of them.

| Boundary | Current behavior | Required integration point |
| --- | --- | --- |
| `ARM64VizNative.c`: `avz_native_execution_context_run_cached_chain_checkpointed_impl` | Selects validated C superblock first, then decoded successors/cache; tests assembly eligibility; handles barriers and checkpoint callbacks; accounts steps/blocks and calls `advance_time` after execution | Keep this outer scheduler and C precedence. Introduce graph selection only at the existing assembly alternative, after fresh selection following any checkpoint |
| `avz_native_run_assembly_block` | Captures local/shared code epochs before cache preparation; caps to min(requested steps, decoded length); calls `ag_run_memory` | Retain as rollback and one-visit control. A graph runner needs an equally early proof plus reset/context/translation identities for every member |
| `ARM64VizBlockCache.c`: `avz_assembly_cache_program` | Rejects both ordinary and mapped-trace semantic candidates; caches negative eligibility; owns a 256-program FIFO separately from decoded entries | Admit every graph member/target through the same semantic policy; coordinate with diagnostics worker, do not duplicate a competing telemetry structure |
| `avz_assembly_release_slot`, `avz_assembly_forget_entry`, cache clear/destroy | Retire single-program snapshots; active invocation pins defer free | Add owner-local graph dependency retirement before member invalidation/reuse/untracking; cache/RAM destruction still requires quiescence |
| `avz_entry_code_is_current`, `avz_native_decoded_block_serial_token`, `avz_native_decoded_block_code_is_current` | Check entry serial, local/shared physical code generations and mapping validation after translation changes | Select/validate before copying; recheck all captured identities after copying; pointers alone are not identity |
| `ARM64VizGuestMemory.c`: `avz_native_memory_fast_path_advance_time` | Catches up shared TLBI even for register-only execution, advances/refreshes counter, checks PSTATE.I and native IRQ/timers | Invoke at every preserved assembly visit boundary or return to this existing call; an offline event pointer is not a replacement |
| `Assembly/gadget_arm64.S`: `VALIDATE`, `RETIRE`, `ag_boundary` | Entry and per-retirement epoch checks; boundary polls atomic events and decrements visits, but performs no native timer/checkpoint work | Keep guards; add a separately reviewed service ABI or remain return-at-each-visit |
| `experiments/phase3/chain.c` | Creates its own sorted graph/program copies, page proof scan/reuse, whole-graph owner pin; reports visits only through optional cumulative statistics | Reference implementation, not production cache adapter. Return per-invocation state before considering continuation |

The non-checkpointed `avz_native_execution_context_run_cached_chain` path must
remain on current short calls unless it is explicitly given the same service
contract. Do not accidentally widen it through a shared wrapper.

## Ownership And Proofs

One host thread owns each vCPU's execution context, decoded cache, fast-memory
path, FIFO programs and graph. vCPU 0 and vCPU 1 must never share mutable graph
nodes or `active`/`retired` counters. Only guest-memory atomics/journal and an
explicit atomic event publication channel may be written by peers.

Proposed graph header contains cache identity, cache reset epoch, full canonical
`AVZNativeBlockKey` context (EL, SCTLR, TCR, both TTBRs including address-space
identity), captured local code epoch and shared code/translation epochs, memory
binding identity, owner pin/retired state, allocation bytes, and member count.
Each member stores PC range, serial token/value, physical code page identities
and local/shared generation token/values. Those tokens, cache, RAM, CPU and fast
path must outlive **all** graph runs and deferred reclamation.

Admission procedure:

1. Synchronize pending shared translations on the owner. Capture proof epochs
   before validating any code. Use existing canonical key and mapping checks.
2. Collect only already decoded, validated, eligible successors. Do not fetch
   speculative targets: speculative decode can change fault state or invoke a
   translation callback. A missing target exits to the existing selector.
3. Apply semantic, chain-barrier and host-checkpoint-barrier exclusions to every
   member, not just the root. For the first patch also exclude system, wait,
   synchronization and context-changing instructions even when the current C
   metadata permits some coherent cache maintenance or barriers within a chain.
4. Copy operations into graph-owned storage, sort disjoint PC ranges, validate
   branch-last layout, and link only graph-owned gates. Never rewrite `taken`
   or sentinel operations in shared FIFO programs. Reject unsupported forms and
   allocation failure without changing C eligibility or evicting a hot program.
5. Initially require each member to fit one guest and one physical 4 KiB code
   page; otherwise use C/single-block execution. Offline `AGBlock` has only one
   atomic generation pointer, while production blocks can have multiple physical
   page dependencies and owner-local **non-atomic** tokens. Never cast a local
   `uint64_t` generation into `_Atomic` to force it through the offline API.
6. Recheck epochs, context, mapping and serials after copying, then publish on
   the owner. Pin before dereferencing executable operation/target pointers.
   Stale proof or identity means discard/reselect, not sample a newer epoch to
   bless older instructions. Memory-view proof elision requires both identical
   token address and identical captured value.

Strict residency is the initial lifetime choice. On eviction of any dependent
decoded entry, retire its graph **before** dropping code tracking or recycling
the serial. A FIFO program-slot eviction alone does not invalidate a graph's
private copy if the decoded identity and its enrollment remain intact. Cache
clear retires every graph before resetting entries/refcounts; an active graph
stays allocated until its normal return. Do not call destroy twice on a freed
graph, and reject same-graph reentry while pinned.

This matters beyond pointer safety: `avz_guest_memory_note_write` publishes
code-page generations/code epoch only when the range may contain code. A copy
that survives loss of enrollment could execute stale code even while its memory
allocation remains pinned. Retaining graphs past decoded-entry eviction is a
different design requiring independent physical-page registration references.
Do not infer such ownership from `ag_chain_create` or `ag_chain_bytes`.

Initial proposed hard bounds, subject to manager approval: one published graph
per vCPU, at most eight members/128 decoded instructions, at most 32 KiB of
total graph allocation including operations, gates, targets and proof metadata.
Do not build replacements while an old graph is active; callbacks may retire
but not rebuild it. This bounds graph allocations to 64 KiB across two vCPUs,
in addition to the existing FIFO/cache. Reject oversize graphs. These are
conservative correctness/resource limits, not a throughput recommendation.

## Exact Service Contract

Maintain separate counters for global retired instructions, steps since host
checkpoint, block visits since host checkpoint, global visits, and instructions
already charged to native timer state. A visit is an admitted block suffix at
initial entry or a branch/fallthrough target, including repeated loop visits.
Partial final visits count; a denied event gate admits no visit. Define zero-step
pre-entry rejection separately from the old outer loop's one attempted block.
Never use optional telemetry or cumulative counter subtraction for scheduling.

Proposed private result carries the existing architectural result plus
`visits`, `timer_accounted_steps`, an explicit stop reason and last-member
identity (only usable after revalidation). Preserve fault/unsupported status
over a coincident service reason. Regenerate/static-assert assembly offsets.
`AVZNativeBlockResult.mapped_blocks` is currently zero for the offline graph:
the new harness demonstrates that four visited blocks cannot be inferred from
that result. Prefer a private result instead of silently changing the public
C/Swift result ABI or repurposing existing diagnostic counters.

At every entry/reentry compute checked, saturating remainders:

```text
S = min(global_steps_left, checkpoint_steps_left,
        applicable_timer_steps_left, native_service_steps_left)
B = min(global_visits_left, checkpoint_visits_left)
zero S or B => return/service; never pass zero as an unlimited allowance
```

Current concrete limits and ordering:

- Current assembly allowance is at most decoded length, at most 16, including
  backward self-loops. Offline snapshot/graph capacity is not a service budget.
- Production native service is after each assembly return. Its PSTATE.I-aware
  test includes `pending_irq`, enabled/unmasked physical and virtual timers.
  For instruction-clock timers, compute distance with checked subtraction and
  ceiling division by cycles/instruction; an already-due unmasked event allows
  no further instruction. Masked IRQ must not spuriously yield. Zero cycles is
  not a division and is not a substitute for host-clock service.
- `counter_refresh_instructions >= 1024` triggers host-clock refresh at native
  service boundaries. This is a threshold, not a hard 1024-retirement ceiling;
  crossing it in the current block is allowed. A widened graph cannot defer
  refresh to its final return. Use the existing clock/advance implementation,
  with per-boundary deltas, rather than a new clock or estimated milliseconds.
- Swift initially supplies a timer-clamped allowance no larger than 65,536;
  the native chain global block cap is 262,144. Host checkpoint interval is
  configurable, defaults to 1,024, and is clamped to at least one at the call.
  Subsequent Swift checkpoints currently return `min(remaining, 65_536)` without
  recomputing the timer distance there. Therefore retain native per-boundary
  timer service; do not assume every returned allowance is deadline-clamped.
- Swift checks stop/preemption at checkpoints, and wall deadline only when its
  next 4,096-accounted-step threshold is reached. This is not a wall-time
  guarantee. Preserve or shorten both step and visit checkpoint schedules.
  Translation-fault attempts add one to Swift accounting, not native retirement.
- An atomic nonzero `events` is a request to return, not IRQ acknowledgement.
  Production `pending_irq` is not the offline `_Atomic uint64_t events` storage;
  do not alias it or make peers mutate a private fast-path state. Wiring a live
  host-preemption/event token needs an explicit producer and lifetime contract.

Initial adapter stage sets `B = 1`, uses the current decoded-length bound, and
returns to the existing native service/checkpoint logic. Later continuation
must service each visit before entering the next. Gates may service earlier
(e.g. a loop into a suffix) but never later than the old block-length return.
Also impose the current visit's decoded-length cap so an internal cycle cannot
hide behind a large graph allowance. A numeric instruction budget alone does
not preserve native IRQ polls on every short block.

For true multi-visit calls, add an ordinary ABI-compatible service veneer which
materializes CPU/PC, preserves host callee-saved registers/stack/unwind rules,
and calls native service with **only the uncharged retirement delta**. It must
not run arbitrary device/Swift callbacks and then resume an old successor.
TLBI catch-up during service may mutate the owner cache: keep the graph pinned,
recheck epochs/retired state, and terminate on any change. Return for a host
checkpoint, then release the pin and freshly select. At final return charge
only residual steps in the outer scheduler, including fault prefixes, so timers
are not advanced twice. A service veneer is a new ABI path requiring tests;
the existing two terminal memory-helper calls do not establish its correctness.

## Helpers And Semantic Fallback

Preserve existing C superblock precedence and both semantic-candidate arrays.
Exclude an entire candidate-containing block, including entry through an
interior PC; never link into its suffix to evade the policy. A branch to that
PC exits after retiring the branch, then fresh selection gives the authoritative
C path its normal budget. Keep PLT, string, bulk and mapped-trace accelerators;
do not synthesize their hit counts or replace them based on assembly coverage.

Hot RAM retains translation/access/observation/dirty/exclusive/code-write guards.
MMIO, translation misses, pair partial faults, unaligned/cross-page cases and
observer transitions use authoritative helpers. Successful helper commits once
and returns REVALIDATE even on the final budget instruction. Failure returns
MEMORY_FAULT at faulting PC, with no retirement/writeback for that instruction;
any helper-owned device effects or earlier pair-store effects remain. Neither
case is unsupported or permission to replay through C/Swift. No successor
continuation after a helper, even if its callback left epochs unchanged.

Outer handling must preserve current precedence: map REVALIDATE to normal
selection exit and force checkpoint; IRQ may yield but cannot overwrite HALTED,
UNSUPPORTED or MEMORY_FAULT. Zero checkpoint allowance ends that invocation;
later resume gets fresh selection and allowance, not a sticky halt. Retain
pending fault data if host stop/preemption wins in Swift before fault delivery.

## Shared Invalidation And Two-vCPU Reclamation

Shared code write publication updates enrolled physical-page generation before
release-publishing code epoch. Keep entry and every-retirement acquire guards;
the instruction already in flight is not revoked. Test aliases of one physical
code page and writes from both guest and device paths. Initial graphs retire on
any epoch mismatch; defer the offline unrelated-write rescan/proof-hit shortcut.

Shared TLBI has a 64-entry locked journal and release-published epoch. The owner
collects under the same lock, applies local invalidations and only then updates
its observed epoch. Lag greater than 64, or backwards epoch, causes full local
invalidation. Keep this path for register-only tails. A fresh memory snapshot
cannot bless a graph created before TLBI. ALL, ASID, VA+ASID and VA-all-ASIDs must
all force the required local catch-up and context-aware code revalidation.

Peer publication is not permission to call `ag_chain_destroy`, mutate private
serials, free token arrays, or reset a peer's cache. It is also not proof of
DSB/ISB completion or peer acknowledgement. Keep synchronization instructions
in authoritative C paths. Teardown, RAM replacement, cache rebind and generation
identity reuse require both vCPUs stopped, no active graph/program pins, and
device/graphics readers quiescent. Counter wrap must cause quiescent full
invalidation of code/TLB/direct-link/graph proofs, never an ABA match.

Required deterministic concurrency test for the future adapter: rendezvous
before a successor gate; peer writes code or publishes TLBI; owner observes the
publication and exits without executing the stale successor; owner callback
retires graph while pinned and allocates/recycles cache entries; assert no free
until return and no old serial/PC reuse. Repeat with two distinct execution
owners and journal overflow, then teardown after joins. The current new tests
do **not** execute this scenario or certify two-vCPU graph reclamation.

## Staged Patch Design

1. **Private contract, no longer calls.** Add per-call graph result/visit and
   timer-charge state, explicit stop reasons, static offsets, opt-in selection
   default off. Keep FIFO/single-block behavior and all semantic filters. Test
   exact steps, visits, entry rejection and status precedence with telemetry off.
2. **Production ownership, one visit.** Add cache-owned graph builder, strict
   residency dependency hooks and reset/context proofs under the limits above.
   Preserve C superblocks/semantic targets; return at each visit. Production C
   tests must exercise eviction, callback clear, code writes, remapping and
   serial reuse against the actual graph adapter, not synthetic proof tokens.
3. **Service veneer, still opt-in.** Introduce per-visit native service and
   residual timer accounting, then permit `B > 1` only under both global and
   checkpoint budgets. Add all timer types, IRQ masking, service threshold
   crossings, exact partial blocks, self-loops, interior direct/indirect
   targets, checkpoint zero/resume and fault-vs-stop tests. Verify ABI/unwind
   for the new nonterminal service call and disabled/unsupported-host paths.
4. **SMP and memory gate.** Run deterministic two-owner publication/reclamation
   tests above, MMIO success/failure/replay counters, pair partial faults,
   observer changes, ASID aliases and journal overflow. Test graph retirement
   during service and during a terminal helper. Supported-host ASan and TSan
   where applicable complement UBSan; neither is claimed by this task.
5. **Manager-only integration/promotion.** Reconcile diagnostics changes, run
   native/Swift integration regressions and serialized full-system smoke tests,
   then matched baseline/assembly cohorts under the roadmap protocol. Require
   zero Swift fallback, bounded allocation and no event-service regression on
   both vCPUs. Cache attribution precedes tuning graph retention. Keep rollback
   to single-block assembly and established C independently selectable.

Blocking stage 3/long-run enablement: missing service ABI and per-call result,
missing cache dependency/enrollment lifetime, no production graph key/mapping
proof, no real two-owner graph reclamation tests, no all-target semantic filter,
and no end-to-end event/interaction evidence. Existing offline throughput and
single-block VM smoke evidence close none of those graph integration gates.

## New Bounded Tests And Results

Files owned by this task:

- `docs/phase7-chain-integration-plan.md` (this document).
- `scripts/phase7-chain-integration-contract.c` (new standalone test).
- `scripts/run-phase7-chain-integration-contract.sh` (new standalone runner).

Commands from repository root:

```sh
sh scripts/run-phase7-chain-integration-contract.sh
sh scripts/run-phase7-chain-integration-contract.sh --ubsan
```

The runner compiles only a standalone native harness and its dependencies in a
temporary directory, checks generated offsets, and removes its artifacts. It
includes production `ARM64VizNative.c` in the test translation unit for access
to CPU setup, links the current cache/memory and canonical assembly, and also
links **offline** `experiments/phase3/chain.c`. No existing fixture is modified
or reused as a replacement for a new test. The 30-second alarm is a safety
timeout, not a benchmark; loops are fixed and bounded.

Optimized (`-O2`): PASS. UBSan (`-O1`, undefined behavior sanitizer,
no recovery): PASS. Shell syntax (`sh -n` on the runner): PASS.

| Check | Scope and outcome |
| --- | --- |
| Physical timer, virtual timer, native pending IRQ | Three gap witnesses: production single-block adapter yields after two retired instructions/one block; raw offline graph retires eight/four visits with unchanged native counter. One-visit fence followed by authoritative `advance_time` restores service. Pending IRQ case tests the C API boundary, not Swift's earlier pre-entry IRQ check |
| Steps/service/visit matrix | 324 offline cases with exact retirement, PC, register values, status and cumulative visit deltas; zero limits reject without effects, UINT64_MAX step allowances remain fenced to one visit. Returned `mapped_blocks` remains zero, exposing the missing production result contract |
| Event already published | Offline zero-step yield admits no visit, preserves CPU and does not acknowledge the token |
| Checkpoint zero, fresh resume, partial block | Current production adapter stops at one two-instruction block; a fresh run retires exactly three across two visits |
| Semantic successor | Raw offline graph admits a PLT target; production cache rejects it for assembly. Actual production assembly predecessor retires two, C PLT retires four with one fast-path hit and correct target/register state |

These are characterization/contract assertions: a future corrected API should
replace the gap-witness expectations with service/accounting invariants, not
preserve the missing behavior to keep tests green. They do not assert a failure
of the deliberately offline API's documented caller-owned service contract.

Production-path rows run real native adapter/cache code in a standalone process.
They are **not** Swift VM runs, production multi-block assembly, concurrent
two-vCPU tests, host-clock latency tests, boot/Phosh validation or performance
evidence. Existing suites cited in the adapter document were read, not rerun by
this task. No ASan pass, default promotion or user-visible speedup is claimed.
