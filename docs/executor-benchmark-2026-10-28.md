# Simulator Executor Benchmark

Measured October 28-29, 2026. No runtime code or guest packages changed for this
comparison. This is an Apple M2 / iOS Simulator measurement, not an iPhone result.

## Method

- One existing Release executable; SHA-256
  `472c8e58be88bba2bab71232a5f9b039654c7bffec2ba25b4fad912a8f060346`.
- Same iPhone 17 Simulator model and iOS 26.2 runtime, on macOS 26.5.1.
- Host has 24 GiB RAM. Background user apps were not closed. A later memory
  query reported 39% system-wide memory free and about 14 GiB allocated swap;
  two sampled swap-out counters were unchanged. Allocated swap alone is not
  evidence of active thrashing. Thermal state and other apps are uncontrolled.
- Dedicated disposable device `BDCD90C2-5EED-4863-8084-3FE01A664BC2`.
  The original Simulator was stopped to avoid competing VM load; its disk was
  not overwritten. A stopped-VM disk clone supplied the common seed.
- Seed SHA-256
  `29c74d26c3128d8954f52066011f09e9ddb4ee0660587ba70f53456da9d09664`.
- Bundled kernel SHA-256
  `db28ef894923d5b707f448a1f2695dd8f5ee148034ee333a65825613a8ff8933`.
- Two parallel vCPUs in every run. Same graphics, scheduler, guest image,
  interaction tracing, and auto-start command. Both vCPUs use the selected mode.
- Restore and hash-check the seed before every boot. No host page-cache flush;
  unrelated host apps remain running. These are cold guest-process boots with
  matching persistent state, not cold host-disk measurements.
- Nine trials in order: established, register-threaded, threaded-memory,
  register-threaded, threaded-memory, established, threaded-memory, established,
  register-threaded. No compilation or microbenchmarks during timed boots.
- Sample process CPU time/RSS about once per second; save readiness metrics and
  a screenshot, then collect another 15 seconds of idle samples. Peak RSS below
  includes that idle interval and is not physical footprint or guest RAM size.
- Readiness is `interactiveWorkloadReady` relative to `guestExecutionStarted`.
  A screenshot at that marker verifies a lock screen is present; it does not
  locate the earliest lock-screen pixel. `firstVisibleFrame` is not a Phosh
  readiness metric: it can describe early output unrelated to the lock screen.

## Boot Results

| Executor | Flags (prototype, memory) | Readiness trials (s) | Median (s) | Median host CPU time to observed ready (s) | Median peak RSS (MiB) |
| --- | --- | --- | --- | --- | --- |
| Established C | 0, 0 | 63.438, 57.273, 62.293 | 62.293 | 65.26 | 831.9 |
| Register-threaded | 1, 0 | 65.598, 72.824, 68.984 | 68.984 | 67.65 | 732.8 |
| Threaded scalar memory | 1, 1 | 81.697, 76.897, 78.021 | 78.021 | 72.94 | 812.4 |

Relative to established C, median readiness takes 10.7% longer with the
register prototype and 25.2% longer with threaded scalar memory. CPU time to
the polling observation is approximate, not sampled at the exact guest marker.
Three trials give a useful local comparison, not a statistically robust p95 or
a universal ranking. RSS ranges overlap; do not infer a memory reduction from
these medians alone.

Only about 1.9% of primary steps used the register prototype in these boot
snapshots; enabling scalar memory raised that to roughly 7.9-9.4%. These are
hybrid eligibility modes, not replacement of all native instruction handlers.
Ineligible blocks still use the established C executor, not Swift fallback.

All nine readiness milestones have zero fallback steps on both vCPUs.

## Instruction Accounting

| Executor | Primary billions, by trial | Secondary billions, by trial | Combined billions, by trial |
| --- | --- | --- | --- |
| Established C | 1.379, 0.807, 1.355 | 1.420, 1.988, 1.424 | 2.799, 2.795, 2.779 |
| Register-threaded | 1.236, 2.033, 1.598 | 1.534, 0.765, 1.176 | 2.770, 2.798, 2.774 |
| Threaded scalar memory | 2.039, 1.929, 1.993 | 0.673, 0.829, 0.773 | 2.712, 2.759, 2.766 |

The UI badge is the primary vCPU counter. The approximately twofold badge
variation is reproduced within established C itself, while combined work stays
near 2.8B. It is not evidence that threaded dispatch halves total guest work.
These runs show substantial variation in work distribution between CPUs.

Both paths feed `block_result.steps` into the same native chain/checkpoint
accounting. The established executor also accounts equivalent guest steps for
semantic loop accelerators. Swift checkpoint accounting additionally counts a
translation fault attempt; the badge is therefore not a strict hardware PMU
retired-instruction counter. Source inspection does not prove every possible
accounting edge case correct.

`ParallelVCPUClock` supplies a shared host-time-based 24 MHz counter. Guest
timing, scheduling and waits are not deterministic functions of instruction
count. Instructions per second alone are consequently not an end-to-end
responsiveness measurement.

## Interaction Measurements

Interaction trials are recorded separately from the boot series. They use
ordinary Simulator pointer input, not injected guest shortcuts. Recorded video
and screenshots distinguish Home/application content from splash screens.
The sample is exploratory, not an input-latency p95 benchmark.

| Executor | Settings launch marker to presented surface (s) | Approximate tap to first Home content (s) |
| --- | --- | --- |
| Established C | 32.675 | about 3 |
| Register-threaded | 29.969 | about 3 |
| Threaded scalar memory | 36.097 | about 3 |

Each row is one interaction trial, not a median. Settings content was visually
verified, not just its launch spinner. Home's first content is not the same as
its final navigation/dock layout becoming stable. All modes unlocked and
rendered Settings without visible instruction fallback. No statistically
defensible touch-latency winner follows from this sample.

For unlock, screenshots had uneven observation intervals, so recorded video
was inspected instead. The first transition from black to Home in a fixed
upper-content crop occurred at video PTS 16.870 (established), 13.7483
(register-threaded), and 15.2567 (threaded-memory). Aligning the movie creation
timestamp with the pointer-call timestamp gives approximate delays of 2.68,
3.05 and 2.74 seconds. Movie creation metadata is second-resolution and is not
a synchronized input/frame trace: allow at least roughly one second of timing
uncertainty, and do not rank these small differences. Videos and crop-luminance
logs are retained under `ui-*/`.

Additional UI-setup boots took 69.303 seconds (established) and 76.201 seconds
(threaded memory). They are recorded separately from the predeclared balanced
nine-boot series, not silently pooled or discarded. Register-threaded UI used
the last run of that series.

## Isolated Execution Loops

VM stopped; host-native C harness rebuilt at `-O3`. Nine alternating samples
per variant, one million guest instructions per sample, with result-state and
step-count assertions. These are synthetic loops, not Firefox speedups.

| Workload | Established median (ms) | Register prototype median (ms) | Threaded-memory median (ms) |
| --- | --- | --- | --- |
| Load/add/store/branch | 8.019 | 8.020 | 20.433 |
| Register arithmetic/branch | 5.410 | 16.290 | Same register handler path; not separately sampled |

The memory workload stays on the established executor when memory eligibility
is disabled, explaining the nearly identical first two values. Enabling
threaded memory takes 2.55 times as long. The register-only prototype takes
3.01 times as long on the arithmetic loop. All variants assert one million
steps and matching expected architectural results; no factor-of-two counter
discrepancy appears in these loops. This is not exhaustive proof of accounting
for every accelerator or exception path.

Post-Settings commit-to-present p50/p95 snapshots were 12.37/22.52 ms
(established), 12.52/26.22 ms (register-threaded), and 11.41/23.91 ms
(threaded-memory). Those samples mix boot/launch/idle frames and exclude the
guest work before commit. They are neither touch-to-frame latency nor a
steady-animation FPS measurement.

The established executor already uses computed-goto dispatch and semantic
fast paths. The prototype is a separate guaranteed-tail-call handler design,
not the first threaded execution mechanism in the project.

## Firefox

The initial desktop-icon test with the copied user profile reached a Firefox
crash-recovery dialog rather than a browser window. It was not counted as a
successful startup, and Troubleshoot Mode was not enabled. The interrupted
profile is left untouched in the user's original disk.

Controlled browser trials use a fresh `/tmp` profile, bundled `user.js`, the
complete Phosh process environment, normal sandboxing and software WebRender,
and a local HTML fixture. This removes the target document download and
session-recovery timing.
The target document is local, but Firefox still opened its default first-run
Mozilla privacy tab; this is not a network-isolated browser workload.
One initial shell-launch setup was aborted because it copied only part of the
session environment; it is excluded explicitly, with its raw directory kept.
One scalar-memory setup was also aborted before any browser result because it
remained locked substantially longer than the other configurations. The
replacement trial uses matched unlock timing (roughly 35-41 seconds after the
browser-start marker) and a longer harness safety timeout. These are not
discarded successful or failed browser outcomes.

| Executor | Approximate start marker to local page (s) | Test button result | Sampled peak RSS (MiB) |
| --- | --- | --- | --- |
| Established C | 228 | No visible response within 88.7 s | 1150.9 |
| Register-threaded | 251 | No visible response within 93.5 s | 1166.1 |
| Threaded scalar memory | 316 | No visible response within 101.0 s | 1495.2 |

One browser trial per mode: these are exploratory observations, not medians.
Rendering the fixture is not equivalent to an interactive browser. The expected
button result was a change from `Local page ready` to `Tap received`; none
showed that change during its observation window. These are failed response
checks, not measured successful input latencies. Established C also showed no
visible URL-bar focus or keyboard within 40.2 seconds of a separate tap.
There was no visible instruction fallback in these observations. Host input
injection telemetry does not prove that Firefox received or handled an event.
Tracing the event through guest input, Wayland and Firefox remains necessary.

The page timing comes from recorded video, not the later live screenshot:

| Executor | Movie creation UTC (2026-10-29) | First fixture frame PTS (s) | Browser marker Unix seconds |
| --- | --- | --- | --- |
| Established C | 03:41:04 | 11.645 | 1793245047.3592691 |
| Register-threaded | 03:48:22 | 207.378 | 1793245658.137192 |
| Threaded scalar memory | 04:02:46 | 267.117 | 1793246517.476049 |

A fixed document crop changes from blank white to fixture text at those frames;
nearby extracted frames were visually checked for the heading, status, button
and input. Movie creation has second-level precision and the UART marker is
polled about once per second. Allow roughly two seconds of timing uncertainty;
do not treat the decimal PTS values as end-to-end timing precision.

The scalar-memory observer did not create its completion sentinel before the
600-second harness deadline, so that raw summary reports
`UI observation deadline expired`. Video establishes that the page had already
rendered. This was an observer-completion failure, not a VM crash or evidence
that rendering took more than 600 seconds. Live observation confirmed the page
at 536.5 seconds after the browser marker, followed by the input check above.
The raw failure is retained rather than rewritten as a clean harness pass.
RSS windows end at different observer-completion times (or the timeout), so
these peaks are descriptive, not a controlled memory-efficiency comparison.

## Conclusions and Next Work

1. Keep established C as the default. It wins this repeated boot comparison
   and both isolated executor loops. The prototype has not demonstrated a
   reliable UI advantage; the single Settings result is insufficient to claim
   one, and its memory path is materially slower in the synthetic workload.
2. Investigate prototype handler/dispatch overhead before expanding eligibility.
   Profile the repeatable arithmetic and memory loops, compare generated code,
   and isolate state traffic, tail-call overhead and memory callbacks. The
   timings establish a regression, not its precise cause.
3. Trace the failed Firefox input end to end before treating it as CPU latency:
   host injection, virtio delivery, guest consumption, Wayland dispatch,
   Firefox event handling and resulting damage. Keep the local fixture for a
   repeatable correctness test. More interpreter throughput alone is not yet
   shown to fix this failure.
4. Use combined vCPU work and wall time for comparisons. The primary-only badge
   does not support a claim that 875M versus 1.8B means half the work.

This pass covers repeated boot, CPU/RSS sampling, instruction accounting,
isolated execution loops, unlock, Settings launch and Firefox rendering/input.
It does not establish real-device performance, sustained animation FPS,
touch-latency percentiles, battery/thermal behavior, general network throughput
or long-running stability. No runtime code was changed to improve a result.

## Evidence and Reproduction

Runner: `scripts/benchmark-simulator-executors.py`.

Raw artifacts: `/tmp/pinecone-executor-benchmark-20261028/`.
`boot-trials/identity.json` records fixture identity; `summary.json` records
all runs. Each trial directory includes launch flags, CPU/RSS samples, UART,
metrics and its readiness screenshot. No large disk images are added to git.

Use the runner only with a disposable Simulator: it replaces that app's disk
with the explicitly supplied seed before every run. The last process remains
running for semantic UI verification.

## Restored State

The disposable benchmark Simulator is shut down. The original
`541E22EE-C52B-4478-A041-56FEDC23ACFF` is running again with two parallel vCPUs,
`PINECONE_THREADED_PROTOTYPE=0` and `PINECONE_THREADED_MEMORY=0`. Its original
disk was not replaced. Phosh's lock screen was visually verified, and both
vCPU readiness counters report zero fallback. This restoration boot reported
104.100 seconds to readiness; it used the original disk and overlapped host
video analysis, so it is not part of the controlled nine-boot comparison.

Only this report and `scripts/benchmark-simulator-executors.py` were added for
the benchmark. Existing runtime edits in the worktree were preserved.
Runner argument parsing and `git diff --check` pass; the two native loop
harnesses also completed with their result/step assertions enabled.
