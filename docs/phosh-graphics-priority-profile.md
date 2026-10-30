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
