# Phase 7 Cache Integration

Status: cache fix, owner-side publication and screening comparison complete,
2026-10-29. Assembly failed the screening gate and is not promoted. The cache
fix has a correctness/retention regression test, not a measured before/after
end-to-end speedup.

## Measurement Contract

Use the newly created disposable iPhone 17 / iOS 26.2 Simulator
`C20024A2-E866-468D-BDC6-C44E6F01E0A3`. Do not overwrite the user's working
Simulator disk. Preserve its live VM by temporarily suspending its identified
host process during measurements, then resume it afterward.

Initial screen: two alternating pairs, established C then assembly, with the
same Release executable and restored bundled rootfs for every attempt. Both
use two parallel vCPUs, zero Swift fallback, identical tracing, no automatic
unlock, and a 600-second observer deadline plus 15-second post-ready observation.
No builds, correctness tests or process sampling run during clean timing.
File caches are not flushed. This is a screening comparison, not Phase 7's
five-pair/20-interaction promotion cohort or a before/after cache-policy test.

If both assembly attempts are more than 10% slower than their paired C controls,
do not promote or expand the cohort merely to find a favorable run. Attribute
the remaining cost in a separately instrumented build instead. Any fallback,
crash, missing readiness or visible regression also stops promotion. Otherwise
the full roadmap gates are still required; two pairs cannot establish a win.

Record hashes, raw logs, failures, wall time, app CPU seconds and sampled RSS.
Guest readiness is a milestone, not proof of complete rendering. Independently
verify lock screen, ordinary tap unlock, Home, Settings and return Home.

## Diagnostic Publication

Detailed cache collection requires `AVZ_ASSEMBLY_CACHE_DIAGNOSTICS=1` at build
time and `PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS=1` (counts) or `time` (also time
preparation) at runtime. Default builds compile out hot-path instrumentation.
Each backend begins its own window before execution and publishes at most once
per second after a completed execution slice. A lock protects the published
copy, not guest execution or cache operations. UI consumers never traverse a
running cache. Snapshots carry host publication timestamps and can be stale
while a vCPU is idle; independently sampled vCPUs are not a simultaneous view.

Reports include `assemblyCachePrimary`, `assemblyCacheSecondaryByVCPU`, and
`assemblyExecutorSecondaryByVCPU`. Default-disabled reports retain their initial
disabled snapshot rather than sampling a live cache. Footprint gauges exclude
allocator overhead and retired-but-pinned programs, as documented in the C API.
Preparation timing excludes cache lookup, validation, copying raw words and
execution. Diagnostic runs must not be mixed with clean timing results.

## Implemented Policy

Empty slots precede live programs in an owner-confined, circular slot-order
list. Retirement moves a slot to the free prefix; admission moves it to the
tail. Once full, replacement preserves admission FIFO, including after holes
are filled. Hits do not reorder entries. Selection, insertion and retirement
are O(1), with no full-capacity search on misses. The 256-program limit is
unchanged; slot-order metadata adds 1,024 bytes per vCPU cache. Existing active
pins, semantic exclusions, code and mapping invalidation remain intact.

The focused fixture previously evicted a program after 100 hits despite an
empty slot elsewhere. It now preserves that program and fills the hole without
re-preparation, then verifies the complete FIFO order after the cache fills.
The deliberately cyclic 257-program workload still thrashes a 256-program FIFO;
this patch does not claim to solve working-set capacity or admission policy.

## Clean Screening Results

Same executable SHA-256:
`7388d149e15ccc5b0457a094f1178b00c1d06dc2f4acf4c78fa1ad9349178ef2`.
Same seed SHA-256:
`9bb385f1df937c9101b28a03afbfc21055af70c8a1285bb7fd629a6acdbf643c`.
All four attempts completed with zero Swift fallback on both vCPUs.

| Attempt | Executor | Guest readiness (s) | App CPU seconds at observation | Sampled peak RSS (MiB) |
| --- | --- | ---: | ---: | ---: |
| 1 | Established C | 73.170 | 75.86 | 839.28 |
| 2 | Assembly | 118.087 | 108.35 | 724.61 |
| 3 | Established C | 73.184 | 72.48 | 679.17 |
| 4 | Assembly | 109.223 | 107.34 | 752.66 |

The two-run means are 73.177 seconds for C and 113.655 seconds for assembly:
assembly is 55.3% slower and uses 45.4% more observed app CPU time. Both pairs
exceed the predeclared 10% slowdown threshold, so no promotion cohort was
attempted. This small screen rejects this candidate; it is not a general claim
about assembly interpreters. RSS varies substantially and does not establish a
memory improvement. CPU samples include launch/observer overhead and exclude
Simulator services. No before-fix binary was compared, so these figures cannot
isolate the cache policy's performance effect.

The assembly candidate passed visible lock screen, ordinary tap unlock, Home,
rendered Settings network panel and return Home, with fallback zero. Settings
was slow and showed a splash/blank transition before rendering. This was an
untimed functional smoke check, not a latency cohort; separate native checks
ran during part of that smoke check, never during clean boot timing. Existing
elogind/cgroup setup errors remain visible in the archived log. No Firefox
interaction claim or physical-device test is made.

## Attribution Result

Separate instrumented executable SHA-256:
`5a93d19f7b1d541b9c5cf56e1e8ce5212d2b3d87b18c61a6bc4d1743b44964eb`.
It reached guest readiness at 137.098 seconds with zero Swift fallback. That
time is deliberately excluded from the clean comparison.

Owner-published snapshots observed at readiness:

| Counter | vCPU 0 | vCPU 1 |
| --- | ---: | ---: |
| Program preparations | 40,218,070 | 16,163,582 |
| Re-preparations within decoded-entry lifetime | 37,792,601 | 13,874,664 |
| Positive evictions | 39,909,842 | 15,875,190 |
| Evictions while a free slot exists | 0 | 0 |
| Accumulated preparation duration (s) | 6.281 | 2.511 |
| Currently owned programs | 256 | 256 |
| Currently owned program bytes | 63,664 | 69,232 |
| Cumulative requested program bytes | 10,476,959,056 | 4,141,032,800 |

Approximately 51.7M of 56.4M preparations repeat an admitted program in the
same decoded-entry lifetime. Cumulative requested bytes are allocation traffic,
not resident consumption or a leak. The sum of per-vCPU preparation durations
is about 8.8 seconds, excludes freeing/validation/raw-word copying, and may
overlap between vCPUs; do not subtract it from wall time as an exclusive share.
Clock calls and counters perturb this attribution run.

Assembly execution totals at report time average about 2.67 guest instructions
per entry. Cache request/hit counts include selection and execution lookups;
they are not independently retired-block counts. In particular, a second
lookup on the same execution can mark an eviction as reused. Snapshots are
independently timestamped and may precede the milestone by approximately one
publication interval, rather than describing an exact simultaneous boundary.

Next experiments should measure bounded hot-program admission/retention and
decoded-operand reuse, while the separate chaining work adds native service and
lifetime contracts. Repeated preparation is real, but its measured inner cost
alone cannot explain the complete slowdown. Do not blindly enlarge the cache,
remove invalidation checks, or enable the offline long-chain runner in the VM.

## Verification And Artifacts

- 673 Swift tests pass in the final instrumented build; the default build also
  passed 673 tests. The three focused bridge tests pass with instrumentation
  compiled in, including window reset/disable without clearing residency.
- Cache fixtures pass optimized and UBSan, diagnostics off/on, with free-slot,
  complete FIFO order, repeated invalidation/clear, pinned retirement, feature
  guards and default-build clock-symbol checks.
- Native assembly runtime/continuation regressions pass optimized and UBSan.
- 52 benchmark harness tests pass. No ASan success is claimed; the previously
  documented host-runtime startup blocker was not retried.

Raw manifests, source identities, reports, screenshots and build/test logs are
retained locally under `experiments/phase3/results/phase7-cache-integration/`
(ignored artifacts). The initial screen and attribution are separate folders.

Restoring the clean app after profiling initially failed due to host disk
space. Only this task's disposable app/data and generated DerivedData were
removed; reinstall then succeeded and its executable hash was verified against
the clean manifest. The disposable app is left stopped. The user's working
Simulator app/disk were not replaced; its original process was resumed.
