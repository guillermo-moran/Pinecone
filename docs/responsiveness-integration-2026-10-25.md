# Responsiveness integration: October 25, 2026

Nine dedicated agents implemented the nine audit items. The parent reviewed,
integrated, and built their changes. Concurrency was limited to six agents, so
three owners started after earlier owners finished. No interpreter fallback,
vCPU count, safety policy, or physical-phone configuration was changed.

## Implemented work

1. **Pixman ownership and batching.** Lifetime-bound renderer leases replace
   whole-pass CPU access for compositor-owned buffers. Unknown client aliases
   remain hazards; retained immutable source/mask snapshots allow batching.
   Escaped-address tracking is bounded to 4,096 coalesced intervals (64 KiB).
   Saturation fails closed and disables trusted external-buffer batching until
   process restart rather than forgetting alias history.
2. **Phoc layout transactions.** Completion matches surface, configure identity,
   and exact serial. Timeouts, replacement, wrap, unmap and destruction cannot
   consume another surface's acknowledgment. Existing deadlines remain intact.
3. **DMA-BUF import.** The Pixman renderer advertises only validated linear,
   single-plane supported formats. Device probing, mapping, bounded readiness,
   CPU access synchronization and backing lifetime are explicit. Imported
   sources still use snapshots/uploads; this is not end-to-end zero-copy.
4. **GPU lock scope.** Bulk copy, raster and scan work release the metadata lock.
   A separate execution gate and retained resources protect commands while
   display readers use immutable published frame/cursor leases.
5. **GPU scheduling.** Shared reads can overlap; RAW/WAR/WAW and lifecycle
   barriers remain ordered. Lookahead is bounded to 32 commands/1 MiB and three
   executing submissions. Guest fence responses retire in virtqueue order.
6. **Touch timing.** UIKit capture times and gesture boundaries survive bounded
   queues. A gated Pinecone v2 Linux input extension maps each gesture's capture
   clock to CLOCK_MONOTONIC and sets actual evdev timestamps. It does not confuse
   MSC_TIMESTAMP events with evdev timestamps. Before device enqueue, a backed-up
   host queue retains the two newest motion samples per gesture plus phase edges
   and a distinct final position. Device queues retain their original ordinal
   semantics; already-delivered or partially delivered frames are not compacted.
7. **Application scheduling.** Phosh emits bounded, tracing-independent launch
   lifecycle records. Token-scoped failure/cancellation and alias matching
   replace Settings-only scheduling. Boost lasts at most 12 seconds by default,
   capped at 15; it is not a launch-success deadline. Lifecycle tracking survives
   for up to 120 seconds without extending the boost, so a slow cold launch still
   reports presentation or failure. Presentation markers are still app-ID based,
   not per-window identities.
8. **Legacy touch routing.** Linux no longer duplicates input into an unread
   legacy MMIO queue. Generic MMIO input remains supported and bounded, retaining
   accepted gesture termination and its existing ACK/latch protocol.
9. **Presentation.** One display-refresh pacing point acquires the newest frame.
   Bounded off-main staging avoids uploads for every metadata notification.
   Acquired work makes progress during continuous arrivals. GPU completion owns
   texture/lease retirement; reset epochs reject stale callbacks. The existing
   default-off physical-device shared-scanout option remains opt-in.

## Integration review corrections

- Corrected Phoc's private wlroots field access after real-header compilation.
- Declared Phosh's direct appstream development dependency for fresh builds.
- Prevented reset deadlock when Metal delivers completion handlers serially:
  a contended transport completion is handed to a per-device serial queue.
- Added cropped-scanout damage coverage for alternating immutable frame slots.
- Scoped Pixman GEM handle matching and snapshot allocations by DRM file.
- Simulator Metal staging now retains per-submission buffers and copies results
  from the submitted destination buffer, not a potentially replaced cache entry.
- Checked Pixman submission now occurs before the backend scanout commit, including
  when the allocator and KMS backend use separate DRM descriptors. Submission
  failure aborts the commit; it does not wait for successful GPU completion.
- Reaping a saturated pending queue can destroy a buffer and recursively flush.
  Capacity is now reclaimed before capturing the batch payload, then the batch
  is re-read. Regression tests reproduce and prevent duplicate submission.
- Native mapped-block solid-fill fast paths now leave the old block dispatch after
  updating PC. Real native-RAM tests reproduced 32/64-byte suffix overruns before
  the fix and preserve canaries afterward. The subsequent guest boot no longer
  emitted the ext4 buddy-bitmap warnings seen in the baseline.
- Generic native chain APIs no longer cast opaque callback state to the native
  fast-memory context when advancing the guest clock. Guard-page regressions
  reproduce the invalid access; typed native timer/interrupt tests still pass.
- Guest overlay resolution checks actual APK runtime dependencies and staged
  SONAME targets without replacing pinned packages wholesale. Native loader checks
  cover Phoc, Phosh, Squeekboard and NetSurf before cache generation. GNOME/EDS
  development packages are pinned to the guest ABI for reproducible rebuilds.

## Verification

- Baseline: 531 Swift tests passed.
- Final integrated core: 626 Swift tests passed serially, zero failures.
- All 192 native interpreter tests pass without exclusions.
- Focused GPU integration: 58 tests passed, including serial-callback reset.
- Phoc: 10 transaction regressions passed; production package compiled.
- Touch: 24 focused Swift tests and extracted Linux-code tests passed. A delayed
  96-motion swipe consumes 4 device frames/32 wire events instead of 98/784,
  preserving phase edges, final position and original timestamps. This measures
  queue work reduction, not end-to-end gesture latency.
- Presentation: 14 scheduler tests; device and Simulator typechecks passed.
- Launch lifecycle: 28 Swift tests and 10 C scenarios passed.
- Native ARM64 bridge tests and trap-mode UBSan passed.
- Real Metal matches Pixman for 3,528 cases in each of direct and Simulator-copy
  modes, including concurrent staging-buffer reuse coverage.
- Overlay dependency validation: 12 tests; graphical cache/loader guards: 7 tests.
- Cairo rebuilt and compared against stock Cairo with matching pixel output.
- Phoc 0.57.0-r6, wlroots 0.20.2-r5 and Phosh 0.57.0-r4 built successfully.
- Phosh's native upstream suite: 43 tests passed, zero failures.
- Final Release Simulator app built and installed. Its bundled kernel and rootfs
  hashes match the validated artifacts. Boot, visible lock screen, unlock,
  Settings rendering and Settings back navigation were observed. The intermediate
  build also displayed the guest keyboard.

ASan attempts stalled or lacked runtime support and are not counted as passes.
Source-mocked DRM tests do not replace real Metal and Simulator checks.

## Measurement limits

The pre-change installed Simulator reached the lock screen with fallback zero,
but its capture overlapped compilation and reproduced existing ext4 buddy-bitmap
warnings. Those startup/latency numbers are not a controlled performance
comparison. No percentage speedup is claimed from that capture.

The intermediate corrected build reached the shell in 3.91 seconds and Phosh
readiness in 77.43 seconds with both vCPU fallback counters at zero. Settings
rendered and navigation worked, but guest-side interaction samples still ranged
from roughly 0.2 to 3 seconds. A black display observed after inactivity was guest
idle blanking and woke on tap, not a failed compositor. These are observations,
not a claim of native responsiveness or a controlled speedup.

## Final Simulator acceptance

Completed October 26 on the dedicated `Pinecone Graphics Regression` Simulator
(`541E22EE-C52B-4478-A041-56FEDC23ACFF`, iOS 26.2), without background compilation.
The user's normal Simulator and physical phone were not modified.

| Observation | Final run |
| --- | --- |
| Shell prompt | 3.26 seconds |
| Phosh readiness | 85.25 seconds |
| Settings launch request to surface presentation | 33.37 seconds |
| Host frame commit to presentation, P95 | 24.06 ms |
| GPU command metadata lock hold, P95 | 0.002 ms |
| GPU command metadata lock wait, P95 | 0.000084 ms |
| Interpreter fallback | Zero on both vCPUs at every measured milestone |
| Graphics prepare/native/finish/synchronization failures | Zero |
| Ext4 warnings, unsupported instructions, panic or runner failure | None observed |

A fast three-event pointer drag delivered input but did not unlock the screen.
A continuous swipe through the display's accessibility action subsequently
reached the home screen. A real Settings icon tap opened the Network panel, and
a subsequent back-button tap rendered the Settings category list. This is a
functional smoke pass, not a claim that short swipes or animations feel native.

Recent active interaction samples spent approximately 0.4-2.7 seconds between
device delivery and frame commit, versus roughly 0.1-1.4 ms in the host input
queue. The aggregate touch P95 includes a 52-second sample spanning the earlier
unsuccessful drag and a later changed frame. The current frame association does
not establish causal gesture latency for that sample; it is retained in the raw
capture rather than presented as a controlled responsiveness benchmark.

The session also logged elogind cgroup mount/startup warnings. These did not
prevent unlock or Settings, but service integration is not warning-free. A
source-mocked DMA-BUF readiness test does not prove fence-ready redraw behavior
for every real client. Imported DMA-BUF sources still snapshot/upload; full
zero-copy and complete responsiveness are not claimed by this change set.

Artifact identities (SHA-256):

- Rootfs: `064cd5c953b0dcf9aa16a34d2be648921c947f41b4548ef068b73bee2e31b2f0`
- Kernel: `bd5a7aaa772fe98a070d9581a76d50b64dddf34b65853df5cd9d82c9c68798be`

Local evidence (temporary files, not committed):

- `/tmp/pinecone-nine-acceptance-tests.log`
- `/tmp/pinecone-nine-acceptance-rootfs.log`
- `/tmp/pinecone-nine-acceptance-app-build.log`
- `/tmp/pinecone-nine-acceptance-metal.log`
- `/tmp/pinecone-nine-acceptance-pixman.log`
- `/tmp/pinecone-nine-acceptance-pixman-ubsan.log`
- `/tmp/pinecone-nine-acceptance-profile.json`
- `/tmp/pinecone-nine-acceptance-ui-metrics.json`
- `/tmp/pinecone-nine-acceptance-uart.log`
- `/tmp/pinecone-nine-acceptance-runtime.log`
- `/tmp/pinecone-nine-acceptance-settings.png`
