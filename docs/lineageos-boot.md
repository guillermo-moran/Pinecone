# LineageOS Boot Bring-up

Pinecone has a direct-boot profile for LineageOS `virtio_arm64only`. With the
v2026.10.18 release artifacts it boots Linux 6.12.81, loads the Android vendor
and generic ramdisks plus bootconfig, mounts the dynamic system partitions,
activates bootstrap and main APEX packages, starts zygote and core Android
services, and continuously presents through VirtIO GPU. The LineageOS profile
exposes the modern VirtIO PCI transport required by the release kernel. The
boot console is visible, but the Lineage launcher has not appeared yet.

The target is LineageOS's generic VirtIO ARM64 device, not a build for a phone.
That target uses an ARM64 `Image`, PL011 `ttyAMA0`, and VirtIO devices and sets
`androidboot.hardware=virtio`, which closely matches Pinecone's virtual machine.

## iOS boot option

The iOS host now opens on a guest picker with **Alpine Linux** and
**Android (LineageOS)** options. Pinecone exposes its Documents directory in
Files and creates `Pinecone/LineageOS/README.txt` with the same placement
instructions.

Put these files in `On My iPhone/iPad/Pinecone/LineageOS`:

- `boot.img` (required);
- `vendor_boot.img` (required by the current release);
- `vda-unencrypted-preexpanded-complete-all-fontfix2-nobootanim.raw` (preferred),
  `vda-arm64viz.raw`, or `vda.raw`;
- `vdb-arm64viz.raw` (preferred clean writable userdata disk) or `vdb.raw`;
- `init_boot.img` only when using a build whose generic ramdisk is not present
  in `boot.img`.

Choose **Android (LineageOS)** to validate the Android boot image, extract its
kernel and ramdisk, compose `vendor_boot` and bootconfig, merge the embedded
command lines with Pinecone's LineageOS defaults, attach both raw disks, and
launch the VM. Missing or incompatible assets are reported on screen, with
controls to retry or return to the picker.

LineageOS defaults to four parallel software vCPUs. The iOS host now requests
2048 MiB in Simulator and 1024 MiB on device; the larger Simulator default is
still undergoing UI-boot validation.
Its shared architectural counter is adaptive: it advances at a dilated rate
during CPU0-only kernel initialization, then accelerates when PSCI brings the
secondary CPUs online. This prevents an overdue timer-interrupt loop from
starving early boot while preserving one monotonic clock across every vCPU.

Run `scripts/fetch-lineageos-arm64only.sh` on macOS to download the pinned
release, verify its checksums, convert its QCOW2 disks to sparse raw files, and
extract `vendor_boot.img` from the system disk. Then run
`LINEAGE_LPUNPACK=/path/to/lpunpack scripts/patch-lineageos-vendor-dlkm.sh`.
That creates `vda-arm64viz.raw`, preserving the downloaded disk, and removes
the optional `virt_wifi` module from the boot list. The workaround requires
`lpunpack` plus the `debugfs` and `e2fsck` tools from e2fsprogs.

Create a clean ext4 userdata disk with:

```sh
scripts/create-lineageos-userdata.sh
```

The launcher prefers the resulting `vdb-arm64viz.raw`. This matters for the
unencrypted fstab used by the arm64viz system image: the release's encrypted
userdata bytes do not mount as ext4, leaving Android's `/data` placeholder on
the read-only root filesystem and causing `init_user0` to fail.

Do not use the experimental `vda-arm64viz-vintf.raw` image. Its extra base
manifest declarations conflict with the vendor APEX fragments after activation
(`IMemtrack/default` is the first reported duplicate), invalidating the device
manifest. The host no longer selects that image. Keep the original APEX HAL
declarations and use clean, writable userdata instead.

For clock diagnostics, the CLI accepts `--smp-counter-hz 24000000` to test an
undilated clock after secondary CPU startup. This is an opt-in experiment;
the app's default remains 6000000 until a complete boot validates the change.
The advertised `CNTFRQ` remains 24000000, so this default advances Android's
clock at one-quarter wall speed after SMP starts. It stretches timed waits and
watchdogs; it does not make the interpreter execute instructions faster. In
the 1200-second 2 GiB probe, final `CNTVCT=0x1ac29ae85` corresponds to 299.3
guest seconds. Boot deadlines and comparisons must use host elapsed time,
not the timestamps printed by Android.
The matched `nopt-24mhz-300s` probe failed to reach Android userspace within
300,003 host milliseconds: CPU0 remained in timer/RCU softirq catch-up, with
only CPU1 brought online. IRQ27 acknowledgements and EOIs matched (103,713),
and final active/pending sets were empty; this was not an unacknowledged IRQ
wedge. Aggregate execution fell to about 1.85 million instructions/second,
versus about 39 million in the 6 MHz run. Keep the existing default; merely
accelerating the clock is not a validated boot-speed fix.

## Accepted boot inputs

The preferred input is an Android boot header v3 or v4 `boot.img` from a
`lineage_virtio_arm64only` build:

```sh
swift run -c release arm64viz prepare-lineageos out/target/product/virtio_arm64only/boot.img
```

The launcher extracts the kernel, ramdisk, and embedded kernel command line.
For Android 13 and later, the generic ramdisk can be in `init_boot.img`:

```sh
swift run -c release arm64viz prepare-lineageos \
  out/target/product/virtio_arm64only/boot.img \
  --init-boot out/target/product/virtio_arm64only/init_boot.img \
  --vendor-boot out/target/product/virtio_arm64only/vendor_boot.img
```

The pulled v2026.10.18 release can be exercised directly:

```sh
swift run -c release arm64viz run-lineageos-trace \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/boot.img \
  --vendor-boot artifacts/lineageos-virtio-arm64only-v2026.10.18/vendor_boot.img \
  --disk artifacts/lineageos-virtio-arm64only-v2026.10.18/vda-arm64viz.raw \
  --secondary-disk artifacts/lineageos-virtio-arm64only-v2026.10.18/vdb.raw \
  --memory-mib 1024 --vcpus 4 --max-steps 50000000000 --stop-on-display
```

An unpacked ARM64 `Image` and ramdisk work too. `--bootargs` replaces the
LineageOS profile defaults and command lines embedded in Android boot images.

## Current VM contract

The profile supplies:

- direct ARM64 Linux entry at EL1;
- four parallel vCPUs by default, with PSCI startup and a shared adaptive
  host-monotonic counter;
- a generated device tree in `x0`;
- PL011 console and `androidboot.console=ttyAMA0`;
- `androidboot.hardware=virtio`;
- GICv2, architectural timer, PSCI for multiple CPUs, a generic PCI ECAM host,
  and modern VirtIO PCI block, network, input, keyboard, and GPU functions;
- separate file-backed system and userdata images intended as `/dev/vda` and
  `/dev/vdb`.

The Android boot-image reader deliberately accepts only header versions 3 and
4. The vendor-boot reader accepts header versions 3 and 4 and assembles the
vendor ramdisk, generic ramdisk, and bootconfig trailer in the Android-defined
order. Older images and malformed or truncated payloads fail before VM state is
modified.

## Current bring-up boundary

The November 1 bounded probe with the original vendor manifest, writable ext4
userdata, serial-only console, and incremental UART matching stopped at
300,006 ms. It executed 423,654,752 primary and 10,041,680,498 secondary
instructions, reached Zygote startup and SurfaceFlinger graphics initialization,
and did not reach a launcher. There were no duplicate VINTF-manifest failures.
`bpfloader` consumed 24.781 guest seconds (about 99 host seconds at the current
clock rate). A separate 24 MHz clock probe produced kernel soft lockups and RCU
starvation, so the default rate was not increased. Raw logs and reports are in
`experiments/lineageos/2026-11-01/`. The provisioning userdata is incomplete;
it must not be published as a boot-completed seed.

- The v2026.10.18 guest discovers both disks, performs first-stage mounts from
  the super partition, activates APEX packages, and advances into Android's
  service startup. A 50-billion-step validation reaches zygote, netd, wificond,
  media, and audio service startup without an unsupported-instruction stop.
- The release kernel enables `CONFIG_VIRTIO_BLK` and `CONFIG_VIRTIO_PCI`, but
  not `CONFIG_VIRTIO_MMIO`. Its reference QEMU command attaches both disks with
  `virtio-blk-pci`. Pinecone now publishes six modern VirtIO PCI functions over
  a generated `pci-host-ecam-generic` node. Unit tests validate enumeration,
  BAR access, queue negotiation, notification, interrupt status, and a complete
  block descriptor request.
- The release kernel accepts the PCI device-tree handoff, enumerates the modern
  VirtIO devices, and completes real block I/O through the PCI transport.
- Dynamic/super partition mapping and Android first-stage mounts are validated.
  The pinned image's optional `virt_wifi.ko` currently faults, so the provided
  patch script creates a separate disk whose module list omits it.
- `--stop-on-display` ignores the DRM driver's initial blank scanout, halts on
  the first guest-transferred and flushed VirtIO GPU frame, and reports frame
  metadata and GPU counters. `--display-snapshot frame.ppm` saves the final
  framebuffer for visual validation. Long runs show the boot console and more
  than two thousand successful presentations; Android then clears the display
  while framework startup continues. The current `fontfix2-nobootanim` derived
  image disables the animation to reduce software-rendering work. Neither a
  kernel framebuffer nor a boot animation proves launcher readiness.
- DRM scanout and repeated framebuffer transfer/flush are validated. The next
  UI checkpoint is Android framework boot completion and a composed launcher.
- A source-level [lean LineageOS product](lean-lineageos-build.md) retains the
  complete Android UI and VirtIO path while removing optional phone hardware.
  For the pinned prebuilt image, use the checksum-guarded [inspection and
  patching workflow](lineageos-lean-image.md); arbitrary APK deletion is not a
  safe or effective way to shrink its fixed dynamic-partition extents.
- Android input, networking, audio, power, storage, and other required HALs need
  validation or implementation.
- Boot-completion probes must use an exact init action or Android event marker.
  Searching for `BOOT_COMPLETED` alone also matches the package permission
  `android.permission.RECEIVE_BOOT_COMPLETED` during scanning, before the
  framework or launcher is ready.
- A phone-specific LineageOS OTA depends on that phone's kernel, DTB, vendor
  ramdisk, firmware, and partition scheme and is not a compatible input.

## Framework watchdog investigation (November 1)

The simulator's userdata contains a watchdog report for system_server PID 657
at uptime 275,687 ms. Its WindowManager global lock was held by a Binder thread
waiting in `BpSurfaceComposer::captureLayersSync`, called by
`Transition::ScreenshotFreezer`. ActivityManager, the display thread, and the
main thread were blocked behind that lock. SystemUI also failed to complete
startup. The report is preserved in
`experiments/lineageos/2026-11-01/watchdog/system_server_watchdog.txt.gz`.
This is not a successful boot, nor proof of a specific GPU-device defect.

The experimental `scripts/prepare-lineageos-software-rendering.py SOURCE OUTPUT`
creates a new disk with `service.sf.prime_shader_cache=0` set during early init
only for `androidboot.graphics=mesa_swrast`. This tests whether speculative
shader compilation is occupying llvmpipe/RenderEngine and delaying captures.
Rendering and watchdogs remain enabled. The script preserves the source and
refuses to overwrite an existing output. Do not promote its image without a
successful boot/display test.

The first no-prewarm probe stopped at its 900,008 ms wall-clock limit. It reached
`Displayed ... FallbackHome`, enabled the screen at guest uptime 190,906 ms, and
entered framework boot phase 1000. No watchdog kill or emulator runtime error
was observed during that probe. This is not a matched-duration A/B result: the
baseline CLI probe was only 300 seconds, and the original watchdog report was
from a simulator run. The framebuffer remained entirely black despite 75 GPU
transfer/flush commands (73 unchanged flushes). User 0 had not yet completed
unlock, the actual launcher was not confirmed, and no exact `sys.boot_completed`
action was seen. Thus shader prewarming remains a candidate mitigation, not a
verified full fix. Logs, JSON counters, and the final framebuffer are saved
alongside the watchdog evidence. The experimental disks remain under
`/private/tmp/pinecone-no-prewarm-{system,userdata}.raw`; the simulator's original
disks were not replaced.

The black `FallbackHome` frame alone does not establish a readback defect.
[AOSP FallbackHome](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/src/com/android/settings/FallbackHome.java)
intentionally uses an all-black, navigation-hidden theme when
`Settings.Global.DEVICE_PROVISIONED` is zero, and waits for user unlock before
resolving the real home activity. The probe's saved settings have that value
set to zero and its log says `User not yet unlocked`. Verify the unlock/home
handoff, rather than interpreting `Displayed ... FallbackHome` as a launcher.
For independent pixel-path diagnosis, the CLI now accepts
`--display-backing-snapshot guest-frame.ppm` alongside
`--display-snapshot frame.ppm`. The former reads the active scanout directly
from guest RAM; the latter captures the committed frame used by the display.
These are diagnostic snapshots, not substitutes for a visible guest UI.

A follow-up run with cloned prepared userdata reached full user unlock at
guest uptime approximately 256 seconds. `FallbackHome` reported that a real
home was found; Android started Lineage SetupWizard, its Bluetooth setup
activity, and Launcher3's Quickstep background service. This did **not** prove
a visible launcher: at the 1,200,029 ms wall-clock cutoff the committed frame
was still entirely black, generation 8, with 90 transfers/flushes and 88
unchanged flushes. There was no emulator runtime error. Window transaction
commit callbacks timed out, and the saved watchdog report identifies the
`android.ui` handler blocked for 60 guest seconds. Its system_server Java stack
dump failed, leaving kernel wait-channel data; it does not establish a specific
SurfaceFlinger lock owner. The new evidence is saved as `no-prewarm-1200s.*`
and `no-prewarm-1200s-ui-watchdog.txt` alongside the previous probe.
Therefore user unlock is no longer the only blocker, and disabling eager shader
prewarming is **not a verified black-screen fix**. This candidate remains
separate from the simulator's installed system image.

The controlled 2 GiB follow-up also ended with black pixels in both independent
guest-backing and committed-frame captures. It eliminated the observed LMKD
kills but did not eliminate SystemUI's startup timeout. Its complete native
thread dump (`no-prewarm-2gb-renderthread.txt`) provides a narrower blocker:
`android.ui` waits in `RenderProxy::setStopped`, while RenderThread is runnable
inside the Mesa/LLVM shader compiler beneath `GrOpFlushState` and Skia flush.
That thread had consumed about 22.5 guest CPU seconds; llvmpipe raster workers
were sleeping. Disassembly of the shipped Gallium library identifies compiler
IR/value-graph analysis, not a pixel loop. This supports expensive synchronous
shader compilation, not proof of an infinite optimizer loop.

The image builder's opt-in `--disable-llvm-optimizations` additionally exports
`GALLIVM_PERF=nopt` during early init for the `mesa_swrast` profile. Both the
shipped Mesa binary and upstream Gallivm recognize this flag. It trades generated
shader performance for reduced compilation work, leaving rendering enabled.
The controlled 2 GiB run with this option ended at 1,200,005 host milliseconds
with no emulator runtime error, but both raw backing and committed pixels were
still black (generation 8; 97 transfers/flushes, 95 unchanged flushes). It is
therefore **not a verified launcher fix**. Evidence is saved as
`nopt-2gb-1200s.{json,uart}` in the watchdog directory. Its SystemUI startup ANR
captures a separate transient `UserRepositoryImpl` constructor/settings wait,
with an idle RenderThread; this different process's trace does not prove the
earlier system_server shader-compilation stall has cleared.
An independent `--force-softpipe` option selects Mesa's non-LLVM software
rasterizer with `GALLIUM_DRIVER=softpipe`. It cannot be combined with
`--disable-llvm-optimizations`. A boot probe confirmed SurfaceFlinger reports
`renderer: softpipe`, but it then aborted on the first Android window buffer
import: `Could not create EGL image, err = (0x3000)` followed by `Failed to
create a valid texture` for a 480x1024 format-1 buffer. The failed probe was
stopped, with UART evidence in `softpipe-egl-import-failure.uart`. This option
is retained only to reproduce that failure; do not install/promote it as a UI
fix. The default renderer remains unchanged.
`--display-snapshot-interval-ms 10000` now refreshes supplied committed/backing
snapshot paths during a CLI boot, so diagnosis no longer requires stopping it.
When `PINECONE_HOT_PC_PROFILE=1` is set, trace JSON now includes
`secondaryHotPCs` as well as `primaryHotPCs`. Performance conclusions about an
SMP boot must consider all vCPUs, rather than treating CPU 0 samples as the
whole workload. Profiling remains disabled by default.

Simulator builds now save the complete console to `Library/Caches/pinecone-uart.log`
by default, resetting it on each boot. Set `PINECONE_SIMULATOR_DUMP_UART=0` to
disable this for performance comparisons. Previously that file was only updated
with an explicit environment flag, so its existence did not mean it was current.

## First-frame resource tracing and scanout correction

The installed simulator subsequently displayed the real LineageOS welcome
screen and a SystemUI ANR dialog. That verifies visible guest composition and
host presentation, but responsiveness and launcher startup remain unresolved.
A later vCPU 1 stop identified `0x6e21d421` at `0x776014f2c4`, vector
`faddp v1.4s, v1.4s, v1.4s`. The native decoder/executor now handles vector
FADDP in 2S, 4S, and 2D arrangements, preserving source operands when registers
alias and clearing the upper half for 2S. Focused regressions reproduce the
exact failure and cover distinct/overlapping registers and reserved 1D
rejection. This removes that instruction-coverage blocker; it does not resolve
the observed Android startup timeouts.

A subsequent lock-screen boot stopped vCPU 2 on `0x6e7fb795` at
`0x7080563264`, `sqrdmulh v21.8h, v28.8h, v31.8h`. Native execution now
supports scalar/vector SQDMULH and SQRDMULH for signed 16/32-bit lanes,
including rounding, saturation, sticky FPSR.QC and source/destination aliasing.
The saturating corner `INT_MIN * INT_MIN` uses a non-overflowing intermediate.
Narrow results clear unused lanes; reserved 8/64-bit encodings are rejected.
The reported lock-screen milestone and service timeouts remain separate from
this instruction-coverage fix.

The CLI's opt-in `--display-resource-diagnostics PATH` writes atomic JSON with
host elapsed milliseconds, active and committed scanout resource IDs, and
exact nonblack-RGB pixel counts for each live resource's host storage and guest
backing. Alpha-only pixels are not counted as visible color. Missing backing
or a failed read is reported explicitly, not interpreted as black. Combine
with `--display-snapshot-interval-ms 10000` for periodic snapshots; otherwise
only the final snapshot is written. No resource scans run without this flag.
Guest writes can continue while the diagnostic reads memory, so this is not
an atomic snapshot of all vCPUs. Existing backing-image capture refers to the
currently selected scanout; the separate IDs expose when that differs from
the committed display.

A regression test found a generic GPU publication defect: publish buffer B,
publish buffer A at the same rectangle, then select and flush B again without
another transfer. The old rectangle-only comparison left A visible rather
than publishing B. `flushResource` now compares the whole scanout, including
resource identity, and republishes the selected buffer. The regression failed
before this change and passes with it, including preservation of an existing
frame lease. This is a verified device bug fix, not yet proof of the Android
black-screen cause.
Two additional regressions cover a partial flush on first publication and
after switching resources. Full-frame rebuilds previously cleared the display
and copied only the flush intersection, inventing black pixels outside it.
They now copy the whole selected scanout; incremental same-scanout flushes
remain unchanged. Both tests failed before the correction and pass afterward.
The full suite passes 750 tests, including a two-VM guest JIT-publication
sequence (`STR`, cache maintenance, barriers, and peer execution) that found
no stale-code-cache failure.

For paired guest stacks, `prepare-lineageos-focused-native-stacks.py` accepts
repeated `--target`, `--samples` (1–3), and `--sample-interval-seconds`. Explicit
framework/compositor targets are captured first. It logs sample markers,
renderer environment variables, executable mappings, and bounded debuggerd
backtraces under the existing dumpstate policy; it does not relax SELinux.

Host samples from the two-scanout-fix diagnostic run show approximately one
busy host core during both early boot and framework startup; other guest
vCPUs mostly wait idle. Mutex contention was small (approximately 0.6% and
1.4% of active samples respectively), so additional vCPUs or display-lock
changes are not supported as fixes for those phases. One concrete cost was
isolated `DC ZVA` instructions entering Swift `fillRAM`, allocating temporary
mapping and pattern arrays for each cache block. Instruction-mapping and
code-generation validation also remained visible in both profiles. These are
host execution-cost observations, not proof of an Android rendering failure
or an end-to-end speedup.

## Android graphics bridge bring-up status

`scripts/android-graphics/` contains a portable layer encoder for the same
PN2D v3 commands used by Alpine's Pixman bridge. A C-to-host compatibility
test verifies scaled, plane-alpha composition through `VirtIOGPUDevice`.
This is preparation for an Android composer backend, not a loaded HAL.
Android still uses Mesa/llvmpipe. The directory README documents the required
virtio kernel patch, gralloc imports, validation, fences and build integration.
The existing host Metal backend separately passes 3,528 Pixman differential
cases in each direct-memory and simulator-copy configuration on the Mac.
Those checks do not prove Android submits Metal work.

Android already accepts the shared VirtIO touchscreen as a 480x1024 DIRECT
touchscreen on display 0. Input uses UIKit, the host queue, VirtIO and Linux
evdev; Metal displays resulting frames. No additional Metal touch transport is
needed. Only one contact is currently exposed. Host input injection and frame
completion are not sufficient to infer guest input-to-frame causality.

The latest startup ANR for SystemUI PID 909 sampled its main thread runnable
inside keyguard coroutine initialization, with 7.47 guest CPU seconds and
13.54 seconds of run-queue delay. Its RenderThread was idle. The same process
later logged completion of its core startables. This is distinct from an
earlier PID 912 settings-initialization wait and SetupWizard PID 1381's
RenderProxy wait on a runnable Mesa/LLVM RenderThread. Do not describe all
three samples as one shader deadlock.

The isolated DC ZVA RAM fast path now has explicit native-hit regressions for
both untranslated and MMU-enabled EL1 memory, alongside fault tests. A live
simulator host profile no longer contains Swift `fillRAM` in that window.
Decoding, block-cache lookup, mapping validation and instruction translation
remain prominent. Per-vCPU miss/invalidation measurements are needed before
changing cache capacity or coherency semantics. The complete core suite passes
758 tests; these findings do not establish an ANR fix or boot-speed gain.

## Upstream references

- [LineageOS QEMU release used for bring-up](https://github.com/jqssun/android-lineage-qemu/releases/tag/v2026.10.18)
- [LineageOS `virtio_arm64` device tree](https://github.com/LineageOS/android_device_virt_virtio_arm64)
- [LineageOS VirtIO common device tree](https://github.com/LineageOS/android_device_virt_virtio-common)
- [AOSP generic boot partition](https://source.android.com/docs/core/architecture/partitions/generic-boot)
- [AOSP boot image header](https://source.android.com/docs/core/architecture/bootloader/boot-image-header)
- [AOSP vendor boot partition](https://source.android.com/docs/core/architecture/partitions/vendor-boot-partitions)
