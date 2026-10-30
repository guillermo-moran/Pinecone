# Opt-In Assembly VM Integration

## Scope

The precompiled Darwin ARM64 executor is linked into `ARM64VizNative` and the
iOS app. Its canonical sources are in `Sources/ARM64VizNative/Assembly`.
The experiment harness includes those sources rather than maintaining a fork.
Generated offsets are checked by C static assertions and regenerated/compared
by both regression scripts. There is no JIT or guest-to-host executable mapping.

`PINECONE_ASSEMBLY_EXECUTOR=1` enables it on each software vCPU. Absent/zero is
off. Selecting it via the environment disables the older threaded-C experiment;
unsupported assembly blocks continue through the established native C executor.
This does not enable Swift instruction fallback. The C setter and Swift setter
must only be used while the owning vCPU is stopped, like the existing switches.

Blocks with existing native semantic candidates stay in C, including mapped
trace candidates. This preserves PLT, string and bulk-operation accelerators;
assembly support alone is not a reason to displace an established fast path.

The native block cache owns at most 256 assembly snapshots per vCPU in a FIFO.
Negative eligibility is retained on decoded entries and consumes no snapshot
slot. Capability is calculated during preparation, without a second decode.
Cache eviction, code invalidation and reset
retire snapshots. An executing snapshot remains pinned until its call returns,
including callback-driven eviction. Register-only blocks work without a native
memory context; memory blocks require the authoritative native fast path.

Proof epochs are captured before validating code. Assembly observes local/shared
code epochs and memory translation epochs. Memory helper exits remain terminal;
completed stores are never replayed. Timer/checkpoint allowances still bound
each invocation to at most one decoded block's instruction count. Backward
branches cannot escape that allowance. Existing native C superblocks remain
available; the offline multi-block assembly chain is not enabled in the VM yet.

Primary-vCPU counters are available as `assemblyExecutorPrimary` in the existing
opt-in performance JSON: enabled, blocks, steps, boundaries and faults. These
counts distinguish real assembly use from a build that merely contains symbols.

## Validation

- Complete Swift suite: 672 tests pass, including MMU-enabled mixed assembly/C
  execution, exact budgets, native-only policy and code-write invalidation.
- Optimized and UBSan production-adapter regression suites pass: 3,136
  differential scenarios, 128 cache replacements, opt-out, hot RAM, callbacks,
  300-program eviction, remapping, self-modifying code, shared code publication,
  all shared TLBI scopes, precise faults, timer deadlines and checkpoint resume.
- Offline assembly suite passes against the same canonical source, including
  ABI, conditional flags, scalar addressing/pairs, branches and chain lifetimes.
- AddressSanitizer is blocked on this host: the process deadlocks before `main`
  in `AsanInitInternal` / `InitializeShadowMemory`, recursively entering the
  sanitizer allocator through dyld enumeration. A one-second `sample` captured
  that stack in `/tmp/pinecone-assembly-asan-sample.txt`; the process was stopped.
  This is not an ASan pass and does not replace a later supported-host run.
- The initial direct-mapped adapter reached shell, lock screen and ordinary
  unlock/Home with zero Swift fallback, but readiness took 209.204 seconds.
  A startup stack sample exposed repeated preparation, allocation/free and a
  redundant decode for capability checking. That design was replaced by the
  FIFO/entry-lifetime eligibility scheme above. The failed performance trial
  is retained as `/tmp/pinecone-assembly-first-trial.json`; it is not a speedup.
- The cache correction passes UBSan, including an additional 600-negative-entry
  regression that keeps an existing hot program resident. Its Simulator trial
  reached readiness in 168.315 seconds and unlocked normally, with zero Swift
  fallback. `/tmp/pinecone-assembly-fifo-trial.json` retains this result. A later
  sample still contains positive-program preparation churn. These are single
  diagnostic runs on a preserved filesystem, not matched benchmark cohorts.
- Review also found that supported assembly blocks could displace native
  semantic fast paths. The final adapter preserves those candidates in C and
  adds a regression asserting the PLT accelerator still retires all four
  instructions as one native fast-path hit. Optimized/UBSan adapter suites and
  all 672 Swift tests pass after this correction.

## Final Simulator Trial

Release binary SHA-256:
`998a30a7bb62d850257a8a2aa2346a818c9a8884b39c2fdc51963b606dc11fe4`.

Simulator: `541E22EE-C52B-4478-A041-56FEDC23ACFF`, iOS 26.2. The existing guest
disk was preserved, with the previous VM stopped before each app update.
Assembly enabled, threaded-C experiment and its memory flag disabled, two
parallel vCPUs, expensive hot-PC profiling disabled. Performance JSON and UART
logging enabled. No compilation or regression suite ran during these boots;
each diagnostic run included a one-second host stack sample.

| Adapter iteration | Shell (s) | Guest-reported Phosh readiness (s) |
| --- | ---: | ---: |
| Initial direct-mapped cache | 5.994 | 209.204 |
| FIFO and retained eligibility | 4.753 | 168.315 |
| Native fast-path candidates preserved | 3.836 | 98.281 |

These are development smoke runs, **not a matched comparison against established
C**. Filesystem/service state and scheduling differed. Do not report the table
as a demonstrated production speedup or promote the path from these samples.
`firstVisibleFrame` is not used as evidence of a rendered lock screen.

At final readiness, the primary vCPU had executed 390,092,331 assembly steps
across 138,005,943 entries. Primary native total was 1,059,053,430; secondary
native total was 1,686,937,830. Both Swift fallback counts were zero, and the
older threaded prototype executed zero steps. Assembly faults in telemetry
include ordinary guest memory/translation exceptions, not unsupported opcodes.

The final build visibly reached the lock screen, accepted ordinary tap-to-unlock,
showed Home, launched/rendered Settings with legible text and icons, and returned
Home through the guest navigation control. The final visible native count was
2,912,908,705 with fallback zero. Guest UART also logged elogind cgroup
mount/daemon warnings during application startup; Settings still rendered.
No guest service configuration was changed to suppress those warnings. This
test does not establish that every Settings panel or Firefox interaction works.

Raw diagnostics, earlier trials, stack samples and regression logs are archived
locally under `experiments/phase3/results/phase7-integration/` (ignored artifacts).
The final startup sample still includes preparation/cache and entry overhead;
removing the redundant capability decode did not eliminate all preparation.

This is an integration candidate, not an end-to-end speedup claim or promotion.
The first adapter deliberately preserves service boundaries. Matched alternating
boot/interaction cohorts and cache hit/coverage attribution must precede a
default switch. Further work includes production assembly-chain integration,
reducing cache preparation churn, and measured hot-family expansion.
