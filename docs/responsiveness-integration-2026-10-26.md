# Remaining responsiveness work: integration review

Six owners worked in disjoint areas; the parent reviewed, packaged, and tested
the combined result. Existing changes from the previous nine-owner pass were
preserved. This pass does not establish native-like responsiveness.

## Integrated changes

| Area | Result | Boundary |
| --- | --- | --- |
| Input/frame attribution | Host admission identities, explicit coalescing/rejection/expiry, guest frame identities and optional thread-CPU spans | No host-to-Phoc causal chain; temporal context is not a measured touch response |
| Host rendering | Exact NEON solid-source/packed-A8 OVER plus native/Metal phase, operator, rejection and copy counters | No expanded operator eligibility or protocol change |
| Source snapshots | Copy only sampled regions; reuse valid contained source/mask snapshots without redundant synchronization | Unknown/escaped aliases still snapshot; allocations remain full-sized |
| DMA-BUF readiness | Event-loop readiness waits retain cached surface commits and previous content; bounded retries and lifetime cleanup | Real producer-fence latency is not established by mocked DRM tests |
| CPU execution | Added mapped-dispatch producer/helper/branch/budget regression harness | Candidate optimization rejected after final benchmark regression; previous dispatcher retained |
| Acceptance | Offline repeated-interaction evidence validator and compatible boot profiler | Accessibility/automatic swipes are functional diagnostics, not ordinary-pointer performance acceptance |

The parent corrected an app-only integration reference: the display-generation
value used to continue an input execution burst remains scheduling-only state.
It is updated when queued touches are injected. Input boosts, delivery tracking,
and display-publication wakeups do not depend on attribution success.

The boot profiler forwards the trace opt-in to both host and guest. It no longer
waits for the retired next-frame touch metric. Requesting positive legacy
`PINECONE_PROFILE_MIN_INTERACTIONS` fails before operating the Simulator.

## Measurements, not UI claims

- Host glyph loop: 67,258 byte-exact cases passed. Five alternating-order trials
  measured an 8x7 glyph at approximately 425-462 ns before versus 47-50 ns after;
  a 64x7 glyph measured 3,233-3,407 ns versus 230-239 ns. These are isolated host
  raster measurements, not application or interaction latency.
- Snapshot harness: a 4x4 ARGB region copied 64 bytes instead of a full 8,192-byte
  image. Twenty valid source and twenty mask hits copied no bytes and issued no
  backing synchronization. These are controlled synthetic workloads.
- Readiness harness: 1,000 idle Wayland dispatches caused one initial readiness
  check; signaling the producer committed once. Tests use pipe readiness and
  mocked DRM, not a real GPU producer.
- The final CPU candidate regressed median synthetic ALU time by approximately
  46-73% and the longest memory workload by 18%. The earlier promising numbers
  preceded additional metadata guards. The parent withheld the candidate and
  verified the native implementation matches the pre-pass baseline exactly.

## Verification

Owner checks include native/Pixman comparisons, 3,528 real Metal comparisons in
each direct/copy mode, native glyph UBSan, ARM64 bridge UBSan, actual patched
wlroots commit/lifetime tests, and Phoc attribution source tests. ASan attempts
stalled or lacked runtime libraries and are not counted as passing.

The integrated core suite passed 649 tests. Acceptance validation passed 33
synthetic cases, profiler compatibility passed eight mocked-device cases, and
graphical package dependency closure passed 12 cases. These are separate from
Simulator functional checks.

After withholding the CPU candidate, 1,647 valid-metadata mapped-dispatch cases
pass against the restored implementation, including its saved baseline under
UBSan. Invalid internal-map expectations added only for the rejected candidate
were removed; the private runner continues to require validated producer data.

Guest packages are Phoc 0.57.0-r7 and wlroots 0.20.2-r6; Phosh remains 0.57.0-r4.
Cairo was rebuilt against the updated bridge and its manifest verified before
rootfs assembly. Package hashes and rootfs identity prevent silently testing the
previous precompiled guest libraries.

Rootfs SHA-256:
`b38ed39c296f40d86cc1e67da1a2a2ee29f970322eb0020a462087bbfaa29025`

Unchanged kernel SHA-256:
`bd5a7aaa772fe98a070d9581a76d50b64dddf34b65853df5cd9d82c9c68798be`

Final Release Simulator executable SHA-256:
`65a67b52c94b20cf8b1acdc31cfd2dac463f5576788a8733c7cab10947edb86a`

## Simulator observations

Tested only the dedicated Pinecone Graphics Regression iOS 26.2 Simulator,
with two vCPUs, Release configuration, and interaction tracing enabled. This was
not an uninstall/factory reset; the new image had already booted once during the
withheld CPU candidate's diagnostic run. No connected phone was used.

- Final run reached the shell in 3.682 seconds and Phosh readiness in 64.214
  seconds. These are single-run checkpoints, not a controlled A/B improvement.
- The first full-height accessibility swipe returned to the lock screen. The
  second unlocked to the home/app grid. The unsuccessful first attempt is retained
  as an unresolved interaction issue, not omitted from the result.
- Tapping the actual Phosh Settings icon produced the Settings window. The
  request-to-presentation milestone was 33.320 seconds, so startup is still slow.
  This is not an exact usable-content observation time or equivalent to the
  earlier TTY-launched Settings benchmark.
- Settings navigation worked. Its search field presented the guest Squeekboard
  keyboard, and tapping `w` inserted text and filtered the results.
- Both vCPUs recorded zero Swift fallback at all captured milestones; all four
  paravirtual GPU failure counters were zero. UART/runtime logs contained no
  unsupported instruction, panic, segfault, or runner-failure marker.

Evidence is under `/tmp/pinecone-remaining-*`: `final-profile.json`,
`final-ui-metrics.json`, `final-uart.log`, `final-runtime.log`, `lockscreen.png`,
`home.png`, and `settings-keyboard.png`. These temporary files should be archived
with any performance report. They establish the described functional observations,
not completion of the repeated ordinary-gesture performance gate.

## Remaining limits

Full causal latency attribution requires a versioned identity through virtio,
kernel, libinput, shell/client semantic updates, surface/output commits, and host
presentation. Current guest thread-CPU spans are guest accounting, not host
interpreter CPU samples. Present callbacks are not physical display completion.

The available CUA drag produces only three events in approximately 1 ms. A full
bottom-to-top accessibility swipe can check functional unlock, but it cannot
pass the ordinary-gesture acceptance contract. Repeated same-clock semantic
observations with an appropriate continuous-input driver remain necessary for
performance acceptance. See [the contract](responsiveness-acceptance.md).

No vCPU-count, fallback-policy, or guardrail changes were made. The runtime remains
two native vCPUs with Swift fallback disabled. Unknown graphics operations still
use correctness-preserving raster paths; this is distinct from CPU fallback.
