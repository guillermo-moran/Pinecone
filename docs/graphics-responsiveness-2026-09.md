# Graphics Responsiveness Changes

## Implemented

1. **Resource ordering:** virtio-GPU reserves resources until asynchronous
   completion. Independent resources can remain in flight together; overlapping
   commands and resource lifetime operations wait. Reset discards stale queue
   completions and drains outstanding Metal writes.
2. **Upload ownership:** the Pixman bridge tracks submitted fences by DRM file
   and buffer handle. Source and mask cache refresh waits for prior readers,
   rather than assuming submission means completion.
3. **Exact Simulator coverage:** partial writes initialize only their actual
   rectangles. Overlapping damage is not expanded into unwritten holes. Batches
   that reinterpret the same resource as both packed A8 and four-byte pixels
   are rejected before submission.
4. **Single preparation:** cheap Metal eligibility runs before buffer creation
   and synchronization. Native completions return directly to the virtqueue;
   they do not decode the request and attempt Metal again.
5. **CPU access boundaries:** wlroots supplies read/write flags and mapped-buffer
   identity. Read-only getters preserve cache generations; mapped access waits
   on the affected buffer. Unscoped pointers remain conservatively writable.
   Synchronous operations release the bridge mutex only when they do not own
   reusable scratch storage. Scratch copyback and cache-refresh ownership still
   require serialization; these are not claimed to be lock-free.
6. **A8 destinations:** the bridge's destination-format gate now admits the A8
   path already supported by the graphics protocol and native compositor.
   Native output skips XRGB normalization for packed A8, whose DRM allocation
   still advertises XRGB. Otherwise normalization overwrites every fourth alpha
   byte, producing vertical glyph artifacts. An end-to-end test reproduces the
   corruption and checks both alpha bytes and untouched row padding.
7. **Reduced input copying:** CLEAR and SOURCE do not read the destination.
   Source/mask synchronization deduplicates exact regions within a submission.
   Coverage is not reused across submissions without a guest-write generation.
8. **Measurements and gates:** touch timing uses the actual virtio SYN_REPORT
   delivery timestamp and rejects frames committed before that delivery. Frame
   timing retains stalls during input response instead of filtering them as
   idle. Regression checks require a measured baseline and actual samples.
   Settings profiling no longer waits for an optional, disabled prewarm service.

The guest package revisions are wlroots 0.20.2-r4 and Phoc 0.57.0-r2. Phoc's
embedded wlroots is patched and rebuilt too; replacing only the shared wlroots
library would not activate these hooks in Phoc.

## Additional Startup Investigation

A fresh two-vCPU run reached the shell and announced Phosh readiness, but showed
a black display. The September 2 Release binary reproduced that behavior. A
single-vCPU diagnostic rendered the lock screen. Guest logs contained large
time jumps and D-Bus timeouts.

The parallel counter implementation exposed different per-vCPU instruction-based
counter values between synchronization points. The native path now reads one
immutable host-clock epoch shared by both CPUs. Timer polling is amortized over
1024 instructions; counter-register reads always sample the current clock.
Single-vCPU deterministic instruction-based timing remains unchanged.

## Verification

- 492 Swift tests pass, including independent/overlapping resource ordering,
  cross-vCPU counter reads, input delivery timestamps, and active-frame stalls.
- Both direct-memory and Simulator-copy Metal paths pass 3,528 Pixman pixel
  comparisons each, plus ordered batches, scaling, and partial-rectangle tests.
- Alpine/aarch64 bridge tests cover read/write generations, independent handles,
  and cache refresh while a reader's fence is outstanding.
- The rebuilt ext4 image passes filesystem validation.

The existing Simulator disk reported ext4 bitmap inconsistencies during
diagnostics. It was preserved, not repaired or erased. A separate Simulator,
`Pinecone Graphics Regression`, booted the fresh bundled image without those
errors and rendered Settings and the unlocked Phosh home screen with two vCPUs
and zero instruction fallbacks. Visual inspection found the A8 normalization
issue above, which was reproduced in a failing test before correction.

The final Release build was installed in place on that isolated Simulator.
Visual verification confirmed the unlocked home screen, launching Settings by
tapping its icon, and correctly rendered glyphs without the vertical artifacts.
The final UART log contains no ext4 errors, kernel panics, or unsupported
instruction failures. The original Simulator disk remains untouched.

Final-run observations (not a controlled before/after benchmark):

- Shell prompt: 2.41 seconds; Phosh readiness marker: 57.77 seconds.
- Commit-to-present p95: 18.42 ms across 74 recorded frame samples.
- GPU command-lock hold p95: 0.141 ms; first guest Metal completion: 5.37 ms.
- Snapshot copies and framebuffer copy-on-write bytes: zero in this capture.
- One touch-response sample: 133.44 ms. This is insufficient for a meaningful
  percentile or a general latency claim.
- The application frame marker was 18.19 seconds after the launch request.
  This marker is not semantic application visibility; Settings was separately
  verified visually. Startup and application responsiveness still need work.

Evidence from this session is in `/tmp/pinecone-final-verified-profile.json`,
`/tmp/pinecone-final-settings.png`, and `/tmp/pinecone-swift-tests-final.log`.

The regression script now preserves app containers rather than uninstalling
Pinecone on every run. Use a dedicated Simulator for clean-image measurements.

Commands:

```sh
swift test -c release
bash scripts/run-metal-compositor-differential.sh
bash scripts/run-pixman-bridge-regressions.sh
PINECONE_PERFORMANCE_BASELINE=/path/to/known-good.json \
  bash scripts/verify-pinecone-performance.sh
```

Readiness messages and generic frame samples are not proof that Phosh unlocked
or that Settings is visible. Those require a visual check. Historical touch
numbers collected before the timestamp correction are not an apples-to-apples
performance baseline. No overall responsiveness speedup is claimed from the
unit tests or from black-display runs.
