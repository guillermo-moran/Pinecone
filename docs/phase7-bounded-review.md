# Phase 7 Bounded-Service Review Contract

Manager follow-through after the independent review: the peak-byte sampling
finding below was fixed by measuring the live graph before retirement clears
its owner pointer. A production regression prepares and retires a bounded graph
in the same invocation and asserts the enlarged peak. The final normal and
LLVM ASan 18-case production suites and cache ownership/disabled-build checks
pass. This note records the integration result; it does not rewrite the
independent review's historical findings or imply a performance promotion.

Status: independent C/assembly source review complete, 2026-10-29;
**not a promotion sign-off**. Allocation-isolation P2 resolved; one P2 peak-byte
diagnostic finding remains after the final lazy-preparation delta review.
Production service across multiple blocks is authorized. Runtime implementation
belongs to the runtime agent; integration belongs to the parent. This sidecar
changes no runtime and runs no tests, builds, Simulator, or performance work.
Finalized after the parent marked Bohr's runtime stable. Parent/agents report
all eight lazy-allocation failure cases, all 18 production cases (including
ordinary fallback, no false bounded counts, and successful retry byte refresh),
and the final normal run passed. Final UBSan and incremental Release build were
still running at closeout; the earlier Release build succeeded but was not
installed. These are reported results, not independently executed verification.
No further runtime edits or review work are scheduled by this sidecar.

## Finding For Bohr And Parent

**P2: Lazy allocation peak is lost when the same run retires its graph.**
`ARM64VizBlockCache.c:2632-2638` refreshes bytes/peak only after confirming the
graph survives. On first bounded use, preparation can grow the graph and then a
helper, service invalidation, or final proof check can retire it. The retirement
hook clears/destroys the chain without sampling its enlarged byte count; the
wrapper then clears metadata or retires before its accounting branch. Thus peak
can remain at the generic allocation even though bounded storage existed.
Sample owner-inclusive bytes/peak before destruction in the retirement hook (or
return prepared allocation high-water separately). Do not dereference the graph
after run returns if it retired. This affects memory-gate evidence, not the
current static allocation bound; surviving-graph accounting is correct.

**Resolved: unused bounded-program OOM no longer rejects generic graphs.**
`prepare_bounded` allocates all clones into temporary storage, frees earlier
clones on failure, and publishes programs/gates/bytes only after all allocations
succeed. It clones immutable decoded programs without fetching, relocates branch
targets, then copies fallthrough gates after every gate is initialized. Generic
programs remain unchanged. Inline bounded gates remain by parent agreement.

`STOP_PREPARATION` occurs before pin, validator/service callbacks and guest
execution. Native.c falls back to ordinary assembly with original requested
steps; no chain/bounded work or timer charge is counted for the failed attempt.
The wrapper's intervening validation is callback-free, so borrowed ordinary
program lifetime is preserved; its normal guards still reject peer mutations.
No zero-progress allocation retry loop or helper replay was found.

The suspected fixed-cap coverage loss is **not present at current limits**.
Source-derived Apple arm64 LP64 sizes (not executed measurements):

| Maximum eight-member / 128-instruction graph | Before | Lazy, unprepared | Prepared |
| --- | ---: | ---: | ---: |
| Graph plus private programs | 13,992 B | 20,776 B | 27,624 B |
| Including 848 B cache owner | 14,840 B | 21,624 B | 28,472 B |

Derivation: `AGOperation=48`, `AGProgram=40`, each 16-instruction program
`40 + 17*48 = 856`; graph base grows from 7,144 to 13,928 B. Both totals remain
below 32,768 B, leaving 4,296 B with the current owner. Generic-only fixed
overhead remains 6,784 B, but optional program allocation/decode work is removed.
The new static assertion covers maximum raw graph bytes; owner-inclusive bounds
still follow from these current layouts. Allocator overhead is outside counters.

## Completed Runtime Assessment

No P0/P1 safety defect found in the reviewed ownership contract. Static checks:

- `bounded_snapshot` excludes a provisional zero-retirement visit, but includes
  first-instruction fault/unsupported visits and restores the prior last member.
  `bounded_service` charges cumulative steps minus already-accounted steps.
- `gadget_arm64.S:890-900` materializes the prefix before calling
  `ag_bounded_before_helper`; callee-saved resident registers preserve execution
  state. Veto executes no access. Success permits exactly one terminal helper;
  final settlement charges success by one instruction or a fault by zero.
- `ag_service_chain_run_bounded` captures executor status before final service and
  preserves terminal helper/fault/unsupported/halted results over final action
  or proof failures. A pre-helper veto survives final CONTINUE with valid proof;
  a new final proof failure/non-CONTINUE action may supersede its reason without
  resuming execution. No helper retry/resume path was found. `Lcode_commit1` deliberately
  bypasses veto after bytes changed and completes publication/writeback first.
- `gadget_arm64.S:819-867` polls events, global guards and every member's
  serial/local/shared-page tokens before admitting another suffix. Shared tokens
  use acquire loads. Whole-block admission plus terminal branches/sentinel gates
  bounds visits; cumulative instruction and visit budgets cannot be renewed.
  Existing instruction-retirement global guards remain in place.
- Graph/program storage stays pinned through final settlement/validation;
  retirement defers reclamation. Cache wrapper releases its active state only
  after return, and Native.c does not reuse borrowed decoded members afterward.
  CPU/RAM/cache/token lifetime still requires owner quiescence, not graph pinning.

Reviewed SHA-256: `service_chain.c`
`f1cc537d79657fcdb3bff9f96b2bf8e693f4d1ef69c31fb7973e64fdba282df2`;
`gadget_arm64.S`
`c884e89cc40ec89d7e0e9799358b16561761e481fee2899edf735eb6d299bcd9`;
`ARM64VizBlockCache.c`
`7bcf4c81fd7440c3f8d914939a0d06e9b06b2dcd9b3efd714c7d9883fee8f5dd`;
`ARM64VizNative.c`
`db53d1bda88aac6f2efe7bfcceda692e333f8f2e96f6968eb04ec4415550c9c2`.
New edits require a delta review. No tests, builds or timing work ran here.

## Reviewed Baseline

Source anchors below are function names, not moving line numbers. Native files
are under `Sources/ARM64VizNative/`; Swift files under `Sources/ARM64VizCore/`.

| Boundary | Observed behavior and implication |
| --- | --- |
| `Assembly/service_chain.c`: `service_boundary`, `ag_service_chain_run` | Generic callback runs initially and after each attempted visit; whole-graph validation brackets continuation. Keep this public contract unchanged. Add a distinct production-only policy. |
| `ARM64VizNative.c`: `avz_native_service_assembly_chain` | Charges `retired_delta` through `advance_time`; computes instruction-clock timer allowance. No wall-clock deadline or live event provider here. |
| `ARM64VizNative.c`: checkpointed chain implementation | Passes remaining step/visit/checkpoint budgets; `AGServiceLimits.events` is unset. Subtracts `timer_accounted_steps` before outer time charge; discards borrowed root after graph return. |
| `ARM64VizGuestMemory.c`: `avz_native_memory_fast_path_advance_time` | Catches up shared TLBI even for delta zero. Host clock refreshes only once accumulated charged instructions reach 1,024; otherwise instruction time advances by unsigned multiplication/addition. |
| `EmulatorBackend.swift`: `NativeChainCheckpointContext.checkpoint` | Owns stop requests, live host-preemption generation, wall deadline, live interrupt-controller query, fault/context-change exit. Next deadline threshold advances by 4,096 steps, but is checked only at a checkpoint. |
| Swift native burst initialization; `VirtualMachine.swift`: `HostPreemptionSignal` | Native `pending_irq` is an entry snapshot, not an atomic live IRQ source. Host preemption is a locked generation/provider, not the service API's atomic event flag. |

## Parent Integration Assessment

Read after notification: `avz_native_service_assembly_bounded`, Native.c result
normalization, bounded service C implementation and cache wrapper. **No blocking
issue identified in the callback/normalization logic under this ownership
contract; promotion still requires the gates below.**

- Initial generic `advance_time(0)` handles pending IRQ/due instruction timers
  and TLBI. Host-mode allowance is then `1024 - pending`; after the generic call
  `pending < 1024`, so the defensive `: 1` branch is normally unreachable. Final
  charge reaches the refresh threshold before returning a fresh allowance.
  Initial delta zero does not promise a fresh host-clock read.
- `STOP_ALLOWANCE + CONTINUE` normalization to outer `MAX_STEPS` is correct for
  this callback's positive host-refresh quantum: the run is fully settled and
  the outer loop reselects with reduced checkpoint budgets. A refreshed timer
  IRQ returns `AG_SERVICE_IRQ`, stays yielded, and forces a checkpoint. The
  production callback never deliberately returns zero allowance with CONTINUE;
  keep that assumption explicit if future policies are added.
- No native event pointer is wired. Live external IRQ/preemption/deadline checks
  remain at the original Swift checkpoints, not at each 1,024-step refresh.
  Preserving both checkpoint step and visit budgets is sufficient for the
  existing observation contract; immediate asynchronous notification is neither
  required by this integration nor claimed. Instruction-clock mode has no added
  fixed service quantum beyond timer and outer checkpoint/invocation bounds.

## Required Execution Contract

1. **Keep independent bounds.** Every visit, including self-loops and interior
   suffixes, remains capped by its remaining decoded length (at most 16).
   Every cheap gate consumes exact retired steps and visits. Effective allowance
   is the minimum of remaining invocation steps, checkpoint steps, native service
   quantum, and applicable timer/host-refresh allowance. Also stop at invocation
   and checkpoint visit limits. Zero is stop/invalid, never unlimited. Use
   subtraction after range checks; never underflow, replenish a consumed allowance,
   or hide visits by following an internal edge. Pre-entry rejection is zero
   visits; an admitted first-instruction fault is one visit and zero retirement.

2. **Settle retirement exactly once.** Track uncharged retirement separately from
   cumulative architectural steps. Full service charges that delta through the
   authoritative native `advance_time`, then clears the debt. Every exit,
   including outside graph, event, proof mismatch, budget exhaustion, helper,
   fault and zero-progress terminal exit, settles outstanding debt before returning.
   `timer_accounted_steps` must equal the actual sum charged and must not exceed
   architectural steps. Native.c charges only the nonnegative remainder. Do not
   count Swift's extra fault-attempt accounting as retired/timer instructions.

3. **Instruction-clock timers.** After settlement, with `PSTATE.I` clear, stop
   immediately for `pending_irq` or either asserted timer. A timer contributes
   only when `(CTL & 3) == 1`; both physical and virtual compares matter. For
   `CVAL > counter` and `cycles > 0`, cap at
   `distance / cycles + (distance % cycles != 0)`. At that retirement boundary,
   settle and check before another instruction. Already-due timers require zero
   instructions. With zero cycles, still check already-due timers/pending IRQ;
   do not divide or invent ticking. With IRQ masked, suppress IRQ delivery/timer
   caps, not time accounting, proof checks, events or checkpoints. Preserve
   unsigned counter arithmetic; near-wrap cases must fail closed to a smaller
   service window if an allowance proof cannot cover the wrap.

4. **Host-clock refresh.** Do not convert remaining wall time to guest steps using
   throughput estimates or `timer_cycles_per_instruction`. Bound the next charge
   by `1024 - counter_refresh_instructions` (service immediately if already due),
   including deferred retirement in the calculation. Refresh then re-evaluate
   both timers before continuing. `advance_time(0)` does not force a live clock
   sample, and an invocation-local counter must not discard the persistent refresh
   remainder. Preserve this existing instruction-based polling bound at minimum;
   it is not a hard elapsed-time latency guarantee after host descheduling.
   A stronger elapsed deadline requires an actual monotonic clock check with
   explicit units/anchor conversion, not a claim based on the step quantum.

5. **Events and wall deadlines.** Never extend the outer checkpoint step or block
   interval to amortize service. Existing Swift limits remain authoritative
   (65,536-step allowance ceiling, configured block interval; VM default 1,024
   blocks, mobile configuration can be 4,096). The 4,096-step deadline threshold
   is not itself an execution cap. Without new native plumbing, live device IRQ,
   host preemption and wall deadline observation remain checkpoint-only; state
   this limitation, and retain the same checkpoints. If a native event source is
   added, publish atomically, acquire-poll before entry/each successor gate, never
   acknowledge it in the graph, and exit to the owner. A generation requires
   comparison with a captured generation; testing nonzero would permanently stop
   after the first signal. Do not cast the Swift locked field or `pending_irq`
   snapshot to an atomic pointer. Deadline/event exits must force a host checkpoint
   and fresh selection, even with zero progress, not be normalized to an ordinary
   budget continuation. No Swift/device checkpoint may run and resume a pinned
   invocation. IRQ masking must not mask host stop/preemption events.

6. **Helpers and precedence.** Slow memory and post-store commit helpers remain
   terminal, including successful helpers at the final step. Before a slow helper
   performs any access, settle debt from earlier cheap visits and its local prefix;
   service may veto the unexecuted instruction. Final service settles only the
   remaining retirement. An already-performed inline store must finish publication
   and writeback without veto or replay. Successful helpers
   retire once and preserve completed PC/writeback/exclusive effects. Failed
   instructions do not retire or commit success-only register/writeback effects;
   retain partial memory effects and fault metadata. Never replay a helper/MMIO
   access through fallback. Preserve executor fault/unsupported/halted/helper
   revalidation over coincident IRQ, event, deadline or checkpoint stops; a service
   action must not erase the architectural result. After ordinary completion,
   proof failure prohibits continuation regardless of any service decision.

## Invalidation And Lifetime

- Preserve instruction-level `VALIDATE` guards in `gadget_arm64.S`, including
  shared code/translation epochs, and acquire-load **every captured member page
  generation** at cheap successor gates. Owner serial/local generation checks
  remain ordinary owner-only reads. A cached successful full validation is not
  permission to omit page checks until the next full service.
- Publication order matters: `note_write`, `note_device_write`, DMA completion
  and fast stores publish page generations before the shared code epoch. During
  that window the global epoch can match while a member page is stale. Reject
  changed pages even if no global epoch changed. Conversely, a token check is not
  a writer lock: do not claim detection before publication or zero stale
  instructions under unsynchronized writes. Preserve the existing guard timing;
  strengthening writer synchronization is a separate change.
- Before selection/capture, synchronize shared translations. A changed translation
  epoch stops the run, including register-only paths; full settlement catches up
  the journal (including overflow-to-all invalidation) and can retire the graph.
  Do not refresh a captured epoch to bless old decoded code or stale memory views.
  Revalidate after service; retain a prepared memory view only if its binding and
  captured epochs are still valid. Fresh invocation prepares a fresh view. Preserve
  pending fault state during catch-up/settlement.
- Full admission/reuse still proves exact resident serial, whole original block,
  one virtual/physical code page, enrollment/refcount, token addresses/values,
  physical mapping, reset/translation/context and RAM/fast-path binding. Keep
  semantic candidates and system/checkpoint barriers in C. No speculative decode,
  graph rebuild or arbitrary owner callback on the cheap gate. Owner-only immutable
  metadata may be amortized only while no callback can mutate it; any helper exits.
- Retire before eviction, reset, mapping/translator replacement, untracking or
  serial/token recycling. Pinning protects private programs, not the RAM, token
  arrays or cache owner. Keep all dependencies live until return; defer reclamation,
  forbid recursive execution/replacement while active, and quiesce owners before
  destruction or generation reuse/wrap. Preserve one graph/vCPU, eight members,
  128 instructions and 32 KiB including ownership metadata. Never reuse borrowed
  decoded pointers across a checkpoint or released pin.

## Promotion Gates And Deferred Protocol

Static review is complete with the P2 finding above. Execution/performance gates
remain unverified by this reviewer; the parent owns acceptance of reported runs.

- **Static integration review:** verify every continuation/exit against this
  contract, unchanged generic callback semantics, disabled/stub builds, outer
  status normalization and fresh selection. Record the actual maximum service
  step/visit windows and which events remain checkpoint-only.
- **Deterministic correctness, later:** cover exact/partial/self/suffix budgets;
  both timers before/at/after expiry, masked/due/zero-cycle/wrap cases; host refresh
  remainder 0/1023/1024 and short repeated runs; initial/late events and preemption;
  fault/helper after several deferred visits, partial pair-store and coincident
  IRQ/deadline; page-only publication before global epoch; peer TLBI scopes/journal
  overflow; active retirement/remap/token reuse. Compare CPU, memory, faults,
  visits and exact time accounting with the generic service reference. Assert
  multiple cheap visits per full service so enabled-but-unused cannot pass.
- **Validation, later and serialized:** optimized native service/cache/production
  and assembly regressions, Swift coverage, compatible UBSan/ASan, Release build,
  then authorized functional boot/unlock/Settings/Home. Retain all failures;
  handwritten assembly accesses are not made ASan-instrumented by testing C.
- **Performance, only after implementation and validation:** parent schedules a
  frozen, matched cohort using `phase7-benchmark-protocol.md`. Compare same-binary
  ordinary assembly/C composition, generic every-visit chaining, and bounded
  chaining with explicit mutually exclusive flags and actual-work counters; retain
  established C control and separate frozen pre-change ordinary-entry regression
  check. Keep seed, toolchain, CPU count, instrumentation and workload fixed.
  Separate attribution from clean timing. No timing during agents' builds/tests,
  profiling or other cohorts; record uncontrolled VM/thermal contention.
- **Promotion decision:** predeclare latency/regression and memory budgets;
  retain every attempt and report paired distributions, failures and tails, not
  only throughput. Require nonzero bounded coverage, fewer full service calls,
  exact accounting, unchanged responsiveness bounds, no stale code/lost input/
  corruption, bounded cache/RSS growth and repeated semantic UI completion.
  Synthetic wins cannot replace whole-VM gates; Simulator cannot establish
  physical-device gains. Keep defaults unchanged until the parent has reviewed
  the completed code and all required evidence passes.
