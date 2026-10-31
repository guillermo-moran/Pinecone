# Input Scheduling Agent Report

Date: 2026-10-31. Task 3, host scheduling/input scope only.

## Evidence And Decision

Read `gtk-input-latency-profile.md` and `phosh-graphics-priority-profile.md`
before editing, including the existing primary-launch-pacing fix. Preserved
pre-existing dirty/untracked work; no commits, device/Simulator interaction,
rootfs changes, app installation, shared builds, or guest benchmarks.

The measured GTK phases are guest wall-clock intervals: insertion handler
76.96 ms, insertion start to before-paint 105.93 ms, frame cycle 306.55 ms,
insertion start to after-paint 416.88 ms (medians). The 105.93 ms interval
includes the handler; it is not a 106 ms scheduler stall. None of these is
CPU-only attribution, and after-paint is not display presentation. Disabling
GTK4 animations did not establish an improvement and is not a proposed fix.

Found a concrete host wakeup gap in `MobileOSHostModel.startRunner`:

1. The runtime approves continuous-execution pacing with no pending input.
2. Input arrives after that check or after the pacer's last-activity sample.
3. `queueTouch` signals input preemption, the secondary cluster, and
   `HostWakeSignal`, but the primary runner is in `Task.sleep`.
4. That signal cannot end the primary sleep. Touch injection waits until the
   sleep and cooperative-task rescheduling finish.

`HostExecutionPacer` caps the requested delay at **2 ms**. This code-level
wakeup defect does not explain the measured hundreds of milliseconds, and no
typing-speed or whole-UI performance improvement is claimed.

## Changes

- `Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift`: return an optional
  wake generation from the existing pacing decision, captured before checking
  eligibility. Wait on that generation with the unchanged pacer delay instead
  of `Task.sleep`. Add opt-in primary pacing-wait counters to existing touch
  diagnostics. Remove the now-shared private wake helper from this file.
- `Sources/ARM64VizCore/InteractionExecutionPolicy.swift`: move the existing
  `HostWakeSignal` implementation here for direct policy regression testing.
  Retain its lock, generation, continuation dictionary, and timeout mechanism.
  Add cancellation handling matching the existing `DisplayCommitSignal`
  pattern, preserving the old pacing sleep's cancellation behavior; zero
  delay returns immediately. Interaction policy/deadlines are unchanged.
- `Tests/ARM64VizCoreTests/InteractionExecutionPolicyTests.swift`: add six
  focused tests described below.
- `docs/input-scheduling-agent-report.md`: this report.

No edits to `ApplicationExecutionPolicy.swift` or its tests in this task.
Their pre-existing dirty changes, including independent primary/secondary
launch windows and distinct overlapping-presentation matching, remain intact.

## Path Audit

- Host touch goes through `sendTouch` -> `queueTouch` -> `TouchMotionQueue`.
  Admission and scheduling policy changes use the runtime lock. Preemption
  and wake signaling occur after releasing it. The trace/admission work inside
  that lock has no measured contention attribution in the supplied captures.
- `runSlice` drains only the virtio touchscreen's available sample capacity,
  preserving reserved termination slots, then calls `enqueueTouches`.
  The device lock protects event generation, used descriptors, and IRQ updates.
  `inputFrameDeliveryProgress`/`noteTouchDeliveredIfNeeded` end the delivery
  execution profile after SYN_REPORT delivery, not after Squeekboard handles
  the contact or Text Editor changes its buffer. No ownership or IRQ semantics
  changed. Guest Squeekboard typing is not `queueKeyboardEvents` host text input.
- IRQ wake handlers reach `ParallelVCPUCluster.signal`, its condition broadcast,
  and the host wake handler. The secondary already waits on that condition for
  duty-cycle pacing, with recent-wake grace. Its condition is not held during
  `vm.run`. Primary execution likewise does not hold the runtime lock across
  `machine.vm.run`. No evidence justifies deleting locks/atomics or changing
  guest task affinity.
- Primary idle WFI waits already use the generation signal and guest timer
  timeout (capped at 250 ms). The fixed primary duty-cycle wait now also reacts
  to input, IRQ, network, frame activity, and cancellation. Capturing the
  generation before policy evaluation protects the decision-to-registration
  gap; registration and signaling still serialize under the signal lock.
- Touch delivery/tracking/rendering wall budgets remain 4/10/16 ms, with their
  existing checkpoints and instruction budgets. The five-second input watchdog,
  250 ms frame-quiet period, cooperative yields, and two-vCPU default remain.
  The primary pending-launch pacing exemption still lasts until presentation,
  failure/cancellation, or its bounded lifecycle deadline. The secondary boost
  remains 12 seconds; the opt-in global launch experiment is unchanged.
- Virtio display commit wakes the publisher and execution. Publication calls
  `recordDisplayPublished` -> `InteractionExecutionPolicy.frame`; actual host
  presentation is recorded separately. Frame generation ends a tight burst,
  not necessarily the interaction. The policy can settle after 250 ms without
  another publication, and late frames cannot revive it. Publication is not
  causally identified as the text response; no longer boost is justified yet.

## Diagnostics

With `PINECONE_INTERACTION_TRACE=1` and existing performance reporting enabled
(for example `PINECONE_DUMP_PERFORMANCE=1`), the host touch summary now includes:

`primaryPacingWaits`, `requestedNs`, `elapsedNs`, `maxNs`, `generationChanged`.

These count wait attempts, including stale-generation immediate returns. They
are cumulative since runtime creation and emitted after at least one accepted
host touch. Take snapshots around an interaction window and difference
the counts/totals; the cumulative maximum is not an interval maximum.
`elapsedNs` includes suspension and host task rescheduling, not just an intended
sleep and not CPU time. A changed generation is observed after return: it may
precede registration or follow timeout, so it is not an exact wake reason or
an input count. No text or coordinates are added. With tracing disabled, no
diagnostic clocks/counter updates are added to the pacing wait.

## Verification

Used an isolated temporary Swift package, following the existing focused policy
runner's pattern, copying these production sources: `ApplicationExecutionPolicy`,
`InteractionExecutionPolicy`, `GuestGraphicsTrace`, `GuestControlConsoleFilter`;
and the two policy XCTest files. No native interpreter or iOS build was needed.
Fixture: `/tmp/arm64viz-input-scheduling.K9AJE8` (temporary, not a deliverable).

Command from that directory:

```sh
swift test --jobs 2 --disable-sandbox \
  --cache-path /tmp/arm64viz-input-scheduling.K9AJE8/cache \
  --config-path /tmp/arm64viz-input-scheduling.K9AJE8/config \
  --security-path /tmp/arm64viz-input-scheduling.K9AJE8/security
```

- 41 tests pass: 30 existing application-policy tests and 11 interaction tests.
  The six additions cover a signal between eligibility and registration,
  concurrent signals/32 waiters, timeout without activity, cancellation before
  or racing registration, zero delay, and exact quiet-period/watchdog boundaries.
- Negative control in the temporary fixture only: substitute `Task.sleep` in
  the lost-wake test. Its expectation fails at one second as intended; cancel
  the synthetic 60-second wait and restore the fixture. This tests semantics,
  not the production 2 ms latency or an integrated app execution.
- The first isolated compile exposed its manifest's old default deployment
  target. Added explicit availability to the extracted async helper/tests;
  the existing focused manifest now builds without changing repository scripts.
- `swiftc -frontend -parse Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift`
  and scoped `git diff --check` pass. Parsing is not iOS typechecking/linking.

## Risks And Integration Needs

No full suite, iOS build, real taps, zero-fallback runtime verification, or pixel
verification was performed here. The user owns those integration checks.
Execution backend, fallback policy, graphics fences, guest image, animation
settings, CPU count, pacing ratio/cap, and synchronization contracts are unchanged.

Wakeable pacing can perform more work on real activity and adds continuation /
dispatch-timer bookkeeping to the primary path. Timers scheduled before an early
wake still fire harmlessly after removing no waiter. Cancellation now also ends
idle waits promptly. Measure CPU/power and admission latency before promotion;
this is not a performance acceptance result.

Concrete unresolved scheduling path: `recordDisplayPublished` ->
`InteractionExecutionPolicy.frame` -> `isLatencySensitive` ->
`continuousExecutionPacingGeneration`, and primary task rescheduling after
`HostWakeSignal.wait` / `Task.yield`. The provided GTK samples do not reveal
whether a quiet-period expiry or a long host scheduling delay occurred there.
Counter deltas can establish whether primary pacing overlapped the next sample;
host stack/scheduler sampling is still needed to separate runnable delay from
guest WFI or lock waits. The downstream guest path from evdev/Phoc through
Squeekboard to GTK insertion/frame production has no shared end-to-end identity.

Integrate with two vCPUs and unchanged guest/build flags; repeat real Squeekboard
tap sequences in fresh Text Editor documents with reversed A/B order. Record
queue-to-injection separately from guest GTK phases and host frame presentation.
Verify text, backspace, selection, non-ASCII composition, idle/resume, and Stop;
require zero interpreter fallbacks and unchanged graphics correctness. Do not
subtract host and guest clocks, infer per-key causality from cumulative counters,
or increase boosts/CPU count without further evidence.
