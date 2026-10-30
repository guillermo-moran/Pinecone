# Firefox Performance Investigation

## Conditions

Measured October 28, 2026 local time (October 29 UTC) in the existing Pinecone
Graphics Regression Simulator. Release build, two parallel vCPUs, 1 GiB guest
RAM, threaded prototype and scalar-memory prototype enabled. No runtime code,
browser preferences, sandbox settings, or performance switches were changed.
The Simulator was initially shut down; the existing installation and guest
profile were retained, not reinstalled.

Firefox was launched from the guest shell with its existing Wayland session,
Pixman preload, and `pinecone-launch-firefox about:blank`. This removes a
website download from the foreground startup workload, but is not a pristine
profile experiment: an `about:sessionrestore` tab was also present. Firefox
background services can still use networking. Diagnostic commands and host
sampling add overhead; these are diagnostic observations, not benchmark medians.

## Observations

- Launch command: 01:41:37 UTC. The blank browser window and guest keyboard
  were visibly present by 01:45:17 UTC. Screenshot polling was intermittent,
  so 220 seconds is an upper bound, not an exact first-frame latency.
- At 01:43:50, Firefox's main thread had 105.23 seconds user CPU and 11.64
  seconds system CPU. Its `Renderer` thread had 1.67 seconds total CPU.
- At 01:47:41, main-thread CPU was 237.94 seconds; `Renderer` was 2.60 seconds,
  `Software...cThread` 22.29 seconds, and `SwComposite` 0.53 seconds. These
  are guest kernel CPU accounting values, not native-speed work estimates.
  Other browser processes/threads are not included in these four values.
- Guest available memory: 975604 KiB before Firefox, 736120 KiB during startup,
  and 729652 KiB after the input test. Sampled swap, reclaim scanning,
  allocation-stall and OOM counters were zero. More RAM is not the first fix
  for this 1 GiB Simulator workload; this does not establish iPhone headroom.
- A Squeekboard `x` tap at 01:45:53.561 was still absent at 01:46:03.800;
  `ex` was visible at 01:46:32.877. Observed latency is bounded between about
  10 and 39 seconds, not an exact 39-second measurement.
- Cumulative host frame metrics: commit-to-present median 12.97 ms, p95
  30.23 ms; commit-to-publish p95 0.245 ms. These cover the run, not exclusively
  Firefox frames, and do not include time before the guest commits a frame.
- Native-only execution remained active; the visible fallback count was zero.

## Concrete Execution Bottleneck

`TP_MEMORY` in `ARM64VizThreadedPrototype.c` ends execution after every supported
load/store, returning `AVZ_TP_STATUS_REVALIDATE` even after an ordinary successful
RAM access. This is deliberate lifetime protection: a memory callback can
invalidate/free the decoded program. The native chain then clears its predecessor
and calls the Swift checkpoint. It must not simply be changed to continue using
the potentially freed program.

The final metrics snapshot reports, on the primary vCPU:

- 233450869 prototype invocations (`blocks`).
- 447626002 prototype instructions: **1.92 instructions per invocation**.
- 133805592 memory revalidation boundaries: **57.3% of invocations**.
- 16105 memory faults, distinct from the ordinary revalidation boundaries.

These are cumulative counts including boot/Phosh, not isolated Firefox deltas.
They explain why "prototype enabled" and "zero fallback" do not mean execution
stays on the fast path. The complete native C executor still handles the other
instructions; this is not Swift instruction fallback.

Two 10-second host stack samples independently show checkpoint overhead:

| Inclusive sampled path | Startup | Later sample |
| --- | ---: | ---: |
| Swift native-chain checkpoint | 1831 / 11316 (16.2%) | 1063 / 12956 (8.2%) |
| Native mapped executor | 5133 / 11316 (45.4%) | 4738 / 12956 (36.6%) |
| Block code-current validation | 707 / 11316 (6.2%) | 1699 / 12956 (13.1%) |

Denominators are sampled stacks inside `SoftwareARM64Backend.run`, across both
vCPU execution paths. These are inclusive stack proportions, not percentages of
total application CPU, and nested categories must not be summed. Checkpoint
stacks include shared-translation synchronization, weak-reference/ARC traffic
in the preemption callback, and interrupt-controller locking/hash lookups.
Instruction fetch translation and decoding are additional visible costs.
The file named `input.sample.txt` started at 01:45:16 UTC. It predates the
documented `x` tap at 01:45:53 and must not be used as a causal profile of that
keypress. See the cache audit for more precise call-tree attribution.

## Graphics Scope

Firefox explicitly uses software WebRender. The Pixman/Metal bridge does not
automatically offload WebRender's renderer. That is a separate acceleration gap,
but the measured startup main-thread cost is much larger than the sampled
renderer-thread CPU; replacing presentation alone will not solve startup.

The cumulative Metal snapshot also reports 25.4 GB input-copy traffic and 8.54 GB
output-copy traffic. Its recorded input/output copy times total about 2.34
seconds and GPU execution about 1.04 seconds. Copy elimination remains useful,
but these measurements do not explain minutes of foreground latency by
themselves. The historical plain-HTTP timeout was not retested in this run.

## Next Work, In Order

1. Give running threaded programs a safe lifetime, and distinguish successful
   direct RAM accesses from callbacks, faults, code writes, and remaps. Continue
   ordinary loads/stores without a full host checkpoint. Preserve cross-vCPU
   invalidation, exclusive access, faults and interrupt deadlines. Add adversarial
   invalidation tests before enabling the continuation path.
2. Remove routine Swift work from native checkpoints using native generation and
   pending-event state with explicit ownership. Do not merely lengthen scheduling
   quanta: that could worsen input latency.
3. Measure validation/translation epochs, cache misses and decode churn specifically
   during Firefox. Reuse validated executable mappings where correct, and extend
   threaded coverage based on measured hot instructions, not a blanket rewrite.
4. Capture a symbolized Gecko main-thread profile to identify which Firefox
   initialization/JS/layout work consumes the guest CPU. Evaluate WebRender
   acceleration separately; do not assume Pixman changes accelerate it.

Acceptance should repeat blank-page startup, guest-keyboard typing, local/static
page rendering and HTTPS navigation, collecting Firefox-only counter deltas and
repeat-run medians. Keep the profile, guest disk, two-vCPU configuration and
sandbox settings fixed. No speedup is claimed without that A/B test.

## Raw Evidence

Host-local files from this run:

- `/tmp/pinecone-firefox-profile-baseline.sample.txt` (Phosh startup, not idle).
- `/tmp/pinecone-firefox-profile-startup.sample.txt`.
- `/tmp/pinecone-firefox-profile-input.sample.txt`.
- `/tmp/pinecone-firefox-profile-uart.log`.
- `/tmp/pinecone-firefox-profile-metrics.json`.
