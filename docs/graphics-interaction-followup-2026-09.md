# Graphics Interaction Follow-up

Follow-up: [Guest processing and wakeup fixes](guest-processing-fixes-2026-09.md)
records the subsequent MIME matcher, native shortcut, scheduling and telemetry
corrections. In particular, the earlier latency samples excluded some slow
responses when the touch watchdog expired.

## Scope

This implements the five-item interaction/ownership follow-up. It does not
replace the ARM64 interpreter, change vCPU count, or introduce a JIT. Validation
uses the dedicated Pinecone Graphics Regression Simulator with two native-only
vCPUs. The original Simulator and its persistent disk are not modified.

## Changes

1. **Interaction traces:** bounded host samples split queue-to-device,
   device-to-commit, commit-to-publication and publication-to-presentation.
   Opt-in Phoc tracing records touch handling, render start, submission, output
   commit and presentation in the guest's monotonic clock domain. The two clock
   domains are deliberately not subtracted or represented as one causal trace.
2. **Ownership and fences:** synchronous and targeted fence waits release the
   bridge mutex. Stable image-state allocations survive concurrent table
   growth. Scratch buffers are thread-local; shared-only batching threads also
   register exit cleanup. CPU composite fallback synchronizes the images it
   actually accesses rather than draining unrelated submitted resources.
3. **Batchable uploads:** source and mask snapshots have image ownership and
   can join render-pass batches. Two spare buffers per cache and a 16 MiB
   process-wide spare budget permit rotation while previous readers remain in
   flight. Exhaustion waits for the affected resource. Escaped or unknown CPU
   pointers and GPU-owned alias snapshots are refreshed conservatively; a
   generation number is not evidence that those pixels are unchanged. Immutable
   solid colors remain batch eligible. Diagnostics include batch-size buckets.
4. **Guest CPU attribution:** opt-in primary and secondary vCPU hot-PC snapshots
   are captured by the executing worker, not by racing its native CPU state.
   The analyzer maps PCs to executable guest mappings and reports file offsets.
   The initial trace contains Phosh libgio sites around offset `0x154850` calling
   `memcmp`, with corresponding musl compare-loop PCs. These are investigation
   candidates, not measured percentages of CPU time: the profiler uses bounded
   Space-Saving counters and the two vCPUs have different reset windows.
5. **Application evidence:** Phoc includes app IDs only for focused views that
   contribute damaged pixels, then emits them at successful presentation.
   Settings launch uses this evidence rather than a generic nonblack-frame
   heuristic. UART launch markers and presentation records retain stream order,
   including split CRLF lines. This proves a focused application surface was
   presented, not that every widget is ready for use.

## Regression Coverage

- 497 Swift tests pass, including bounded trace parsing, CRLF/order handling,
  stale-frame rejection, presentation timing and historical report decoding.
- The Linux C bridge regression covers read/write generations, independent
  handles, mutex availability during fence waits, stable rehash, fenced buffer
  reuse, untracked writes, GPU alias snapshots, solids and shared-only thread
  exit cleanup. Built with `-O2 -Wall -Wextra -Werror`.
- Metal output matches Pixman for 3,528 cases in direct-buffer mode and another
  3,528 cases through the Simulator-copy path.
- The bundled ext4 image passes the build's read-only `e2fsck -fn` gate.
- Three analyzer tests cover clock ordering, deduplication, mapping boundaries
  and executable file offsets. Shell scripts pass `bash -n`.
- ASan/UBSan were attempted, but this Lima builder lacks their runtime libraries.
  The concurrency tests ran without sanitizers; no sanitizer pass is claimed.

An intermediate ownership build exposed stale upload contents during unlock.
That build was stopped, and the escaped-pointer/alias cases above were added
before rebuilding. It is not counted as a passing visual regression.

## Running the Diagnostics

Use `scripts/profile-pinecone-phosh.sh` with a dedicated Simulator and these
environment variables:

```sh
PINECONE_PROFILE_APPLICATION_COMMAND=pinecone-launch-settings
PINECONE_PROFILE_MIN_INTERACTIONS=10
PINECONE_PROFILE_TIMEOUT_SECONDS=360
PINECONE_PROFILE_HOT_PC=1
PINECONE_PROFILE_DETAILED=1
```

Perform repeated unlock/open/close interactions while the gate waits. The
automatic unlock waits for visible guest content; it is not a proof of unlock.
Set `PINECONE_PROFILE_PIXMAN_DIAGNOSTICS=1` in a separate diagnostic run to print
batch-size distributions. Do not compare a heavily profiled run with an
unprofiled run as a speedup measurement.

Analyze the JSON using `scripts/analyze-pinecone-responsiveness.py REPORT`, with
`--uart UART_LOG` when the console contains captured executable `/proc/PID/maps`
sections prefixed by `PINECONE_MAP:PID:COMM`.

## Observed Results

The final manual capture contains ten completed interactions, two Settings
launches, panel navigation, app-grid filter changes and a swipe. Phosh unlocked,
Settings rendered and closed, and the guest remained running with zero fallback
steps. The final capture passes the sample-count, application-presentation,
native-only and zero framebuffer-COW checks. The wrapper's 420-second timeout
expired at eight samples while manual investigation was ongoing; the last two
were collected afterward. This is not an automated multi-run regression pass.

| Measurement | Result |
| --- | --- |
| Phosh readiness, clean run without hot-PC profiling | 55.9 s |
| Phosh readiness, final detailed-status capture | 58.3 s |
| Settings request to focused surface, final capture | 29.0 s |
| Host queue to device, interaction p95 | 1.49 ms |
| Device delivery to committed frame, interaction p95 | 1567.6 ms |
| Commit to host publication, interaction p95 | 0.16 ms |
| Publication to presentation, interaction p95 | 40.3 ms |
| Total completed interaction p50 / p95 | 681.7 / 1589.1 ms |

One compositor render-pass diagnostic reports 126 commands in 38 submissions,
with seventeen batches in the 5-16 command bucket. Client-side Cairo/Pixman
transactions still frequently contain only one operation. The baseline's ten
samples used a different interaction mix; these measurements do not establish
an overall latency improvement, and responsiveness remains unacceptable for a
native-like UI.

Evidence is retained in `/tmp/pinecone-five-verified-capture.json`,
`/tmp/pinecone-five-verified-analysis.json` and
`/tmp/pinecone-five-verification-uart.log`.

The final Release rebuild was installed in place and launched without hot-PC,
frame-trace or batch diagnostics. Its normal boot reached the lock screen and
unlocked to the home screen with fallback zero and no ext4 errors in the console.
It is left running in the dedicated Simulator. Screenshot:
`/tmp/pinecone-five-final-home.png`.

### Unresolved Observations

- An earlier heavily profiled boot reported ext4 buddy/bitmap inconsistencies.
  The pristine bundled image passes `e2fsck -fn`. A disposable copy of the
  stopped guest disk passes a full check after journal replay. Subsequent
  clean-seed and repeated boots did not emit those errors. Their runtime cause
  is not established; this is not a filesystem fix claim.
- One earlier run stopped during Settings navigation. Host sampling showed the
  vCPU threads had exited, not a held graphics mutex. Its stop reason was lost
  because detailed profiling was disabled. Metrics mode now records lightweight
  stop/failure status and the wrapper fails immediately on backend failures.
  Repeated Settings launches and closes did not reproduce the stop. That is an
  unresolved observation, not proof it has been fixed.

For those reasons, implementation of the five items is complete, but broad
performance/regression sign-off is not. The next investigation should correlate
the guest CPU candidates with exact GLib/GTK call stacks during frame stalls;
another host presentation rewrite is not supported by these measurements.

## Remaining Constraints

Queue saturation, teardown, raw-pointer operations and actual CPU hazards can
still require synchronization. Pixel snapshots are not universally zero-copy.
The host sample pairs input delivery with a later display generation; the guest
sample pairs input handling with a subsequent render. Neither proves that every
pixel in that frame was caused by that input. Repeated identical workloads and
visual checks remain necessary before claiming a responsiveness improvement.
