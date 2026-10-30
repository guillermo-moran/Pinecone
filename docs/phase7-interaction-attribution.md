# Track U Interaction Attribution

## Scope And Result

2026-10-29 source audit and offline implementation. Owned files are only
`scripts/phase7-interaction-trace.py`, `scripts/phase7-interaction-trace-tests.py`
and this document. Existing dirty work is preserved. No production Swift/C,
guest image, preferences or instrumentation were changed. No Simulator UI,
launch/reset, build, cohort or commit was performed.

Read Track U in `roadmap.md`, the Firefox browser, performance-profile,
performance-integration, guest-profile-plan and cache-audit documents, and the
input/guest/graphics sources referenced below. Historical report measurements
are context, not new measurements or a passing Track U result.

**The first host-to-guest identity bridge is unobserved, not demonstrated
broken.** Host identities stop at injection; Phoc creates independent IDs.
The current graphics traces cannot prove Firefox received a click or that a
particular displayed frame acknowledges it. No failing transition or interaction
speedup is established from the saved traces inspected here.

## Offline Tool

Python standard library only. Reads saved files, prints JSON to stdout, opens no
device/network connection, and never changes inputs. Run one boot/capture at a
time; `--run-id` declares that scope, it does not verify provenance automatically.
If both files are supplied, the manager must establish that they are from the
same run. Do not concatenate runs or successive cumulative metric snapshots.

```sh
python3 scripts/phase7-interaction-trace-tests.py
python3 scripts/phase7-interaction-trace.py \
  --run-id firefox-profile-2026-10-28 \
  --metrics /tmp/pinecone-firefox-profile-metrics.json \
  --uart /tmp/pinecone-firefox-profile-uart.log
```

Either input is optional, but at least one is required. Metrics use existing
`inputAttribution` and raw `guestGraphics` arrays. UART accepts existing v2
`PINECONE_TRACE` touch/present/dropped records, including RS recovery. It ignores
ordinary console lines, launch lifecycle messages and app-presented control
messages; those contain no usable input/frame/time bridge. Unterminated,
malformed and oversized trace lines are reported, not repaired. Output includes
absolute source paths, byte sizes and SHA-256 hashes.

Identity rules:

- Host event: `(run, host producer, identity.epoch, identity.sequence)`.
- Phoc touch: `(run, Phoc producer, epoch, inputSequence)`.
- Phoc frame: `(run, Phoc producer, epoch, frameID)`, additionally validating
  `outputID` and 32-bit commit `sequence`. Different output/commit values for
  the same frame ID conflict; sequence alone never joins frames.
- Equal numeric host/Phoc IDs never join. `touchID` is not a unique event ID;
  down/up/move have different sequences. No contact duration is calculated
  without a verified contact mapping. Millisecond event times can wrap and are
  never used as identities or subtracted from host time.
- Exact duplicates deduplicate across metrics/UART. Conflicting records exclude
  that identity. Missing IDs/unsupported versions are reported, never guessed
  from timestamps, UART order or nearby frames. All timestamp subtraction uses
  ordered unsigned integers before conversion to milliseconds.

Result meanings:

| Status | Required evidence | Interpretation |
| --- | --- | --- |
| `observed_delay` | Same-identity endpoints in the same monotonic domain | An elapsed span, including zero; not automatically a stall or budget violation. |
| `missing_transition` | Explicit event rejection/coalescing/drop, frame abort or `notPresented` | That particular transition did not complete. Coalescing may be intentional; an aborted scanout attempt may be followed by a different successful composite frame. Not an interaction-wide failure. |
| `unobserved_transition` | Missing endpoint/hook, unmatched identity, reset, expiry or lost telemetry | Unknown, not failed or successful. Observation cutoff is not a guest timeout. |
| `invalid_evidence` | Reversed/invalid timestamps or contradictory fields | No duration for that span; do not clamp negatives or invent ordering. |

Host spans are capture-to-queue and queue-to-**injection**, not queue-to-guest
delivery. Guest spans are Phoc handler entry/exit and same-frame
render/submit/commit/present-callback stages. `handlerCPUUs` and same-thread CPU
counter deltas remain separate guest CPU accounting, not host CPU cost.

The only touch/frame association accepted is existing `temporalOnly`, with the
same Phoc epoch/sequence, matching `inputUs`, an ordered handler, and the existing
two-second proximity bound. It is emitted as **noncausal temporal context**,
never as input latency or acknowledgement. This bound is not a response deadline.
No host/guest timestamps are subtracted; UART receipt is not guest processing.
Legacy `interactions`, precomputed `guestFrameStages`, aggregate frame percentiles
and boot milestone counters cannot supply the missing causal edges and are not
converted into interaction measurements.

The tool intentionally cannot declare semantic success. Exit zero means the
offline analysis ran, not the workload passed. No p50/p95 interaction summary is
produced from partial paths. Trace silence is not proof of no execution: host
rings retain 256 events, Phoc has 32 frame slots and an 8192-record cap, and UART
writes can fail/short-write without retry.

## Saved Evidence Checked

Both commands below were executed against existing files, not newly captured
runs. Each result has zero host identities, zero Phoc touch identities, zero
Phoc frame identities and zero legacy interactions. No malformed recognized
trace lines were reported. This does not certify capture completeness.

```sh
python3 scripts/phase7-interaction-trace.py --run-id firefox-integrated-2026-10-28 \
  --metrics /tmp/pinecone-firefox-integrated-metrics.json \
  --uart /tmp/pinecone-firefox-integrated-uart.log
```

| Saved file under `/private/tmp` (`/tmp` alias) | Bytes | SHA-256 |
| --- | ---: | --- |
| `pinecone-firefox-profile-metrics.json` | 7035 | `f9fb7770f6591bb39c02cc3a9579541a55556e2e4484e58ac02588e63c604511` |
| `pinecone-firefox-profile-uart.log` | 41934 | `9370c29280f43fee7f6d9b8905a433d8c3cadb5e11cb5190795029ccdf2e3f1d` |
| `pinecone-firefox-integrated-metrics.json` | 7127 | `c6547b2186f5eea9adc1a9f870a933c3441ecba896da82486c3366d0414fa107` |
| `pinecone-firefox-integrated-uart.log` | 3187 | `8dbe54162c012cee7d6a596bb17167b478999a0fbf6c59ede4a5f03b928de36a` |

Those files cannot locate the historical failed Firefox tap. No new touch
latency, runnable/wait split, Gecko hotspot, rendering bottleneck or improvement
is reported. Earlier screenshots and sampled cumulative CPU counters remain
bounded observations in their original Firefox documents, not event identities.

## Manager Hook Handoff

Exact references below are to the inspected working tree, including patch-file
line numbers, not generated upstream line numbers. Concurrent integration can
move lines; function names identify the intended locations. These are proposals,
not implemented hooks. Keep them opt-in, bounded, nonblocking, and independent
of delivery/scheduling policy. Do not change input semantics to obtain telemetry.

| Boundary and current anchor | Missing evidence to integrate |
| --- | --- |
| [UIKit capture](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/ContentView.swift:454), [host identity admission](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift:1308), [injection](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift:1493) | Export contact ID, phase, transformed coordinates and original capture time with host event ID. Include synthetic final-move relationships. Current attribution contains no coordinates/contact grouping. Record actual down/up duration, not automation click duration. |
| [virtio timestamp wire](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VirtIO.swift:2078), [used-ring publication](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VirtIO.swift:2696), [IRQ line](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VirtIO.swift:3265) | Retain event identity through generated SYN_REPORT ordinal, descriptor publication and IRQ assertion/service. Current delivery timestamps are ordinal/ring bookkeeping, not exported per-touch Linux consumption. Queue injection precedes actual delivery and can leave events pending. Do not treat an IRQ raise as guest IRQ service. |
| [Linux mapping](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/linux-virtio-input-timestamps.patch:78), [input event delivery](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/linux-virtio-input-timestamps.patch:142) | Opt-in trace of consumption at SYN_REPORT with the host identity/ordinal bridge, raw capture, receipt, mapped timestamp, clock-pair generation and fallback/clamping flags. v2 carries capture time, NOT identity. Negotiate any future protocol change; timestamps alone are not unique. Export clock calibration uncertainty before considering cross-domain latency; the analyzer currently refuses it entirely. |
| [Phoc down/up/motion hooks](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:66), [handler record](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:309) | Carry Linux identity into Phoc; record target surface/client lifetime ID, seat/touch ID, Wayland serial and delivery result at the actual send. The scope timer encloses a Phoc callback, not Firefox handling; early returns still produce a handler record. Add client-receipt/handler markers via an approved diagnostic client or instrumented browser capture. |
| [Phoc frame allocation](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:344), [temporal association](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:362), [present callback](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:404) | Independent begin/submit/commit records keyed by frame/output/epoch, plus surface commit/damage IDs and their relationship to the semantic mutation. Current stage times are emitted together only at present, so an in-flight stall can leave no endpoints. Do not relabel `last_input` as causal. `expired` occurs after a successful presented callback; it is telemetry retirement, not presentation failure. |
| [wlroots output/fence preparation](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/wlroots-pinecone-ownership.patch:292), [host framebuffer commit](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VirtIOGPU.swift:801), [display completion](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/GuestDisplaySurface.swift:255) | Bridge surface/output commit through GPU resource/fence/request IDs to host generation and publish/upload/completion records. Pointer/resource reuse needs lifetime epochs. Emit begin/end/result for fence waits, not only cumulative time. Current Metal completion is a command-buffer callback ([handler](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/GuestDisplaySurface.swift:476)); CPU fallback is image assignment ([fallback](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/GuestDisplaySurface.swift:238)), neither proves physical scanout. |
| [light unlock click](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phosh-pinecone-light-lockscreen.patch:60), [launch token emission](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phosh-pinecone-launch-lifecycle.patch:138), [local Firefox fixture](/Users/gmoran/Documents/Projects/arm64viz/scripts/benchmark-simulator-executors.py:68) | Record unlock handler and actual unlocked/Home state separately. Add guest monotonic timestamps and input/window identity to launch tokens; current lifecycle records have tokens but no timestamps, and `PINECONE_APP_PRESENTED` carries only app ID. Extend the fixture with unique attempt/result counters and callback entry/exit markers. Existing `Tap received` is an idempotent visible result, not a repeatable per-attempt counter. No Firefox source is vendored here: select exact Gecko hooks only after inspecting the pinned browser source/build. |
| [host input wake](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift:1333), [secondary WFI wait](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/ParallelVCPUCluster.swift:219), [secondary run](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/ParallelVCPUCluster.swift:249), [pacing wait](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/ParallelVCPUCluster.swift:270), [checkpoint exits](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/EmulatorBackend.swift:1043) | Export per-vCPU run/wake/wait intervals and reason: WFI, pacing, host preemption, budget, pending IRQ, pinned-device access, fault. Use host monotonic time and interval counter deltas. A vCPU run interval includes guest kernel/other tasks, not necessarily Firefox work. Pair with guest scheduler evidence; do not print per-dispatch hot-loop logs. |
| [host retention/expiry](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VMPerformanceTimeline.swift:139), [guest ring retention](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizCore/VMPerformanceTimeline.swift:209), [lossy UART writer](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:290) | Export run/producer boot ID, enabled-hook manifest, capture start/end, record sequence, attempted/written/dropped counts, ring overflow and trace-cap exhaustion. Without this coverage contract, absence never proves a missing transition. A new export must retain pending identities beyond scheduling boosts without extending those boosts. |

The host trace enable is [here](/Users/gmoran/Documents/Projects/arm64viz/Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift:1107);
Phoc independently reads its own guest `PINECONE_INTERACTION_TRACE` environment
[here](/Users/gmoran/Documents/Projects/arm64viz/scripts/patches/phoc-pinecone-interactions.patch:282).
Setting a host environment variable is not proof the guest inherited it or that
the installed guest contains these patches. Verify emitted versions/records and
image/package hashes. No running-session changes were attempted in this task.

## Planned Workloads

Manager-owned future actions only; none was run here. Preserve the user's
guest/profile. Freeze build/kernel/rootfs hashes, executor flags, vCPU count,
viewport, installed instrumentation, browser/profile state and concurrent host
load. Keep two vCPUs and normal security settings. Save raw traces promptly,
before rings roll over. Do not mix profiled diagnosis with latency cohorts.

1. **Tap-to-unlock:** start from the actual lightweight lock screen, not the
   historical swipe scenario or automatic unlock path. Record one ordinary
   down/up pair with target coordinates and actual contact duration, then
   require unlocked Home state. Use host attribution and Phoc handler/frame
   events for local spans. Without the new unlock/state/surface hooks, a Home
   screenshot is functional evidence with observation bounds, not a complete
   latency trace. Preserve rejection, no-response and timeout attempts.
2. **Home and Settings:** verify Home, tap the Settings launcher, retain
   `requested`/`launched`/`failed`/`cancelled` launch-token records and matching
   app presence, then exercise Settings and return Home through the ordinary
   gesture/control. Split cold launch, warm activation and return Home into
   separate windows. `launched` is not a ready window; app presence cannot
   identify which launch instance or input caused it. Screenshot observations
   bound readiness until token/window/surface bridges exist.
3. **Firefox semantic click:** use the existing local-file fixture, with a fresh
   visible ready baseline and no previous `Tap received` result. Record exactly
   one identified contact. Require callback evidence independently of painting
   and then the changed visible result. Future per-attempt tokens avoid stale
   success on repeats. Browser `performance.now()`/Gecko markers use their own
   time origin until explicitly mapped; never subtract them from guest or host
   uptime. After a passing click, verify focus, exact typed text via the guest
   keyboard, scroll position/content change, and return Home as separate cases.
4. **Input-only control:** an existing suitable Wayland diagnostic client, if
   present, should log target/seat/serial/contact and callback independently of
   drawing. Availability was not established. Otherwise the manager must
   separately authorize staging/building such a client. This task did neither.
   Compare its reception with Phoc and Firefox, without assuming compositor
   callback completion proves client receipt.

An explicit observer cutoff ends an attempt as *unobserved by cutoff*, not as a
guest timeout. Require a reliable semantic success baseline before latency
claims. Later cohorts must follow Phase 7's predeclared matched-run protocol,
including failures and individual distributions; synthetic analyzer tests do
not satisfy those gates.

## Runnable, Wait And Render Attribution

Capture the same isolated workload window in guest and host domains, preserving
unmapped intervals separately. Follow the Firefox guest-profile plan for bounded
Gecko recording, actual parent/child coverage, matching symbols and normal
capture/shutdown. A host emulator stack cannot identify guest Gecko functions.

| Candidate cause | Evidence needed before attribution |
| --- | --- |
| Guest executing useful or retry work | PID/TID plus process start time, interval user/system CPU deltas with recorded `CLK_TCK`, nonempty matching Gecko stacks/markers. CPU accounting supports execution, not a specific useful function or dispatch cost. Sample both content and parent/graphics threads. |
| Runnable but not scheduled | Guest `sched_wakeup`/`sched_switch` or supported `schedstat` deltas keyed to TID lifetime in the guest scheduler clock. A sampled `R` state is not a duration. Separate time the host does not run either vCPU using host run/wait records. |
| Blocking I/O, futex, IPC or service wait | Switch-out state and matching wake/reply, wait channel/stack or Gecko wait/IPC markers. A sampled `S` state or a process's presence does not prove a long wait. Preserve missing scheduler hooks as a limitation. |
| Guest render/layout/raster work | Semantic callback-to-surface-damage/commit identity, Gecko layout/WebRender/SWGL markers and CPU deltas, Phoc same-frame stages. Phoc handler/render CPU is not all Firefox renderer work. Pixman/Metal offload does not imply SWGL offload. |
| Graphics synchronization/presentation | Same resource/fence/frame ID with wait begin/end/result, then host generation publish/upload/completion. A fast post-commit frame span cannot exclude slow pre-commit guest work; unrelated frames are not acknowledgements. |
| Emulator execution overhead | Same-window host CPU samples and both-vCPU execution/counter deltas while relevant guest tasks are executing/runnable. Inclusive nested stacks are not additive and do not establish dispatch as the cause of every stall. |

Parse `/proc/PID/task/TID/stat` after the final `)` and preserve start time to
reject PID/TID reuse. Check scheduler/proc availability before capture; do not
invent absent counters or enable intrusive diagnostics inside a timing cohort.
`wall - thread CPU` is not blocking time: it also contains runnable scheduler
delay, other guest tasks, host descheduling/pacing and accounting error. Do not
sum overlapping two-vCPU CPU time or nested graphics phases into a latency path.

## Verification

- `python3 scripts/phase7-interaction-trace-tests.py`: 31 synthetic offline tests
  pass. Coverage includes unrelated clocks/IDs/frames, duplicate/conflicting
  records, identity reuse, two outputs, timestamp wrap/invalid values, retained
  injection after expiry, explicit dispositions, lost telemetry, CPU accounting,
  UART truncation/RS recovery, legacy data rejection and CLI provenance.
- Both saved Firefox metric/UART pairs analyzed successfully as described above;
  both remain insufficient for causal attribution. Hashes bind this statement
  to the actual inspected bytes, not whatever those `/tmp` paths contain later.
- Tools: local shell read/search, `apply_patch`, Python standard library and
  `unittest`. `rg` was unavailable; searches used `grep`/`find`. No Swift/native
  tests, builds, UI actions, new live traces or performance cohorts were run.

Track U stays open: the manager still needs a same-event failing/successful
trace, the targeted runtime fix if demonstrated, and repeated semantic success.
