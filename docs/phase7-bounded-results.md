# Phase 7 Deadline-Bounded Native Service

Status: implementation and native validation complete; Simulator timing screen
rejects promotion. Visual smoke completion is recorded below.

## Change

The new independently opt-in `PINECONE_ASSEMBLY_BOUNDED=1` policy keeps execution
inside assembly across resident graph edges. Both `PINECONE_ASSEMBLY_EXECUTOR=1`
and `PINECONE_ASSEMBLY_CHAINING=1` are also required. The old every-visit service
API remains available as a correctness and benchmark control. Ordinary C and
ordinary assembly selection are unchanged by default.

Initial native service establishes a bounded retirement allowance. Graph edges
check events, global guards, and every captured member's serial/page generation
without calling C. Registers remain in the existing CPU structure; this is not
full guest-register allocation into host registers. Full validation and timer
settlement occur at entry, exit, and before terminal slow-memory helpers.

- Preserve both remaining instruction and block checkpoint budgets.
- Bound instruction-clock execution by the next enabled physical/virtual timer.
- Preserve the host-counter refresh remainder, with at most 1,024 retired
  instructions between existing host-clock refresh opportunities.
- Settle the retired prefix before device access; never replay partial stores.
- Preserve faults and completed helper effects over coincident service exits.
- Retain the graph pin through final settlement and validation.
- Keep instruction-level global guards and per-edge code-page guards.

Live host preemption, external device IRQ observation, and wall deadlines still
use the existing Swift checkpoints. This change does not add an atomic native
event provider or promise immediate asynchronous interrupt observation.

New `boundedRuns`, `boundedVisits`, and `boundedSteps` telemetry is a subset of
aggregate chain counters. The benchmark harness rejects enabled-but-unused
bounded mode and conflicting flags. Counts are owner-published observations,
not a transactionally consistent global VM snapshot.

## Validation

Initial integrated revision passed all 678 Swift tests, 66 benchmark-harness
tests, the ordinary assembly runtime matrix, and all 17 production native cases
under optimized, UBSan, and installed LLVM 22 ASan builds. The known Xcode 17
ASan pre-main timeout is retained as failed evidence rather than hidden.
Handwritten assembly itself is not ASan-instrumented.

The production cases include exact/partial budgets, pending and masked IRQs,
both timers, host refresh remainders, terminal MMIO and partial pair-store
faults, code/translation invalidation, independent opt-outs, and two-owner page
generation publication before the global code epoch changes. The bounded-only
fixture additionally checks suffix/indirect targets, unwinding, pin lifetime,
provisional visits, and amortized callback counts.

Independent review is in [the bounded contract](phase7-bounded-review.md).
Post-review preparation is transactional and lazy. Optional allocation failure
leaves the generic graph usable; the production dispatcher executes ordinary
native assembly without inventing bounded counts or retrying without progress.
Maximum graph/program storage is 20,776 bytes unprepared and 27,624 prepared;
including the 848-byte cache owner, the prepared maximum is 28,472 bytes, below
32 KiB. Allocator overhead is excluded. Inline bounded-gate storage remains
present in the generic graph. Peak-byte telemetry now samples before retirement,
including preparation followed by retirement during the same invocation.

After allocation changes, all 18 production cases passed normal/UBSan/LLVM ASan
and all 678 Swift tests passed again. The final peak-telemetry amendment passed
the 18-case normal/LLVM ASan matrix and cache ownership/disabled-build checks.
The focused bounded fixture passed normal, UBSan, and both disabled variants;
its eight allocation-failure cases verify rollback and retry. No pending test
or agent process was left running during timings.

## Measurement Protocol

Use the same Release binary, frozen quiescent disposable disk, matching kernel
and fingerprint, two parallel vCPUs, and identical host/guest tracing. Native
microbenchmarks compare ordinary execution, every-visit service, and bounded
service across four block lengths with six samples each. They are not Phosh
latency measurements.

The original user VM may be temporarily process-suspended only during timings,
with explicit user authorization and automatic resume on benchmark exit. Its
app and disk must not be replaced. Build/test work finishes before timings.
Host thermal state and file caches remain uncontrolled.

The Simulator screen compares two ordinary/bounded boot pairs, followed by a
single old-service control. Functional lock-screen, tap-unlock, Settings, and
return-Home checks are separate observations. This is a screening cohort, not
the full interaction-distribution or physical-device promotion gate. Preserve
every failed attempt. Do not substitute guest readiness for usable UI.

Raw evidence belongs in `experiments/phase3/results/phase7-bounded/`.

## Native Results

Same-binary medians, six samples per mode/block length, thread CPU nanoseconds
per retired guest instruction. Two resident blocks, 128 timed slices of 4,096
instructions per sample, 64 warmup instructions. Work and final state are checked.

| Instructions/block | Ordinary | Every-visit service | Bounded | Bounded/ordinary |
| --- | ---: | ---: | ---: | ---: |
| 2 | 5.036 | 21.120 | 4.890 | 0.971 |
| 4 | 4.108 | 12.032 | 3.662 | 0.891 |
| 8 | 3.501 | 7.828 | 3.169 | 0.905 |
| 16 | 4.988 | 5.237 | 2.884 | 0.578 |

The short-block every-visit penalty is substantially reduced. Relative to
ordinary execution, the 2-instruction result is near a tie; the other tested
lengths improve by roughly 9-42%. This does not establish Phosh speed, actual
guest graph coverage, cold preparation cost, or touch latency. The competing
VM was paused only during the command and verified resumed afterward.

## Simulator And Decision

Five successful readiness observations, in the predeclared order:

| Mode | Guest readiness (s) | App CPU at readiness observation (s) | Sampled maximum RSS (MiB) |
| --- | ---: | ---: | ---: |
| Ordinary, first | 74.092 | 71.16 | 809.9 |
| Bounded, first | 86.780 | 94.92 | 751.7 |
| Bounded, second | 97.205 | 111.59 | 785.2 |
| Ordinary, second | 88.626 | 83.72 | 768.2 |
| Every-visit service control | 105.331 | 102.64 | 760.8 |

Ordinary mean readiness is **81.359 s**, bounded **91.992 s**: bounded is
**13.1% slower**. Observed app CPU means are 77.44 versus 103.255 seconds:
**33.3% more CPU**. The two ordinary and two bounded attempts all execute about
2.77-2.80 billion native guest instructions at readiness; this is not explained
by a large difference in guest instruction counts. All five attempts retain
zero Swift fallback. These are two pairs, not a statistically conclusive latency
distribution; thermal state was uncontrolled and the ordinary repeat also slowed.

Bounded work at the readiness report is about 20.3-21.3 million instructions
combined across both vCPUs, below 1% of total native work. The owner-published
counts and readiness counters are not sampled atomically, so this is approximate
coverage, not an exact milestone percentage. The candidate makes 1.28-2.06 million
bounded invocations in those observations. Faster long-loop execution does not
address most Phosh work, and invocation/admission/validation overhead can offset
its savings. The latter is a hypothesis to profile, not a measured attribution.

The one every-visit control is slower in wall time than either bounded run,
but a single sample does not establish a reliable before/after UI improvement.
RSS samples do not show increased process RSS in this screen; they are not
physical footprint, true peaks, or a proof against allocation churn.

**Decision: keep bounded and service chaining off by default.** The implementation
is retained for controlled experiments; do not describe it as a delivered Phosh
responsiveness improvement. The original user VM was verified resumed after
both timing commands. No physical device was used.

Next work should measure graph admission/build/reuse costs and work density
before expanding coverage. Add a cheap profitability/admission gate if those
costs dominate, preserving C superblocks and semantic accelerators. More cache
capacity or relaxed invalidation checks are not justified by this result. The
full matched interaction distribution and physical-device gates remain open.

### Functional Smoke

On the disposable Simulator, the bounded build rendered the lock screen,
eventually reached Home after tap input, launched Settings' Network page, and
returned Home using the guest navigation button. Screenshots and the guest trace
are archived beside the timing cohort. The first tap did not visibly dismiss
the lock screen at the first observation; another tap was sent after confirmed
readiness. A package-app transition intervened before returning Home. This is
not a clean single-tap latency measurement and the first observation is retained,
not silently counted as success. Input delivery and subsequent rendering were
slow. The existing absent Settings header is still visible in the screenshot;
full text/layout sign-off remains open.

The trace records the Settings request at guest time approximately 238.4 s and
its first reported application surface at 307.8 s. That roughly 69-second gap
is a guest diagnostic interval, not a measured tap-to-usable-page latency.
The original VM was running again during this untimed functional check, so do
not compare it to the isolated boot cohort. The smoke report shows actual
bounded work and zero fallback. No unsupported instruction or VM crash was
observed. Ordinary assembly/C execution with chaining and bounded mode disabled
was restarted afterward; no user disk or physical device was replaced.
The restored app reached its readiness milestone and a visible lock screen;
telemetry confirmed `chainEnabled=0`, `boundedEnabled=0`, and zero graph work.
The original user process was finally rechecked in running/sleeping state, not
suspended.
