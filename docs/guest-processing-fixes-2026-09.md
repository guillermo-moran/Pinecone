# Guest processing and wakeup fixes

## Findings and changes

- Matching Alpine debug symbols (build ID
  `f4b8265ced44d530f36ff6309f63343318fc11bd`) identify the sampled libgio
  addresses at `0x154850` and `0x154870` as
  `cache_magic_matchlet_compare_to_data`, inlined into
  `cache_magic_matchlet_compare`. This replaces the earlier tentative attribution.
- The unmasked MIME matcher called `memcmp` at every candidate offset. The
  guest GLib patch uses bounded `memchr` candidate discovery, then compares the
  remaining bytes only for viable candidates. Masked matching remains exact.
  Offset/range arithmetic is checked before reading cache or input bytes.
- A native GLib loop shortcut assumed that an arbitrary `BL` meant `memcmp`,
  skipped the actual callee, and assigned estimated instruction counts. A negative
  test replacing the callee with an always-unequal function reproduced an incorrect
  match. The shortcut is removed; ordinary native C execution handles those guest
  instructions. The guest source optimization replaces it without Swift fallback.
- A secondary vCPU could miss a notification delivered between publishing its
  WFI state and entering its condition wait. The wait now returns immediately
  for an already-pending interrupt, even without an armed timer. Interrupt wake
  callbacks run outside the controller lock, avoiding controller/scheduler lock
  inversion. Enabling, retargeting and completing active-but-pending interrupts
  also signals the scheduler, including globally enabling a targeted interrupt.
- The primary runner now uses its current multi-vCPU WFI lifecycle when deciding
  to sleep, not whether WFI occurred at any earlier point in the execution slice.
- Touch scheduling priority renews on new motion. Expiring the scheduling boost
  no longer destroys the outstanding response measurement. Samples remain temporal
  input-to-next-frame observations, not causal proof: a no-op tap followed by a
  much later independent frame can still produce a large value.
- Unexpected backend stops write `Library/Caches/pinecone-last-stop.json` even
  with profiling disabled. This is a failure-only write, not per-slice telemetry.

## Reproducible guest build

`scripts/alpine/glib` retains Alpine's GLib 2.88.3 packaging and patches from
aports commit `11bd4e3a5442ee6c0156c1a9fd290fb49b2f561a`, with the Pinecone MIME
patch and package revision r1. Release tarball and patch hashes are in APKBUILD.
Upstream source: https://download.gnome.org/sources/glib/2.88/glib-2.88.3.tar.xz

```sh
bash scripts/build-pinecone-glib.sh
ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_INDEX=1 \
ARM64VIZ_REUSE_GRAPHICAL_PACKAGE_SELECTION=1 \
PINECONE_REUSE_PIXMAN_LIBRARY=1 \
PINECONE_CACHE_LIMA_INSTANCE=pinecone-builder \
bash scripts/build-arm64-rootfs-image.sh
```

The staging script requires the tested package by default. The diagnostic
`PINECONE_USE_PATCHED_GLIB=0` option selects upstream GLib without changing the
native-only interpreter policy. Build artifacts are generated, not source files
to commit. No changes were made to the Metal blend implementation in this pass.

## Verification

- 502 Swift tests pass, including comparator interposition, pending interrupt
  waits without timers, interrupt callback lock ownership, enable/retarget/EOI wakes,
  and retention of long response samples.
- GLib upstream suite: 373 passed, 8 skipped, 0 failed.
- 100,000 differential MIME cases pass on macOS and native Alpine/aarch64.
  The test includes the actual patched source and covers masks, zero lengths,
  large ranges, malformed offsets, and a guard page immediately after input.
- The MIME test also passes AddressSanitizer/UBSan using Homebrew LLVM with an
  explicit macOS SDK. Xcode's ASan runtime deadlocked during initialization;
  those two processes were sampled and stopped, not counted as passing runs.
- The generated pristine root image passes read-only `e2fsck -fn`.
- C Pixman ownership/fence regressions pass again after the runtime changes.

## Initial measurements

The dedicated Simulator is `541E22EE-C52B-4478-A041-56FEDC23ACFF`, with two native
vCPUs. Original Simulator/device data was not modified. Test disks and the
baseline pristine image were preserved under `/tmp/pinecone-mime-*.ext4` before
reseeding. Both runs below used pristine images and the same lightweight tracing
settings, but are single runs with different scheduling and manual unlock timing.

| Measurement | Upstream GLib | Patched GLib, before wakeup fixes |
| --- | ---: | ---: |
| Shell prompt | 2.37 s | 2.37 s |
| Phosh readiness marker | 74.59 s | 51.36 s |
| Settings request to focused surface | 33.19 s | 28.85 s |

These do not establish a p95 improvement or native-like performance. Slow
responses that previously disappeared at watchdog expiry are now visible, so
old and new latency percentiles are not directly comparable. Automatic unlock
can arrive before the lock screen is ready; readiness markers alone do not
prove visual unlock.

Evidence: `/tmp/pinecone-mime-controlled-before.json`,
`/tmp/pinecone-mime-controlled-after.json`, and associated UART logs. The final
wakeup build is measured separately in `/tmp/pinecone-wake-after.json`.

### Measured wakeup build

The measured wakeup build reached the shell in 2.43 s, the Phosh readiness marker in
62.05 s, and a focused Settings surface 28.81 s after its launch request.
Visual verification covered unlock, two Settings launches and closes, category
navigation, Displays, search/guest keyboard, and the home-screen app filter.
The app is left running and unlocked in the dedicated Simulator.

Ten completed temporal interaction samples have total p50 1184 ms and p95
7362 ms. Queue-to-device p95 is 1.89 ms; commit-to-publication p95 is 0.14 ms;
publication-to-presentation p95 is 23.41 ms. Slow guest-side responses remain.
These samples include startup and different UI operations, and the watchdog
censoring fix changes the sample population. They are not evidence of a p95
speedup over the earlier report.

No unsupported instruction, native fallback, GPU synchronization failure,
framebuffer copy-on-write, or guest ext4 error was observed in the measured run.
This is a functional regression pass, not a completed responsiveness sign-off.
Capture: `/tmp/pinecone-wake-final-capture.json`; analysis:
`/tmp/pinecone-wake-final-analysis.json`; console:
`/tmp/pinecone-wake-final-uart.log`; screenshot:
`/tmp/pinecone-wake-final-home.png`.

### Final normal-mode verification

After the measurement capture, the pending-interrupt wake handling was extended
to global enable and end-of-interrupt completion. The complete 502-test suite
passed, and the Release app was rebuilt and installed in the dedicated Simulator.
With profiling disabled, two native vCPUs mounted persistent root, reached the
shell, auto-started Phosh, and visibly unlocked to the home screen. The counter
showed 2.45 billion native instructions and zero fallback instructions. The UART
log reached `Phosh ready after guest initialization` without an error. The app
is left running and unlocked. This final revision has no new timing capture;
the numerical results above belong to the preceding measured revision.

## Still unresolved

The earlier unexpected VM stop and guest ext4 buddy/bitmap warning have not been
reproduced or causally explained. No claim is made that the MIME or wakeup fixes
resolve them. A stopped, previously mounted test disk showed stale aggregate
free-count summaries even after journal-only replay on a disposable clone;
that is not the same observation as the earlier guest buddy/bitmap warning.
Original disks were not repaired. Failure reports and preserved images remain
available for further diagnosis.
