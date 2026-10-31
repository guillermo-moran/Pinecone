# Phosh Interaction Priority: Initial Attribution

Date: 2026-10-29. Initial capture followed by guest-library experiments below.

## Configuration And Scope

Disposable Simulator C20024A2-E866-468D-BDC6-C44E6F01E0A3, Pinecone PID 86169,
two parallel vCPUs, assembly enabled, service/bounded chaining disabled,
threaded prototype/memory disabled. Interaction tracing enabled; guest hot-PC
profiling disabled. Executable SHA-256:
`419b88e52af37e17ddfc797952c6ba51de6723c030e4e555e9b4441af0a2097b`.

Existing persistent disk, not a fresh install. Settings was a cold process
launch in this VM, not a cold filesystem/cache baseline. The other user VM
remained running. Host stack sampling ran for 20 seconds around unlock and
30 seconds around Settings, at a requested 2 ms interval. These are instrumented,
non-isolated diagnostic observations, not matched performance benchmarks.

Raw evidence: `experiments/graphics-responsiveness/2026-10-29-baseline/`.
Counter windows are before-unlock to after-unlock, then after-unlock to
after-settings. They include idle time and tool gaps; they are not exact
touch-to-response windows. Same-frame guest spans use new `(epoch, frameID)`
entries, not proximity-based touch attribution.

## Measurements

| Metric | Unlock interval | Settings interval |
| --- | ---: | ---: |
| Metal commands | 54 | 161 |
| Metal GPU execution, cumulative delta | 18.52 ms | 61.36 ms |
| Metal input/output copies, cumulative delta | 13.38 ms | 17.72 ms |
| Host C ineligible-operation execution, delta | 0.38 ms | 1.07 ms |
| Newly observed guest frames | 5 | 23 |
| Guest render-to-submit median / maximum | 266.90 / 557.06 ms | 37.03 / 281.49 ms |
| Guest render-to-submit CPU median / maximum | 235.98 / 541.06 ms | 18.20 / 178.83 ms |

Settings application-launch-requested and application-surface-presented host
milestones differ by **41.97 seconds**. This is a milestone interval, not a
measurement of complete usability or all Settings rendering. The host rolling
commit-to-present p95 after Settings was 26.57 ms; this is not an interval-only
percentile and cannot be compared as though it were one.

The Settings sample's leading active leaf symbols were the native decoded
executor (4578 observations), checkpointed chain execution (1586), code-current
validation (601), and instruction translation (492). Sleeping system threads
dominate raw sample counts. These counts are neither exclusive CPU percentages
nor attribution to a specific guest library. The 30-second sample also does
not cover the complete 41.97-second launch milestone interval.

## Conclusion And Next Change Gate

The measured host Metal/copy work cannot explain the multi-second application
startup or the long guest frame-production spans. Small operations handled in
host C are inexpensive here; counting them as slow guest software fallback
would lead to the wrong optimization. This capture does not establish which
guest function or scheduling dependency is responsible.

The immediate target is guest app/frame production: collect bounded guest-PC
attribution with process mappings during the slow launch and render intervals,
and distinguish runnable CPU work from waiting. Correlate with the existing
Phoc/Pixman submission stages. Choose one dominant measured function or wait
dependency to fix. Do not promote another executor variant based on these host
samples alone, and do not spend this iteration optimizing the already-small
host copy totals.

Acceptance remains matched unlock and cold/warm Settings interactions, visual
correctness, zero new input/render failures, and unchanged disk/build/flags.
Neither a boot instruction reduction nor synthetic throughput closes this gate.

## Visual Checks

A single lock-screen tap reached Home. Settings rendered its Network page;
the native instruction badge remained at zero fallback instructions. Screenshots
`unlocked.png` and `settings.png` preserve these observations. This is a basic
functional check, not pixel-perfect rendering or latency signoff. No runtime
code, app installation, disk reset, or physical-device change was made.

## Guest Function Attribution And Candidate Changes

Subsequent captures used the same app executable and executor configuration,
with hot-PC profiling enabled and the primary profile reset on touch. `/proc`
maps, matching library bytes, and musl debug symbols identify these paths:

- Phosh's GTK3 `blur_xspan` / `blur_rows` and buffer transpose loops dominate
  early launch samples. The matching library offsets include `0xb65fc`,
  `0xb65ec`, `0xb65e0`, and `0xb6604`. These are GTK Cairo icon-shadow raster
  loops, before Pixman submission, not a slow Metal kernel. The nearest exported
  symbol in a stripped disassembly is misleading; matching GTK 3.24.52 source
  establishes the blur implementation.
- The Settings process's musl `startup_sym_index_add_symbol` re-hashes exported
  names while constructing our private symbol index (`0x6b324` in r8). Later
  relocation work includes `gnu_hash` and `dl_strcmp` in `find_sym2` / private
  index lookup. Mesa/LLVM are mapped even with `GSK_RENDERER=cairo`: dependencies
  through GStreamer GL/EGL/Gallium mean a runtime 'disable GL' flag alone does
  not eliminate that loader work.

Hot-PC samples are bounded approximate heavy-hitter counts, not time samples or
exact percentages. The secondary profile remains cumulative across boot; ASLR
addresses must be matched to the relevant process. Kernel symbols in the local
build do not match this guest image and were not used for function attribution.

Changes:

1. Scope `-gtk-icon-shadow: none` to `.phosh-dropicon-shadow`, the splash and
   activity icon class. Keep icon content, text, spinner, and launch behavior.
   This removes two CPU blur radii, not all GTK styling or animations.
2. Reuse GNU hash-chain values when constructing musl's startup index; recover
   the overwritten low bit from the bucket index, retaining the normal name
   hash for ambiguous cases. Keep the full-hash r8 private index and selection
   rules. GNU lookup avoids a bytewise comparison for identical name pointers
   while retaining earlier duplicate and version checks.

Exploratory, non-isolated single Settings launch milestone intervals:

| Variant | Launch request to first app surface |
| --- | ---: |
| r8, original CSS, hot-PC profiling | 35.30 s |
| r8, scoped shadow removal, hot-PC profiling | 38.62 s |
| r9, shadow removal + hash reuse, hot-PC profiling | 36.83 s |

The blur and index-build hash hotspots disappear from the leading samples, but
these runs do **not** demonstrate an end-to-end speedup. Do not market them as
one. r10 adds identical-pointer lookup after the r9 profile exposed remaining
bytewise comparisons. Clean timing results follow separately.

## Correctness And Deployment Scope

- GTK 3.24.52 parsed the complete stylesheet without errors or warnings using
  `scripts/gtk-style-regression.c`.
- UBSan checks extracted production loader functions: 2,497,152 hash cases,
  ambiguous/invalid guards, identity, duplicate-name ordering, versions, hash
  collisions, and absent symbols.
- Both the isolated loader and exact signed r9/r10 package loaders pass the
  12-case GNU/SysV/both, PIE/non-PIE, preload/no-preload matrix covering symbol
  binding, relocations, versions, TLS, and runtime scopes.
- Graphical overlay dependency tests: 14 pass, including explicit candidate
  selection and rejection of unknown revisions. Shell syntax and diff whitespace
  checks pass. Cloned candidate ext4 images pass `e2fsck -fn`.

The signed r10 package is built. Rootfs staging keeps r8 by default and accepts
`PINECONE_MUSL_PACKAGE_VERSION=1.2.6-r10` for explicit candidate testing. Simulator
experiments replace the exact packaged loader and CSS on clones of a preserved
stopped disk, not on the original user's VM. These are diagnostic disks, not a
rebuilt release rootfs: their APK database still reports r8. The production
staging pipeline installs/registers the selected revision normally. No Swift, interpreter, or
Metal changes were made in this investigation; earlier dirty work is preserved.

## Unprofiled Comparison And Decision

Two vCPUs, same executable and flags, hot-PC profiling off, interaction trace on.
Each run restored the same preserved seed or its CSS/loader-only clone. Every
Settings test was the first process launch after boot; host filesystem caches
were not purged. The other Pinecone VM was paused with a 900-second automatic
resume watchdog. No physical device or original VM disk was modified.

| Run | Settings request to surface | Native instructions during interval |
| --- | ---: | ---: |
| A1: r8 / original CSS | 34.930 s | 1,634,212,671 |
| B1: r10 / scoped shadow removal | 33.817 s | 1,387,828,860 |
| B2: same candidate, seed restored | 32.225 s | 1,440,680,859 |
| A2: restored baseline, watchdog resumed other VM | 35.041 s | 1,689,126,602 |

A2 is **not** a matched isolated timing result: the watchdog resumed the other
VM before its endpoint. Preserve it as functional evidence, not a clean reverse
pair. A short GTK parser compile/test also overlapped B1 (builder call 0.41 s).
B2 had no overlapping builds/tests. These are screening runs, not a release
benchmark, p95 estimate, or proof of reduced host CPU/memory. Single endpoint
RSS samples varied substantially and do not establish a memory improvement.

The first pair improves the milestone interval by only 3.2%, while retiring
15.1% fewer guest instructions in that interval. The repeat candidate is faster
again, but there is only one clean baseline and the samples are small. This
does not meet the user's responsiveness goal; the loader remains opt-in rather
than silently becoming the new runtime default. The signed candidate, source
patches, and raw evidence remain available for further testing.

All four runs reached the lock screen, accepted a single unlock tap, and opened
Settings with zero interpreter fallback at the recorded milestones. Home was
also verified on both variants. Unlock showed an intermittent black transition;
no precise tap-to-usable-Home latency is claimed.

### Missing Settings Title Bar

B1 and B2 lacked the Settings title bar. A1 displayed it, but **A2 reproduces
the missing title bar on the unchanged r8/original-CSS baseline**. Thus it is not
exclusive to the loader candidate. Screenshots preserve B2 and A2. This remains
an unresolved visual defect, not a passed pixel-correctness gate.

The launcher patch creates a separate bottom-anchored top-layer navigation
surface, reserves `PINECONE_NAV_HEIGHT` (56 logical pixels), and adjusts Phosh's
usable height accordingly. It does not explicitly hide the Settings title bar.
A layout/configure, maximization/fullscreen, or clipping interaction is plausible
but unproven. The next causal check is the same runtime with the navigation
surface disabled, recording client geometry and window state; no launcher
behavior was changed during this investigation.

Final Simulator state: restored baseline r8 disk, app running. Original VM
resumed automatically and verified running. The bundled release rootfs was not
rebuilt or replaced.

## Subsequent Device-Test Promotion

The user subsequently requested promotion for physical-device testing. The iOS
assembly default, r10 packaging default, rebuilt image, signed device build, and
disk-backup correction are recorded in `docs/device-test-promotion.md`. That
handoff supersedes the earlier opt-in/deployment status above, not the measured
results or unresolved responsiveness and visual-correctness limitations.

## 2026-10-30: Loader Identity And Launch Framing

A new diagnostic run on the disposable Phase7 Cache Benchmark Simulator reached
Phosh and Settings with zero native-executor fallbacks. Matching the Settings
process's mappings and the exact r10 package debug symbols resolved sampled PCs
`0x6b9b8` and `0x6b88c` to `dl_strcmp` and `gnu_hash` in the dynamic loader.
These are bounded heavy-hitter samples, not CPU-time percentages.

An additional relocation cache was rejected before implementation: scanning the
cached ELF relocations found only 57 repeated lookups among 3,093 GTK4 relocations
and one among 2,777 Settings relocations. Instead, r11 adds an address-identity
check to the loader's existing string comparator. Equal pointers return zero
without rereading their string; distinct pointers still take musl's original
bytewise comparison. Hashing, lookup order, versions, TLS and runtime scope
behavior are unchanged. No word overreads, interpreter pattern matching, or
process-global resolved-symbol cache was added.

The diagnostic UART also exposed a separate correctness problem: the Settings
launch marker could follow `arm64viz-root:~#` and its ANSI query on the same line.
The decoder then missed the request and did not activate the bounded launch
scheduling policy. The launcher now prefixes the marker with the existing record
separator. The decoder accepts framed and historical unframed markers; the console
filter removes the framed control record without delaying the shell prompt.
Tests exercise every UART split, oversized-line recovery, and the unchanged
12-second scheduling deadline. This fixes terminal-launched Settings; it is not
a claim that the launcher's separate structured lifecycle protocol was broken.

### Comparison Method

- Same Release host in both arms, including the framing fix; normal assembly/C
  executor, two parallel vCPUs, Simulator's default 1,024 MiB RAM.
- One Pinecone VM running; no builds or test suites during timed runs. Other
  desktop applications remain open, so this is not an isolated-host laboratory.
- Restore a preserved, filesystem-checked seed before every run. The candidate
  clone differs only in the exact signed r11 package's loader. Both seeds contain
  the same updated session launcher. Direct loader replacement is for this
  controlled experiment only; APK metadata in those clones still identifies r10.
- Hot-PC profiling off; interaction traces and performance reporting on equally
  in both arms. Launch Settings 60 seconds after Phosh readiness, manually unlock
  beforehand, and use host-observed request and Phoc presentation milestones.
- Measure first presented Settings surface, not complete widget initialization
  or universal touch-to-frame latency. Sum both vCPUs' native instruction deltas.
- Discard the exploratory run that overlapped compilation.

Correctness checks: 668 core tests, 14 graphical-overlay tests, 12 loader cases on
the isolated build and another 12 on the exact signed r11 package, plus UBSan
string-ordering/high-byte/prefix/guard-page checks. Simulator Release builds.
The host OSK policy mocks pass; its real priority/exec test explicitly skipped
because the sandbox denied `setpriority`.

### Results And Decision

| Run | Loader | Phosh ready | Settings request to first surface | Native instructions, both vCPUs |
| --- | --- | ---: | ---: | ---: |
| A1 | r10 | 83.865 s | 33.101 s | 1,199,137,593 |
| B1 | r11 | 77.025 s | 24.612 s | 1,110,363,362 |
| A2 | r10 | 82.631 s | 38.830 s | 1,206,756,807 |
| B2 | r11 | 85.596 s | 57.159 s | 1,313,917,387 |

All four runs reached Phosh, accepted unlock, and displayed Settings with zero
fallbacks. Settings' title bar was visible in these checks; this is not exhaustive
pixel-correctness validation. The r11 result **did not replicate**. These data
neither prove a loader speedup nor establish the cause of B2's slower run.
Normal packaging and staging remain r10. Building r11 requires explicit
`PINECONE_MUSL_SYMBOL_IDENTITY=1`, and staging it separately requires
`PINECONE_MUSL_PACKAGE_VERSION=1.2.6-r11`.

Full per-run metrics, UART logs, and preserved comparison disks are local test
artifacts under `/tmp/pinecone-responsiveness-20261030`; they are not release
images. Snapshot metrics include cumulative frame statistics, so those must not
be presented as Settings-only GPU timing. The initial input sample was not
causally correlated to a presented guest frame; no touch-latency gain is claimed.

### Separate Scheduling Experiment (Default Off)

The source audit found that the 12-second high-throughput launch window also
controlled whether the host inserted continuous-execution pacing sleeps. All
four measured Settings launches exceeded that window. A still-pending first
frame was therefore eligible for artificial pacing despite remaining user work.

`ApplicationExecutionPolicy.isAwaitingPresentation(at:)` can separate that
decision from the short priority window. Pending first presentation suppresses
the primary/secondary host duty-cycle delays, but does not extend high-throughput
quanta, change touch scheduling, disable WFI waits, or alter graphics fences.
Presentation, launch failure/cancellation, VM cancellation, clock rollback, or
the existing bounded lifecycle deadline ends suppression (120 seconds by
default). Out-of-order presentation stops suppression even while waiting for
GIO's launch callback. CPU usage can consequently be higher during a slow launch;
normal idle pacing resumes afterward.

The above A/B timings predate this pacing correction and are not evidence for
its performance. The expanded core suite passes 671 tests, including separate
checks for the priority deadline, presentation, timeout, cancellation, replay,
clock rollback, and out-of-order callback behavior.

The matched-seed C1 run using r10 with this experiment reached Phosh in 94.593
seconds and Settings' first surface in **41.010 seconds**, with **1,460,061,621**
native guest instructions across both vCPUs during the launch interval. It
booted, unlocked, and rendered Settings without fallbacks, but did not beat the
33.101/38.830-second baselines. Its larger instruction count warrants investigating
guest execution/synchronization work; it does not prove a particular contention
mechanism. This is not an accepted speedup.

`PINECONE_EXPERIMENTAL_UNPACED_LAUNCH=1` is required to enable it. Unset or any
other value retains the original 12-second pacing exemption. The normal release
keeps both this experiment and r11 disabled; only the UART launch-framing
correction is promoted. The pending-work API and its tests remain available for
controlled investigation, not as an assertion of better default performance.

The normal guest image was rebuilt with r10, correct APK metadata, and the
updated launcher, and passed `e2fsck -fn`. The local build used
`PINECONE_CACHE_LIMA_INSTANCE=pinecone-builder` because the older cache builder
selection (`pinecone-wlroots`) lacked Bash. Existing Pixman/Cairo binaries were
reused through their supported build flags and the Cairo manifest was verified.
The pre-change release image is preserved with the other local test artifacts.

### Final Deployment And Smoke Check

The final arm64 Simulator Release app includes the rebuilt normal r10 image.
Both experimental flags are unset. On a fresh copy of that image, normal
`start-pinecone-phosh` autostart reached Phosh readiness at 75.792 seconds and
switched to Display. A real tap unlocked Home; a real Settings dock tap opened
Settings with its title bar visible and no fallback instructions. The app is
left running in `Pinecone Phase7 Cache Benchmark` for manual inspection. No
physical device was modified.

This cold GUI launch took **63.712 seconds** from the structured launch request
to presentation. It uses a fresh disk and the launcher rather than the preserved
seed and scripted terminal command, so it is not another matched A/B sample.
It confirms functionality, not improved responsiveness. Its metrics and UART
are saved as `final-default-smoke.json` and `final-default-smoke-uart.log` in the
local artifact directory above. There is **no repeatable UI-speed win from this
pass**. The accepted change is the launch-framing correctness fix; further guest
startup/execution profiling remains necessary before another performance
change is promoted.

### Controlled vCPU Affinity Investigation (2026-10-30)

The earlier correlation between secondary-vCPU instruction share and slow
Settings launches did **not** survive controlled affinity tests. Settings was
slower when constrained to the **primary** vCPU in both pairs below.

Added `scripts/guest-vcpu-probe.c`, a diagnostic-only Linux helper. It sets and
reads back `sched_setaffinity`, checks that the mask contains exactly the
requested CPU, and either runs deterministic scalar/memory work or execs a
command with inherited affinity. It is not part of the production rootfs or app.
The static aarch64 build used `cc -O2 -static -Wall -Wextra -Werror -std=c11` in
`pinecone-builder`. Native Linux and emulated runs produced identical checksums:
`9d44abf2ef311241` (scalar) and `6bf0a788af45eeca` (memory).

Method:

- Same existing Simulator Release executable, r10 loader, two parallel vCPUs,
  1024 MiB guest RAM, and default interpreter settings throughout.
- Every Settings attempt restored the same checked `affinity-seed.ext4`, a clone
  of the preserved r10 seed with only the diagnostic helper added. The original
  Simulator disk was preserved separately. No physical device was used.
- Phosh ran in the background with interaction traces enabled. Settings was
  requested 60 seconds after guest readiness, with Phosh manually unlocked
  beforehand. Unlock timing was manual, not identical across attempts.
- Settings was started with `guest-vcpu-probe CPU --exec pinecone-launch-settings`.
  `/proc/PID/task/*/status` confirmed the new Settings process's affinity three
  seconds after launch. New threads inherit that mask. This does not pin Phoc,
  Phosh, D-Bus services, or all guest kernel work to the same vCPU.
- The first attempt's pre-launch `pidof` guard was unavailable in this guest.
  Later attempts scan `/proc/*/comm` instead. The first attempt still had a new,
  surviving Settings PID with the requested affinity, rather than a launcher
  that immediately exited after forwarding to an existing process.
- Measured launch request to first surface associated with Settings, not the
  completion of all widgets or an input-to-response interaction. Both vCPU
  instruction deltas are included. Visual checks subsequently confirmed Settings.
- Each attempt sampled host stacks for 15 seconds near launch at 2 ms intervals.
  No builds or other Pinecone VM ran during measurement. Chrome, WindowServer,
  Codex, and other desktop services remained active: these are attribution runs,
  not fully isolated release-acceptance benchmarks.

| Attempt | Settings CPU | Launch to first surface | Primary instructions | Secondary instructions |
| --- | --- | ---: | ---: | ---: |
| 0a | 0 | 56.645 s | 1,078,989,878 | 190,908,074 |
| 1a | 1 | 37.533 s | 141,430,612 | 1,105,302,877 |
| 1b | 1 | 44.793 s | 214,986,667 | 1,129,925,674 |
| 0b | 0 | 67.613 s | 1,078,021,134 | 170,461,929 |
| 0, experimental pacing suppression | 0 | 33.170 s | 1,064,009,745 | 118,663,200 |
| 0, pacing suppression repeat | 0 | 25.022 s | 1,063,411,973 | 102,241,837 |

All listed runs booted Phosh, unlocked, and rendered Settings with zero Swift
fallbacks. The 33.170-second control enabled the existing
`PINECONE_EXPERIMENTAL_UNPACED_LAUNCH=1` option; no interpreter or graphics code
changed. Its primary instruction count was within 1.4% of both CPU-0 baselines.
This is evidence that launch-time pacing contributes to the pinned CPU-0 delay.
The option changes pacing for **both** vCPUs, so it does not isolate a primary-only
policy or establish a speedup for unrestricted launches.

The repeated pacing control reached the first Settings surface in 25.022 seconds,
again with zero fallbacks and a visually rendered Settings window. Both controls
executed approximately 1.064 billion primary instructions, versus 1.078-1.079
billion in the normal CPU-0 runs. This supports pursuing a per-vCPU launch-pacing
fix, not claiming the unrestricted application is already faster.

Host samples locate the difference more narrowly:

- Primary execution runs in a Swift cooperative task, using `Task.yield()` and
  `Task.sleep` between slices. It appeared on multiple host worker threads.
  Secondary execution uses one dedicated `Thread` and condition-variable waits.
- In the late CPU-0 baseline sample, backend execution occupied approximately
  3,638 of 5,857 sampling ticks (62%). This is sampled occupancy, **not** precise
  scheduler delay accounting. An absent runnable stack can mean guest idle,
  deliberate pacing, or host scheduling. Do not label all that time lock contention.
- Mutex-wait stacks were sparse. Code-cache lookup, validation, mapping checks,
  and decoding accounted for roughly 13-21% of the classified backend samples
  in the four baseline launch windows. Swift zero-fill callbacks were visible
  but much smaller. Removing synchronization indiscriminately is not supported
  by these profiles.
- Cumulative host commit-to-present p95 was 21-25 ms in the baseline runs. Those
  samples include boot and unlock; they are not Settings-only frame latency.
- The short scalar probe had overlapping, noisy timings. The memory probe favored
  CPU 1 (0.228/0.233 s versus CPU 0's 0.441/0.419 s), with identical checksums.
  These short probes were sampled and are not a general interpreter ranking.
  Their `guest_thread_ns` field is Linux guest accounting, not host CPU time.

Raw reports, UART transcripts, host stack samples, and the temporary orchestration
scripts are under `/tmp/pinecone-responsiveness-20261030/affinity-*` and
`run-affinity.py`. The `affinity-settings-1b-late.sample.txt` capture began after
launch completed and is excluded from launch attribution.

The next scheduling change should separate primary launch pacing from secondary
and idle pacing, then compare unrestricted Settings launches and real touch
responses. Do not ship permanent application CPU affinity as a workaround, or
promote the global unpaced option based only on pinned results. Cache/translation
cost remains a separate measured optimization target, not proof of a broken
secondary interpreter.

Cleanup status at the end of the affinity investigation: the benchmark app was terminated, but automatic approval review
then rejected restoration of the preserved Simulator disk because its usage limit
was exhausted. Restoration and normal-app relaunch did not execute. The app is
stopped, the disposable Simulator still holds the diagnostic disk, and the
pre-benchmark disk remains preserved as `pre-affinity-user-disk.ext4` in the local
artifact directory. No production default was changed in this investigation.
The final full-suite rerun was not started; the previous pass's 671-test result
must not be presented as a new run for this investigation.

## Primary Launch Pacing Fix (2026-10-30)

The implementation now computes separate primary and secondary pacing decisions
from one locked launch-policy snapshot. A pending, not-yet-presented application
suppresses primary host duty-cycle sleeps until presentation, failure,
cancellation, or the original 120-second lifecycle deadline. Secondary pacing
remains eligible after the existing 12-second boost; the high-throughput execution
profile is not extended. WFI waits, interrupt handling, touch priority, network
eligibility, idle pacing, and the two-vCPU configuration are unchanged.

The secondary setting is still applied at existing runner decision points, not
by a new strict worker-side deadline. `PINECONE_EXPERIMENTAL_UNPACED_LAUNCH=1`
remains a diagnostic control that additionally extends secondary suppression;
it is not needed for the primary fix and is not enabled by default.

Presentation matching now skips launches that already observed their surface
while awaiting a late launch callback. This prevents two overlapping same-app
launches from repeatedly consuming the oldest presentation slot. Phoc still
reports app IDs rather than per-window launch tokens, so exact cross-window
attribution is not claimed.

Independent code review found no blocking defects. The complete Swift suite
passed 675 tests, including independent pacing boundaries, lifecycle termination,
clock rollback, overlapping presentations, and independent launch deadlines.

The first unrestricted baseline attempt reached and unlocked Phosh but did not
produce a Settings surface within the 360-second run limit (launch request at
186.751 seconds). Home was still rendering when the timed launch was submitted,
so this is a startup-contention timeout, not a clean standalone Settings latency.
Its logs are preserved as `primary-pacing-baseline-a-timeout*` under the local
artifact directory. Subsequent comparison must launch from a visibly ready Home
screen, use the same disk seed, and report actual first-surface measurements.

### Resumed Simulator Verification

The interrupted afternoon runs are excluded: host load rose above 400, and the
user cancelled verification. The preserved disk was restored at cancellation.
Verification resumed after host load returned to approximately 1.5. Only the
benchmark Simulator was booted; no other Pinecone VM, compiler, or test suite ran
during these measurements. Normal desktop applications remained open, so these
are controlled local comparisons, not fully isolated laboratory measurements.

Each run restored the same r10 disk seed and started a fresh VM with two vCPUs.
Phosh was unlocked after readiness, and Settings was launched by tapping its dock
icon only after Home was visibly rendered. No guest CPU affinity was imposed.
Both builds used identical tracing and a 15-second, 2-ms host sample beginning
at the launch request. The global unpaced-launch experiment remained off.
Run order was candidate A, baseline A, baseline B, candidate B.

| Build / Run | Phosh Ready (s) | Settings First Surface (s) | Primary Launch Instructions | Secondary Launch Instructions | Fallbacks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline A | 70.402 | 37.696 | 938,849,068 | 548,458,809 | 0 |
| Baseline B | 69.660 | 38.997 | 989,976,544 | 534,942,257 | 0 |
| Candidate A | 63.229 | 27.607 | 995,350,680 | 366,506,738 | 0 |
| Candidate B | 70.800 | 26.947 | 812,449,494 | 601,626,603 | 0 |

Mean Settings request-to-first-surface time decreased from **38.346 seconds to
27.277 seconds**, approximately **28.9% lower latency** across two runs per build.
All four sessions visibly reached the lock screen, unlocked to Home, and rendered
Settings. Candidate A additionally passed Settings category navigation and return
to Home. No new unsupported-instruction failure or fallback was observed.

This is a repeatable startup improvement in these runs, not a claim that touch latency or
animation smoothness is solved. First-surface time is not time to complete every
widget repaint. Manual unlock/launch timing, guest task distribution, ASLR and
instruction work varied; the table exposes both vCPU instruction deltas rather
than treating the primary badge as total work. Boot readiness does not show a
consistent improvement and is not attributed to this fix. Peak launch CPU usage
may increase when deliberate primary sleeps are removed; ordinary idle pacing is
unchanged.

Raw JSON, UART logs and host samples are preserved under
`/tmp/pinecone-responsiveness-20261030/primary-pacing-{baseline,candidate}-resumed-{a,b}*`.
The Release build and its independent review remain the ones validated by the
675-test pass; no source changes were made during the resumed comparison.

After comparison, the fixed Release app was reinstalled, the original
`pre-affinity-user-disk.ext4` was restored and byte-compared successfully, and
normal autostart was relaunched without CPU-affinity or global-unpaced overrides.
The unused iPhone 17 Simulator remains shut down, as approved by the user.
The final normal-launch smoke test reached the shell in 2.980 seconds and Phosh
readiness in 72.067 seconds, automatically switched to Display, and visibly
unlocked to the complete Home screen with zero fallbacks. The fixed app was left
running there for manual testing. Final telemetry is saved as
`primary-pacing-final-normal.json` and `primary-pacing-final-normal-uart.log`
alongside the comparison artifacts.

## Committed SHM Textures and Packed Masks (2026-10-30)

The next graphics audit found repeated guest-side source uploads, not expensive
host presentation. At 64 Phoc composite operations, the mask-only candidate had
copied 84,443,520 source bytes. Foreign wl_shm pointers cannot safely receive a
stable ownership lease: clients can change them outside the bridge's knowledge.
The existing conservative re-upload behavior was correct but expensive.

### Implementation

- Added `pinecone_pixman_snapshot_bits`: capture a committed ARGB/XRGB SHM
  texture into independently owned DRM-backed storage while wlroots holds its
  source READ scope. Redrawing the texture references that resource directly.
- Added `pinecone_pixman_update_snapshot`: copy only validated damage rectangles
  on subsequent commits. Wait for queued GPU readers before changing storage;
  failed synchronization leaves pixels unchanged. Reject aliases, invalid
  strides/rectangles and excessive rectangle counts before copying.
- Patched Phoc's embedded wlroots Pixman renderer to create and update these
  private textures. Shared textures follow wlroots' existing replacement rules.
  Unsupported formats, allocation failures and unavailable bridge hooks retain
  the existing renderer path. DMA-buf imports are unchanged.
- Bound retained private snapshots to 16 MiB per bridge process. This is not a
  whole-VM memory cap or a strict transient-allocation peak cap.
- Keep ordinary A8 masks packed instead of expanding each coverage byte into
  four bytes. Component-alpha A8 retains zero RGB coverage, matching Pixman;
  ARGB/XRGB uploads use row copies. Host compositor formats are unchanged.
- Built Phoc `0.57.0-r8` and updated the build/staging package pin. The SHM path
  is gated by `PINECONE_WLROOTS_SHM_SNAPSHOT=1`; it is not default-enabled.

### Exploratory Measurements

Same host app, two vCPUs and seeded guest disks; Settings was tapped from a
visibly ready Home screen. A separate original Pinecone VM remained running.
These are single-run, non-isolated observations, not a statistical performance
claim. The off run and snapshot-only run use the first r8 binary; the final
damage-update run uses its subsequent rebuild. Guest tracing was enabled in
all runs, but host interaction tracing was off in the snapshot-only run.

| Variant | Render-to-submit Median (ms) | P95 (ms) | Render CPU Total (ms) | Frames | Settings First Surface (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Snapshot disabled | 30.078 | 359.167 | 651.138 | 17 | 25.697 |
| Snapshot only | 4.882 | 65.969 | 206.012 | 24 | 25.479 |
| Snapshot with damage updates | 5.928 | 17.086 | 95.305 | 23 | 27.195 |

Frames are those with `renderUs` between the last touch-up before the first
Settings surface and that surface's presentation. This temporal window does not
prove per-frame touch causality. Render CPU is summed over those frames, not all
guest work. Snapshot capture occurs before the render interval, so lower render
time alone must not be reported as an equivalent total-work reduction. The
snapshot-only run copied 18,120,960 source bytes at 64 composite operations;
operation counts do not guarantee identical content or workload.

The final candidate's render-stage median was about 80% lower in these runs,
but **Settings startup did not improve**. It still took about 27 seconds. There
is no demonstrated full touch-to-display or animation-FPS improvement yet.
Damage updates address the full-copy/allocation cost that a snapshot-only
implementation could move into every surface commit.

### Verification and Rollout

- Guest bridge regressions passed normally and with undefined-behavior trap
  instrumentation, including the actual upstream output-commit regression.
- New tests cover independent snapshots, damage-only copies, whole-list
  validation before writes, alias rejection, empty damage, failed/signaled GPU
  fences, retained-budget cleanup and zero-copy repeat draws.
- Metal differential tests passed 3,528 cases in direct mode and 3,528 in
  simulator-copy mode. No host Metal implementation changed in this patch.
- The final candidate booted, unlocked, rendered Settings Network and its
  category list, returned Home and rendered All Apps without observed missing
  text or stale pixels. Both vCPUs reported zero fallbacks at first surface;
  native/prepare/finish/synchronization graphics-failure counters were zero.
- Candidate is running in the disposable **Pinecone Graphics Mask Validation**
  Simulator (`4477AAE1-B35F-4800-A442-65080307F4E2`). The original benchmark
  Simulator and its disk were not modified. The production rootfs and iOS
  bundle were not rebuilt; the candidate guest components were installed in
  the disposable test disk only.

Raw artifacts and the analysis script are under
`/tmp/pinecone-responsiveness-20261030/`: `graphics-shm-off-a*`,
`graphics-shm-on*`, `graphics-shm-damage-on-a*`, and `summarize-graphics.py`.
Next acceptance gate is repeated same-binary flag-off/flag-on measurements with
other VM execution paused, including complete input-to-presentation and commit
costs. App startup needs separate profiling; do not attribute its remaining
delay to host Metal or declare responsiveness solved from this render window.

## Raw Fill Round Trips and Alpha Correctness (2026-10-30)

The next audit found that `pixman_fill()` on ordinary guest RAM allocated a DRM
scratch surface, submitted a solid fill, waited for completion, and copied the
rectangle back through the interpreter. The target was never a shared GPU
surface. This added an ioctl/fence round trip and a full pixel read/copy for an
operation that only needs to write a constant value.

The bridge now defaults to Pixman's existing CPU fill for these buffers.
Eligible registered GPU destinations remain accelerated. Queued work still
flushes and pending fences complete before CPU writes; no interpreter fallback,
guest memory synchronization or resource ownership checks were removed.
`cpu_fills` and `cpu_fill_bytes` distinguish this intentional path in diagnostics.
The old scratch path remains available for opaque foreign fills only with
`PINECONE_PIXMAN_CPU_FOREIGN_FILL=0`, for comparisons. The default is enabled.

### Correctness Finding

An actual guest pixel check found the old scratch path changed raw fill alpha:
`0x00000001` became `0xff000001`, and `0x70133728` became `0xff133728`.
The host correctly normalized an XRGB resource, but `pixman_fill` promises raw
bit writes, not XRGB colors. Routing that API through an XRGB scratch surface
violated its contract. Non-opaque 32-bit raw fills now use the exact CPU path
regardless of the comparison toggle. This also applies to registered mappings;
their cross-thread handle fences are checked before the write. Opaque mapped
fills and packed A8 mapped fills retain their existing accelerated path.

### Measurements

`scripts/benchmark-guest-pixman-fill.c` runs in the emulated guest, binds the
bridge explicitly and requires a real shared DRM image before measurement.
It checks every output pixel and all untouched row padding. Earlier attempts
without that shared image exercised CPU fills in both modes and are excluded.

The valid pre-alpha-fix comparison used mode order 0, 1, 1, 0, twelve synchronous
fills per case, with allocation/fence costs included. In milliseconds:

| Opaque Fill | Scratch A | Direct A | Direct B | Scratch B |
| --- | ---: | ---: | ---: | ---: |
| 480 x 1024 | 73.019 | 27.188 | 27.172 | 74.790 |
| 160 x 40 | 39.511 | 3.513 | 9.276 | 26.831 |

Both opaque cases passed pixel verification. The old non-opaque cases failed
correctness and are not used for speed claims. After the alpha fix, all sixteen
cases in the same mode order passed. Screen-sized opaque scratch fills then
took 246.616/220.920 ms versus 27.556/26.826 ms direct. These later scratch
measurements include cold allocation: preceding transparent fills no longer
warm the scratch allocation. Do not combine the two experiments or describe
their ratio as an overall UI speedup. Other VM activity was not isolated.

At the 1,024-operation Phosh checkpoint, copyback was 32,660,788 bytes in
`graphics-fill-off-a` versus 720,820 bytes in `graphics-fill-on-b`. Operation
counts do not imply identical work, but the direct path structurally eliminates
scratch copyback for these fills; remaining copybacks are composite operations.

Settings first-surface times were 25.117 s with scratch fills and 26.326/26.137 s
with direct foreign fills in preliminary sessions. **No app-startup improvement
is established.** These sessions had varying manual launch times; a 10-second
host sample also ran during candidate A. The host sample remained dominated by
guest instruction execution and block/translation lookup, not Metal execution.
The raw-fill optimization targets painting cost, not all application work.

### Verification

Normal and undefined-behavior-trap bridge regressions pass, including the real
upstream output-commit test. Added coverage checks raw colors/alpha, 8/32-bit
strides and untouched padding, zero scratch allocation/copyback, queued and
pending work, cross-thread mapped readers, and fail-closed behavior after a
bad fence. The default fill policy does not require an iOS host rebuild;
updated guest bridge builds pick it up. The prior SHM snapshot feature remains
independently opt-in.

Artifacts are under `/tmp/pinecone-responsiveness-20261030/graphics-fill-*`.
`graphics-fill-verified-uart.log` preserves the valid pre-alpha-fix pixel/timing
evidence; `libpinecone-pixman-before-alpha-fix.so` preserves that comparison
binary. `graphics-fill-final*` contains the corrected bridge's measurements.
The original benchmark Simulator/disk is untouched; only the disposable
Graphics Mask Validation fixture is used for deployment and verification.

The final build reached Phosh readiness at 77.422 s (including the preceding
microbenchmark), unlocked to Home, opened Settings, repainted its category list,
and returned Home. First Settings surface took 25.809 s. Both vCPU fallback
counters and all four graphics failure counters were zero. Its launch-window
render-to-submit median was 3.940 ms and p95 18.499 ms; host commit-to-present
p95 was 21.971 ms. These do not establish a further compositor or end-to-end
latency gain over the preceding SHM snapshot candidate. The new benefit is the
measured raw-fill cost/copy reduction and corrected alpha behavior.

Reproduce the targeted benchmark inside an aarch64 Linux build environment,
then run the resulting binary in Pinecone's guest with the updated bridge:

```sh
cc -O2 -Wall -Wextra -Werror scripts/benchmark-guest-pixman-fill.c -ldl -o pinecone-fill-bench
LD_PRELOAD=/usr/lib/libpinecone-pixman.so PINECONE_PIXMAN_CPU_FOREIGN_FILL=0 ./pinecone-fill-bench
LD_PRELOAD=/usr/lib/libpinecone-pixman.so PINECONE_PIXMAN_CPU_FOREIGN_FILL=1 ./pinecone-fill-bench
```

Use the installed guest Pixman library, not a host-native timing result. Require
`verified=1` for every case. GPU comparison now applies only to opaque cases;
non-opaque fills are always protected by the correctness fix.

## Solid Composites and Submission Crossover (2026-10-30)

This pass stays in guest graphics, with no interpreter, scheduler or application
startup changes. Three changes are in `scripts/rootfs/pinecone-pixman.c`:

1. Solid colors now match upstream Pixman's `color_to_uint32` exactly. The old
   bridge multiplied already-premultiplied RGB by alpha again, and rounded
   16-bit channels instead of extracting their high byte. Translucent GPU draws
   therefore differed from CPU Pixman. The new guest benchmark reproduced the
   mismatch on every GPU case; after correction every GPU/CPU case passed.
2. Simple solid-source OVER draws of at most 256 pixels into ARGB destinations
   use CPU Pixman, with either no mask or a simple A8 mask. This avoids the guest
   ioctl/fence/upload path for work smaller than its submission overhead. Active
   compositor render passes and already-queued batches are excluded. Existing
   image synchronization still runs before returning control to CPU Pixman.
   `PINECONE_PIXMAN_CPU_SMALL_COMPOSITE=0` disables this routing for comparison;
   it is enabled by default. `cpu_small` and `cpu_small_pixels` record it without
   treating it as an unsupported instruction or failed graphics operation.
3. CPU-return handling also invalidates destination image generations without
   a registered buffer lease. Previously only leased buffers were invalidated,
   allowing an image-owned upload cache to retain a stale generation.

### Pixel-Checked Guest Measurements

`scripts/benchmark-guest-pixman-composite.c` draws repeatedly into a real shared
ARGB surface, waits for GPU completion, and checks all pixels and padding against
an integer premultiplied OVER reference. A8 masks exercise varied coverage.
Allocation/initialization and pixel verification are outside the timed span;
submission and completion are inside it. Each cell below is milliseconds for
32 draws. Policy order is disabled, enabled, enabled, disabled, in separate
processes on the same emulated guest. All 64 cases passed pixel verification.

| Draw | Disabled A | Enabled A | Enabled B | Disabled B |
| --- | ---: | ---: | ---: | ---: |
| Unmasked 8 x 8 | 10.442 | 1.287 | 1.209 | 27.500 |
| Masked 4 x 4 | 33.649 | 4.485 | 3.623 | 58.177 |
| Masked 8 x 8 | 31.391 | 4.663 | 3.694 | 36.486 |
| Masked 16 x 16 | 35.721 | 7.432 | 5.288 | 29.916 |
| Masked 32 x 32 (GPU unchanged) | 40.731 | 41.461 | 39.343 | 36.441 |
| Masked 128 x 128 (GPU unchanged) | 97.955 | 104.355 | 98.984 | 106.631 |

The crossover supports the conservative size limit, not a whole-UI speed claim.
Other Simulator activity was not isolated. The initial pre-fix GPU measurements
failed pixel checks and are not valid performance comparisons.
Small submitted commands can execute in the host-native graphics backend rather
than Metal; this optimization removes their guest/device round trip. It is not
evidence that Metal's blend kernels became faster.

### Full Session and Remaining Work

The corrected-color baseline (`graphics-fill-composite-corrected`) reached
Settings' first surface in 21.366 s; the routing candidate
(`graphics-fill-composite-small`) took 28.497 s. These were single, non-isolated
manual launches at different post-boot times, so no app-launch gain or causal
regression is established. Do not use the microbenchmark ratio as launch speed.
The corresponding compositor render-to-submit medians were 10.352/3.347 ms,
with p95 17.765/13.930 ms, across 23/40 launch-window frames. Different frame
counts and workloads mean this is observational, not a controlled animation
benchmark. Candidate host commit-to-present p95 was 18.954 ms; presentation
interval p95 remained 233.996 ms. Responsiveness is not solved.

Real guest use is confirmed: at Settings' 1,024-operation checkpoint, 310 draws
covering 7,001 pixels used the new route. Phoc's render-pass draws stayed on
their existing path. Remaining costs include repeated bitmap-source tiny draws
(not covered by the solid-only policy), guest cache/hazard processing, and SHM
uploads: Phoc had copied 34,880,672 source bytes by operation 256, including
snapshot creation/updates. That byte count alone does not prove wasted copies;
the next rendering measurement should separate new textures, damage updates,
budget rejections, and snapshot reuse before changing ownership or lifetimes.

Normal and undefined-behavior-trap bridge regressions pass. Added tests cover
all 65,536 component values, policy bounds/overflow, render-pass and queued-batch
exclusions, cache generations, cross-thread reader fences and fail-closed fence
errors. No host Swift/Metal changes were made. The disposable Graphics Mask
Validation Simulator booted, unlocked, and rendered Settings and its category
list, returned Home, and displayed All Apps with zero interpreter fallbacks and
zero graphics prepare/native/finish/
synchronization failures. The user's original VM and disk were not modified.

Artifacts and UART/JSON reports are in `/tmp/pinecone-responsiveness-20261030/`
under `graphics-fill-composite-*`; the final bridge is
`libpinecone-pixman-small.so`. Build the helper on aarch64 Linux with:

```sh
cc -O2 -Wall -Wextra -Werror $(pkg-config --cflags pixman-1) scripts/benchmark-guest-pixman-composite.c $(pkg-config --libs pixman-1) -ldl -o pinecone-composite-bench
LD_PRELOAD=/usr/lib/libpinecone-pixman.so PINECONE_PIXMAN_OPERATOR_MASK=0x100f PINECONE_PIXMAN_CPU_SMALL_COMPOSITE=0 ./pinecone-composite-bench
LD_PRELOAD=/usr/lib/libpinecone-pixman.so PINECONE_PIXMAN_OPERATOR_MASK=0x100f PINECONE_PIXMAN_CPU_SMALL_COMPOSITE=1 ./pinecone-composite-bench
```

Run it in Pinecone's guest, with the patched Pixman and bridge, not on the build
host. Require every `verified` field to be 1.

### Standard Build Promotion (2026-10-30)

The normal session launcher now supplies `PINECONE_WLROOTS_SHM_SNAPSHOT=1`
when unset, preserving an explicit diagnostic `0`. Foreign-buffer fills and
eligible tiny solid composites already default to the CPU policy in the bridge.
No Simulator autorun command or graphics-enabling environment overrides are
needed. This changes guest rendering policy, not interpreter fallback policy.

Rebuilt the standard rootfs and Simulator Release app. The rootfs embedded in
the app has SHA-256
`530cd6d360668dd4121c6bdeb10b215b00ae3eef95a9c3e58fb0a806541b5cdb`.
Its bridge and Phoc r8 binaries match the validated artifacts byte-for-byte:

- Bridge: `5804ed5143e255c7adfec7efbdaa078b17d8aaa41cdcc63d5a947c8b1765570c`.
- Phoc: `39162d74061b6148a72f0817522a637f1cc0b5749c44eeb54d3ad3d235999ffc`.

The stale-Cairo provenance check correctly stopped the first image build.
Rebuilding Cairo reproduced its existing library hashes and passed its ownership
and stock-pixel checks; the subsequent image build passed. No provenance check
was bypassed. Launcher default/opt-out checks, 14 overlay dependency tests,
7 guest-cache tests, bridge regressions and 10 Phoc layout tests passed.
The launcher kernel priority check was skipped because sandbox `setpriority`
returned EPERM; mocked priority tests passed.

Installed only on the disposable Graphics Mask Validation Simulator and launched
without environment overrides. The previous writable disk was retained by the
app and separately backed up before installation. The user's original VM was
not modified. This is promotion validation, not an isolated performance result.

The promoted app reached the shell, automatically launched Phosh and switched
to the lock screen. Manual input verified tap-to-unlock, Home, Settings' Network
page, the Settings category list, return Home and All Apps. Text and icons
rendered in those views, and the counter remained at zero interpreter fallbacks
(3.409 billion native instructions at the final check). All Apps required a
second tap during this smoke test; this does not establish that touch latency
is resolved. No physical-device run was performed for this promotion.

## Snapshot Reuse And Input Admission (2026-10-30)

Follow-up uses the same Graphics Mask Validation Simulator, normal executor and
two-vCPU policy, with bounded guest Pixman diagnostics and host/Phoc input trace.
Hot-PC profiling is off. The original user VM remains untouched and running, so
these are diagnostic observations, not isolated whole-UI benchmarks. Clean image
clones avoid reusing an unreplayed live ext4 journal in offline modifications.

### Findings

At Phoc's 256-composite checkpoint the baseline recorded 14 private snapshots,
23,727,360 initial-copy bytes, 12 updates with 13,634,296 damage-copy bytes,
206 direct snapshot draw submissions and 7 releases. Budget, allocation and
update rejection counters were zero. Repeated drawing does reuse snapshots;
raising the 16 MiB limit is not justified by this capture. Draw submissions are
not necessarily unique textures or completed frames.

For the first three manually observed interactions (unlock, Settings, Home),
host queue-to-injection maxima were 0.361 ms for down and 0.198 ms for up.
Capture-to-queue maxima were 3.902/16.378 ms respectively. Phoc recorded three
down/up pairs. The subsequent All Apps tap also produced a Phoc down/up pair and
eventually displayed the app grid without another tap. Its first use schedules
full `g_app_info_get_all()` discovery through `items_changed` on Phosh's main
loop. That is an additional guest-work hypothesis, not proof that discovery
accounts for all of the delay. No scheduler or input coalescing settings changed.

The host and guest traces still lack shared end-to-end input identity. Independent
ring counts cannot prove correspondence, lost-input absence, or touch-to-photon
latency. `expiredUncorrelated` is not a dropped input: injection timestamps remain
available. Early commit-to-present samples also include frames created while the
terminal was visible; do not interpret that startup tail as interactive latency.

### Changes And Copy Measurements

Added power-of-two SHM checkpoints separating creation, damage updates, empty
updates, direct snapshot draws, releases and failure reasons. The analyzer keeps
only the latest cumulative checkpoint per PID, rejects reset/truncated records,
and reports host admission by phase separately from validated guest frame spans.
Diagnostics remain opt-in and do not alter the production rendering policy.

Private snapshots now request exact resource dimensions, instead of using the
rounded scratch-buffer allocation policy. The prior allocator rounded the real
480-pixel surface to 512 pixels, forcing row copies even for full-width damage.
Virtio-GPU returns width-times-four pitch (allocation bytes remain page-aligned).
At 480 x 1024 this removes 128 KiB of padding per snapshot, or 6.25% of its prior
allocation. Reusable scratch buffers retain their old sizing policy.

A shared copy helper folds tightly packed rows into one memcpy, preserving
row-wise copies for padding and partial-width damage. It never copies padding
or relaxes source READ scopes, damage validation, fence waits or generation
invalidation. A 480 x 3 regression verifies exact pitch and one copy per full
update; all padding, failed-fence and independent-snapshot regressions remain.

`benchmark-guest-snapshot-copy.c` runs the production helper against the previous
row loop inside Pinecone's ARM64 guest, in A/B/B/A order. Each cell below is the
elapsed time for eight copies; all 16 cases passed pixel/padding checks:

| Case | Row A | Bulk B | Bulk B | Row A |
| --- | ---: | ---: | ---: | ---: |
| Packed 512 x 960 | 12.299 ms | 8.114 ms | 8.250 ms | 11.846 ms |
| Padded 480 x 800 | 13.778 ms | 18.770 ms | 17.324 ms | 18.658 ms |
| Packed 64 x 64 | 0.702 ms | 0.101 ms | 0.090 ms | 0.623 ms |
| Padded 4 x 8 | 0.047 ms | 0.034 ms | 0.028 ms | 0.030 ms |

The packed full-surface path reduces 7,680 memcpy calls to 8, with about one-third
less time in this microbenchmark. The unchanged padded case is noisy and does
not establish a speedup. The absolute full-surface saving is only about 0.5 ms
per copy; it cannot explain or solve multi-second app startup. The intermediate
bulk-helper-only Phosh run exposed 2,048 calls for two initial 480-wide snapshots,
which is why exact resource allocation was added rather than claiming that the
microbenchmark path was already used in the real UI.

Normal and undefined-behavior-trap bridge suites pass, along with eight analyzer
tests. The intermediate helper-only image booted, unlocked and opened Settings
with zero interpreter fallbacks. Raw logs and JSON are under
`/tmp/pinecone-responsiveness-20261030/shm-*`. No physical-device validation or
whole-UI responsiveness improvement is claimed from these measurements.

The exact-allocation run confirms the real path: two initial full-screen
snapshots required 2 memcpy calls, versus 2,048 in the helper-only run. At its
256-operation checkpoint, Phoc had 13 creations, 12 updates, 211 direct snapshot
draws and 895 total copy calls, including partial-width damage. All snapshot
failure counters remained zero. Home and Settings (including category-list text
and icons) rendered correctly. Single non-isolated Settings launch-to-surface
observations were 24.268 s in the instrumented baseline and 26.660 s in this run;
they do not establish either an overall speedup or causal regression. Builds
also ran during the latter smoke test, so it is not a timing comparison.

Final review added a zero-area rectangle guard before calculating copy pointers
at the bottom/right image boundary, with corner/edge regression coverage. The
standard rootfs was rebuilt after that guard; SHA-256:
`ee5850fe31b77e5edad1519476460b8ed0cb2c82b57778d9b461520afc41bd9a`.
Its bridge SHA-256 is
`dc763edaec11aeefa55de8651a2d41c9e0520284ff8e7c9cb957981c37bb6b36`.
No benchmark helper is included in the standard rootfs. The eight profiler
compatibility tests also pass.

Final Release Simulator build/install succeeded. Launched without any environment
overrides, reached the shell, automatically started Phosh, tapped to unlock Home
and opened Settings' Network page. The final visible native counter was 2.772
billion with zero fallbacks. The preceding instrumented exact-allocation run
also verified the category list, Home return and All Apps; graphics prepare,
native, finish and synchronization failures were all zero. The final normal app
is left running in the validation Simulator. Original VM and disk are preserved.

## Simulator Metal Barrier Compatibility (2026-10-31)

Xcode's Metal API validation aborted at `executeBatch`'s
`memoryBarrier(scope: .buffers)` on the iPhone 17 / iOS 26.2 Simulator:
`compute memoryBarrierWithScope is not supported on this device`.
The previous differential runner exercised Simulator staging code on macOS,
not the iOS Simulator's Metal implementation. That did not validate the latter's
API capabilities.

The batch encoder now explicitly requests serial dispatch, and its device-created
buffers explicitly request tracked hazards. Metal provides dispatch ordering for
these resources; the redundant, unsupported barrier and per-command written-ID
set have been removed. This retains one command buffer per batch, asynchronous
completion and existing Simulator copyback/fence behavior. It does not disable
validation, force CPU rendering, or add per-operation GPU waits. See Apple's
[resource synchronization contract](https://developer.apple.com/documentation/metal/resource-synchronization).

The differential runner now enables Metal API validation by default. Its new
`--simulator BOOTED-UDID` option compiles and installs a separate test fixture for
the actual iOS Simulator without replacing Pinecone or its VM disk. Ordered-batch
tests span multiple workgroups and partial edge groups, compare complete padded
allocations against sequential submissions, and cover source/mask read-after-write,
write-after-read and write-after-write dependencies, both synchronous and async.
They also assert that the batch remains a single command-buffer submission.

Verification: 3,528 Pixman golden cases plus ordering, partial-damage, scaling,
staging isolation and telemetry regressions pass on macOS direct buffers, macOS
Simulator-copy buffers, and the affected iPhone 17 Simulator, with Metal validation
enabled in all three runs. The Release Simulator app rebuild succeeded. No guest
image changes are part of this fix.

Installed the fixed Release build over the affected iPhone 17 Simulator app,
preserving its existing disk (bundle fingerprint unchanged). With
`MTL_DEBUG_LAYER=1`, verified shell, automatic Phosh startup, visible lock screen,
tap-to-unlock Home, and the Settings category list. The visible counter reached
3.476 billion native instructions with zero fallbacks; stderr confirmed Metal API
validation was active and contained no assertion. This is correctness validation,
not a claim of improved app-launch time.

## Text Editor Keyboard Follow-Up (2026-10-31)

Guest Squeekboard testing now has separate GTK insertion and frame-cycle probes.
See [the Text Editor input profile](gtk-input-latency-profile.md) for measurements,
startup-stage observations, the rejected GTK 4 animation experiment, and
reproduction instructions. These probes are opt-in and are not shipped in the
normal image. No keyboard-latency speedup is claimed by this diagnostic change.
