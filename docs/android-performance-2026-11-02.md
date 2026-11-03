# Android performance investigation — 2026-11-02

## Controlled executor comparison

Five 45-second Android boot-prefix trials used the same cloned system and
userdata images, four vCPUs, 2 GiB guest RAM, and the same native VirGL/Metal
renderer. The simulator VM was stopped during the measurements. These are
aggregate guest instructions across the vCPUs, not launcher boot times.

| Executor | Aggregate MIPS |
| --- | ---: |
| Assembly prototype | 58.498 |
| Established C interpreter | 61.367 |
| Assembly with chaining | 48.896 |
| Assembly with bounded chaining | 50.089 |
| Assembly prototype, repeat | 58.507 |

Chaining remains disabled. Enabling an experimental executor does not establish
a performance benefit; the established C interpreter was fastest in this test.

Subsequent user-requested configuration: assembly is now the default in iOS
builds, including simulator and standalone physical-device launches. Native C
fallback remains available for unsupported blocks; chaining and bounded
chaining remain off. `PINECONE_ASSEMBLY_EXECUTOR=0` restores C execution. The
macOS CLI keeps C as its default. This selection is compiled into the app and
is not a live debugger setting or a claim of a measured assembly speedup.
Validation for this default: the 780-test suite passed with assembly enabled
(two expected skips), the explicit C opt-out test passed, the release simulator
build succeeded, and the precompiled assembly handlers and adapter compiled
for the physical-device ARM64 target. The new app build is prepared but has
not replaced the currently running simulator app.

A later ThinLTO experiment measured 63.016 MIPS for the current C executor,
63.271 MIPS with ThinLTO, and 50.693 MIPS for the repeated C control. That
variation prevents attributing a useful gain to LTO; no LTO build flags were
added. Boot-prefix throughput varies with host conditions and the guest's SMP
startup workload. These samples do not replace matched completion milestones.

## Implemented changes

* Implement SHA256H, SHA256H2, SHA256SU0, and SHA256SU1 using host ARM64 SHA2
  intrinsics, with a portable implementation for other hosts. Advertise SHA256
  and the already implemented CRC32 guest instruction family. CRC32/CRC32C now
  use host ARM64 instructions. AES, SHA1, and SHA512 remain unadvertised.
* Let Android use larger boot slices while retaining native checkpoints,
  wall-clock budgets, and input preemption. Android never emits the Alpine
  shell prompt that previously selected interactive scheduling.
* Detect the actual launcher `Displayed com.android.launcher3/` log. Mark the
  interactive workload ready and change the shared guest counter from 6 MHz
  host ticks to the Android interactive default of 12 MHz. Architectural
  CNTFRQ stays 24 MHz. This reduces timer dilation from fourfold to twofold
  after launcher readiness. Reset restores the conservative boot clock;
  Alpine keeps its existing real-time behavior. The initial validation build
  used 24 MHz after launcher readiness; the default was subsequently adjusted
  to persist the live-tested 12 MHz setting.
* Extend the image preparation script with `--graphics-profile mesa`. The
  prepared image disables eager SurfaceFlinger shader prewarming while keeping
  rendering enabled. Required shaders compile on demand. The original disk is
  preserved under `Documents/LineageOS/Performance-baseline-system`.

The post-launcher clock increase can be disabled for comparison with
`PINECONE_ANDROID_REALTIME_UI=0`. Setting it to `1` explicitly selects full
real-time 24 MHz timing; leaving it unset selects the persistent 12 MHz default.
This is a host pacing change, not a change to the guest's advertised timer
frequency.

## Validation

780 Swift tests passed, with two expected skips. Guest SHA256 instruction
sequences produce the same digests as CryptoKit, including multi-block input.
Tests cover generic execution, threaded execution, assembly fallback, vector
register aliasing, and both CRC polynomials at all operand widths. The shared
clock tests check rate changes, monotonic epochs, and reset behavior.

`sh scripts/run-crypto-differential.sh` passed 200,000 randomized hardware versus
portable SHA256 cases under UndefinedBehaviorSanitizer, including aliases.
Release CLI and simulator builds succeeded.

Matched 180-second boot-prefix runs on unchanged cloned disks completed without
a guest execution error. The baseline executed 8,485,772,311 instructions; the
crypto candidate executed 8,255,085,283. Both reached Android userspace. This
does not establish a launcher boot-time speedup: the instruction mix changes
when guest software selects hardware crypto, and the last UART message is not
a controlled completion milestone.

The release build and on-demand shader image were installed in the simulator.
Android validation started with assembly, chaining, and bounded chaining off;
the native VirGL renderer selected ANGLE Metal successfully. Full boot-time
and touch-latency improvements still require measurement on this run. The
executor prefix measurements above must not be reported as a measured
improvement to Android launcher startup.

The installed simulator run recorded `firstVisibleFrame` at **658,884.897 ms
(10 min 58.9 s)**. Visual inspection confirmed the actual Android "Phone is
starting…" surface, not a generated boot screen. The earlier graphics bring-up
run took approximately 15.6 minutes to its first visible frame. This is an
observational comparison of different full builds/runs, not an isolated crypto
benchmark or a completed launcher startup measurement. Native execution at the
first frame: 5,868,442,507 primary instructions plus 21,498,601,747 secondary
instructions, with zero Swift fallback instructions.

Android reported Quickstep `Displayed` at **972,195.057 ms (16 min 12.2 s)**.
The shared clock changed to 24,000,000 host ticks/second, confirmed in both the
native log and performance JSON. This marker is the framework's report, not
proof that the visible home screen or its input response is ready. Subsequent
inspection found a black display and Android's launcher pause-for-sleep log.
The earlier host UI had no dedicated guest wake action. The follow-up host
change adds a `Wake guest` drawer action using Linux KEY_WAKEUP (143), plus
Android-only wake-key delivery at touch-down before touch injection.
The follow-up release build succeeded and was installed with userdata retained;
the simulator accessibility tree confirms the `Wake guest` control is present.

System UI still reported a startup ANR. Its diagnostic showed CPU pressure
`some avg10=74.27`, memory pressure zero, and I/O pressure `some avg10=0.10`.
This run does not support increasing RAM as the primary fix, or claiming that
startup ANRs are resolved. A post-clock-switch host sample remained dominated
by native interpretation and code/block translation/validation; native timer
advance was a small part of the flat profile. The captured frame pipeline had
17.9 ms median commit-to-present time and 35.4 ms P95, but guest presentation
interval P95 was 618.9 ms. Host presentation latency alone therefore does not
explain or establish guest UI responsiveness.

The wake-enabled follow-up run recorded first visible content at 717,809.916 ms
(11 min 57.8 s), and launcher `Displayed` at 1,094,816.692 ms (18 min 14.8 s).
This run included touches during startup and additional input-dispatch ANRs;
it is not an identical-workload startup comparison. The actual home screen and
an Android system ANR dialog were visually confirmed.

A debugger was attached at `ParallelVCPUCluster.configureRunBudget` and called
`self.setCounterTicksPerHostSecond(12000000)`, then detached. The current running
guest therefore uses **12 MHz**, while the installed binary's automatic
post-launcher target remains **24 MHz**. This live change is not persistent
across VM restart in that installed validation build. The user subsequently reported substantially better touch
responsiveness. Background services were also settling during this period, so
the clock change alone cannot be credited with that improvement.

Persistence follow-through: `LinuxGuestProfile` now supplies the 12 MHz
interactive default, and the host applies it on each launcher-ready event.
The clock reset test exercises the 12 MHz interactive setting, unchanged
architectural CNTFRQ, and restoration of the initial boot clock. Both focused
clock tests passed. The running guest is left undisturbed; using the new
default after a restart requires installing the rebuilt host app.

ANR diagnostics were read from a cloned userdata disk, never by repairing the
live guest disk. Dumps must be matched to the current UART's exact filename
and PID because the disk contains older runs with overlapping wall times.
The matched system-server PID 655 watchdog dump shows its main thread waiting
in `ActivityThread.acquireProvider`, reached through
`CertificateTransparencyDownloader → DownloadManager.enqueue`. Its `android.ui`
thread waits on DeviceIdleController while `appscheduling.default` holds the
DeviceIdleController and ActivityManagerService locks during broadcast queue
processing. These are concrete additional startup/lock-contention paths to
investigate; this evidence does not establish a GPU fence deadlock. Certificate
validation and update policy were not changed.
