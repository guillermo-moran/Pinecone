# Phase 7 Production Assembly Chaining

Status: bounded integration and functional smoke complete; performance gate
FAILED. Chaining remains disabled by default. No Phosh speedup is claimed.

Follow-through: `phase7-boundary-cost-results.md` records sampled attribution,
reduced validation overhead, translator-remap correctness, deterministic
contention testing, and working LLVM ASan validation. The original results below
are historical and retained; the optimized candidate is still not promoted.

## Scope

`PINECONE_ASSEMBLY_EXECUTOR=1` selects assembly eligibility as before.
`PINECONE_ASSEMBLY_CHAINING=1` separately opts into the checkpointed native
fast-memory graph adapter. Both are required. Ordinary assembly, established C,
and non-checkpointed APIs remain independently usable. Guest images, graphics,
memory sizing, CPU count, and instruction support are not changed here.

The adapter captures selection epochs before choosing code, gathers only
resident observed successors, and holds at most one graph per vCPU. Graphs
contain at most eight blocks/128 instructions and 32 KiB including ownership
metadata. Each member must occupy one virtual and one physical code page.
Copies have private gates; FIFO programs are not patched. Cache entry eviction,
clear, invalidation, and binding changes retire dependent graphs before their
code tracking or serial identity can be reused. Active graphs are reclaimed
only after returning from their pinned invocation. Cache/RAM destruction still
requires stopped owners.

One assembly entry can service multiple visits without repeatedly saving and
restoring the full host ABI frame. A normal-ABI native callback charges each
visit's retired delta, catches up shared TLBI, and checks IRQ/timer state. Guest
state is materialized for service, and the graph is revalidated before another
visit. This does not keep all guest registers in host registers or eliminate
all C calls. Each suffix visit remains bounded by its decoded length, global
step/visit budgets, and host-checkpoint budgets. Memory helpers terminate the
chain; their faults/effects are not replayed. The outer scheduler charges only
retirement not already charged by native service.

## C Superblock Selection

The initial strict C-superblock-first integration could not exercise chaining:
C composition already consumed observed self-loops and successor traces. The
opt-in adapter therefore replaces a C superblock only when the graph covers
every member's exact resident identity. Graph admission excludes both semantic
candidate arrays and system/checkpoint barriers. Mixed traces and semantic C
accelerators retain their existing execution path. Ordinary assembly with
chaining disabled retains C-superblock precedence.

## Verification And Measurement Contract

Run focused native service/cache/production tests in optimized and UBSan modes,
the existing assembly runtime/dispatch regressions, all Swift tests, and a
Release Simulator build. The functional sequence remains fresh boot, rendered
lock screen, tap unlock, Settings content, and return Home with zero Swift
fallback. Preserve all failures rather than substituting a later success.

The benchmark harness now selects `assembly-chain` separately, explicitly sets
all executor flags, and requires chain counters so an enabled-but-unused path
cannot count as an improvement. Compare same-build assembly/assembly-chain and
established C under identical seed/instrumentation conditions. The saved
pre-change app at `/tmp/pinecone-phase7-pre-service-chain.app` has executable
SHA-256 `3a3d57a1874d5db4f05c5f353132f3b92ed21e7f09cee05112d40d429bdf32cd`;
use it separately to check ordinary-entry code-generation regressions.

Do not run Simulator timing cohorts during compilation, tests, profiling, or another VM.
Permission to pause the user's other VM has been requested; absent permission,
functional testing can proceed but no isolated Simulator cohort is claimed.
A separate synthetic thread-CPU screening may run after builds/tests and the
disposable VM stop, with the user's VM left running and that contention recorded.
Its six alternating same-binary pairs compare ordinary assembly/C composition
with opt-in chaining for a fixed cached loop, checking architectural results
outside timing. It is a cost screen only, not an isolated benchmark or a Phosh
interaction measurement; it cannot justify promotion.
Promotion still requires the roadmap's repeated boot/interaction, memory, and
correctness gates, plus separate authorized physical-device validation.

## Results

The same-build `-O3` native cost screen compared a warm two-member cached loop
at four block lengths. Both modes prewarm the same decoded/program members;
ordinary mode uses existing C superblocks, while the candidate uses the new
resident-entry graph. Each cell is the median of six alternating samples, each
retiring 524,288 instructions. State/counter comparisons are outside timing.

| Instructions per block | Ordinary CPU ns/instruction | Chaining CPU ns/instruction | Chaining / ordinary |
| ---: | ---: | ---: | ---: |
| 2 | 5.082 | 31.174 | 6.13x |
| 4 | 4.026 | 15.838 | 3.93x |
| 8 | 3.508 | 9.563 | 2.73x |
| 16 | 4.972 | 6.205 | 1.25x |

This is a failed cost screen, not a measured whole-VM regression factor. The
user's original VM remained active (about 20% CPU at the preceding observation);
the disposable VM was stopped, and builds/tests/agent work had finished before
timing. Frequency/thermal state was uncontrolled. No clean Simulator cohort
or interaction distribution was run. The earlier two-instruction-only `-O2`
and `-O3` screens are retained and also show regression. Two initial density
fixtures aborted because successor assembly programs were not prewarmed;
their failures are retained, not included as performance samples. The final
fixture explicitly prewarms every member equally in both modes.

The observed cost decreases with larger visits, consistent with high boundary
overhead. The candidate performs whole-graph proof validation and native
service for every visit, whereas established C superblocks amortize dispatch
and service. These measurements do not separately attribute the cost of each
check. Saving an assembly entry/exit alone does not overcome that overhead.

Next performance work must reduce boundary overhead, not increase cache size:
measure validation versus timer/translation service separately, then design a
production-only cheap boundary path that retains equivalent deadlines and
invalidation checks. Generic service callbacks cannot simply be skipped. Keep
C superblocks authoritative until a new candidate wins matched workloads.

## Verification

- 676 Swift tests pass, including chained self-loops, changing budgets, code
  replacement, independent opt-out, and mixed C execution.
  An intervening full rerun failed two assertions in the parallel exclusive
  spinlock test: neither conflicts nor nonzero lock reads were observed. Both
  workers halted with the correct shared counter and successful-write count.
  The focused rerun and a subsequent complete 676-test run passed. This is
  consistent with scheduling-dependent coverage, not proof that contention
  occurred in the failed run; its log is retained and the fixture still needs
  deterministic contention orchestration. No assertion was weakened.
- Native service/cache/production suites pass optimized and UBSan checks.
  Coverage includes two-owner code/TLBI publication and journal overflow,
  pinned retirement/serial reuse, suffix visits, exact accounting, terminal
  helpers, fault precedence, and semantic C preservation.
- Testing found and fixed two integration issues: instruction-clock timer
  allowance needed overflow-safe ceiling division; pending shared translations
  needed synchronization before selecting code/capturing proofs.
- Existing assembly dispatcher optimized and runtime UBSan checks pass.
- 64 benchmark-harness tests pass; chain-enabled-but-unused runs are rejected.
- ASan is BLOCKED, not passed. Both the production harness and a minimal
  offsets-generator binary hang before `main` during ASan initialization.
  Samples show shadow-memory setup reentering initialization through dyld malloc
  and waiting on `StaticSpinMutex`. Both timed out with exit 142. A compatible
  sanitizer runtime is still needed; no memory-safety claim substitutes for it.
- Release Simulator build succeeds. Executable SHA-256:
  `4f4238c165ed84930adb96b20c47745fd84bf041dd235954c06baa4b8a036a7b`.
- Disposable Simulator `C20024A2-E866-468D-BDC6-C44E6F01E0A3` booted to the
  rendered lock screen with chaining enabled on both vCPUs. One tap unlocked,
  Home rendered, Settings eventually displayed its Network controls, and Home
  worked afterward. The badge remained at zero fallback and both-vCPU recorded
  milestones had zero Swift fallback. Settings' header was not visible in the
  sampled frame, also observed in the preceding build's smoke; this is not a
  full layout correctness sign-off.
- Guest readiness was 101.575 seconds and the Settings surface milestone was
  about 49.4 seconds after launch request. These are single diagnostic
  observations during other test/VM activity, not comparable speedup evidence
  or proof of complete Settings rendering at that exact milestone.
- After screening, the disposable app was relaunched with assembly enabled and
  `PINECONE_ASSEMBLY_CHAINING=0`. Both vCPUs reported zero chain runs/steps; the
  rendered lock screen unlocked with one tap and Home rendered with zero Swift
  fallback. The user's original app/disk/executor and
  physical device were not changed. No commits or guest-image edits were made.

Raw logs, rejected fixture outputs, ASan samples, source hashes, Simulator UART,
performance telemetry, and the Home screenshot are retained under
`experiments/phase3/results/phase7-production-chaining/`.
