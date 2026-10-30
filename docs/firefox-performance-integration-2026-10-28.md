# Firefox Performance Integration

## Shipped Changes

- Threaded programs remain pinned during execution. Cache eviction retires
  them immediately and defers reclamation until the last active call returns.
- Proven hot RAM loads/stores continue within the existing instruction budget.
  Slow helpers, faults, observed stores, retirement, code changes and shared
  translation invalidation retain explicit exits. No Swift fallback was added.
- The host preemption provider retains its signal without a back-reference.
  This removes weak-load/per-read ownership work, not the signal's NSLock.
  Scheduling quanta, deadline/IRQ checks and stop precedence are unchanged.
- Added an opt-in guest Gecko profiling wrapper and offline tests. It is not
  installed or enabled in normal guest launches and does not relax sandboxing.

Independent review found no confirmed introduced pin/retire or epoch regression.
The manager added the requested coverage for a hot store followed by a
register-only loop: peer code writes and all four TLBI scopes must stop it
without relying on a later memory helper to observe the invalidation.

## Verification

- Full Swift/core suite: **668 tests passed**.
- Manager optimized and UBSan runtime suites: 3,136 differential scenarios, 128 cache
  replacements, 384 hot-continuation cases, plus eviction, code modification,
  remaps, MMIO, observation, precise faults, concurrent invalidation and deadlines.
- Agent prototype differential suite: 507,622 cases, disabled-mode checks and
  50-site mandatory-tail verification passed. ASan could not run because its
  host runtime stalled before `main`; this is not an ASan pass.
- Profiling-wrapper offline suite: **24 tests passed** on manager rerun.
- Release iOS Simulator build succeeded; installed over the existing app.
  Guest disk/profile were preserved; the bundled rootfs fingerprint was unchanged.
- Live Simulator: Linux shell, Phosh lock screen, tap-to-unlock Home, Firefox
  window and Squeekboard input observed, with zero visible fallback instructions.
  Two vCPUs and both prototype flags remain enabled. No physical-device claim.

## Paired Microbenchmark

The manager compiled the frozen baseline (`c3b3e957`) and current runtime with
Clang `-O3`, stopped Pinecone, then alternated their existing one-million-
instruction memory benchmark three times. Each variant had 27 samples.

| Variant | Baseline median | Integrated median | Checkpoints before / after |
| --- | ---: | ---: | ---: |
| Native reference | 7.847 ms | 8.063 ms | 245 / 245 |
| Register prototype | 7.934 ms | 8.036 ms | 245 / 245 |
| Scalar-memory prototype | 25.703 ms | 20.561 ms | 250003 / 247 |

The scalar workload's elapsed time decreased **20.0%**, with **99.9% fewer
checkpoints**. It remains roughly 2.55 times slower than the integrated native
reference on this workload. This is not a 20% Firefox speedup claim. Unrelated
host activity was not controlled, although compiler and Simulator load were
absent during the alternating comparison.

## Simulator Observations

Phosh readiness telemetry was 85.28 seconds and shell readiness 3.15 seconds.
Firefox's successful `about:blank` launch command ran at 02:25:41 UTC; its window
was visible by 02:28:28, an upper bound of 167 seconds. An earlier automated
attempt failed because the guest has no `pidof` symlink; using `busybox pidof`
corrected the test setup. The failed launch is excluded from the timing.

A guest `e` key tapped at 02:29:54 was visible at the next check at 02:30:14.
This proves delivery, not a precise 20-second latency or an input speedup.
The profile still showed session-restore UI, and polling was intermittent;
neither this run nor the earlier 220-second upper bound is a controlled
Firefox startup comparison. Firefox is still slow.

All touch-entered characters in `example.com` eventually appeared. Submitting
that bare address selected plain HTTP and did not render a document during
observation. An explicit `https://example.com/` request at 02:33:21 opened a new
tab but was still blank at the bounded final check at 02:36:37 (196 seconds).
Therefore this integration does **not** claim a successful HTTPS page-rendering
or general browsing smoke test. The VM remained running at over 15.4 billion
primary native instructions with zero visible fallbacks. Firefox remains open
for manual testing; its main-thread/network/page-rendering delay needs follow-up.

The new ten-second startup host sample contains 372 inclusive checkpoint
samples out of 11201 backend samples (3.3%), versus 16.2% in the prior startup
sample. This supports reduced checkpoint overhead, but workload phases differ:
it is not an application-wide CPU reduction or an end-to-end speedup measure.

## Remaining Work

The read-only cache audit identifies mapping-validation overhead, duplicated
prototype preparation/decoding and a **preexisting, source-inferred decode-
publication correctness risk**. Those were not silently bundled into this
continuation patch; they need deterministic tests and a separate scoped fix.
Firefox main-thread symbol profiling and software WebRender acceleration also
remain open. The Gecko wrapper has not yet produced a live guest capture.

Raw evidence is in `/tmp/pinecone-firefox-integration-tests.log`,
`/tmp/pinecone-firefox-integration-build.log`,
`/tmp/pinecone-firefox-integration-native.log`,
`/tmp/pinecone-firefox-integration-ubsan.log`,
`/tmp/pinecone-firefox-paired-before.log`,
`/tmp/pinecone-firefox-paired-after.log`, and
`/tmp/pinecone-firefox-integrated-startup.sample.txt`. Guest and presentation
snapshots are `/tmp/pinecone-firefox-integrated-uart.log` and
`/tmp/pinecone-firefox-integrated-metrics.json`.
