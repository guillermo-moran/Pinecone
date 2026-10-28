# Integrated Interpreter Performance: 2026-10-26

## Result

The integrated musttail prototype is executing real guest instructions, but a
large UI responsiveness improvement is **not established**. Six controlled-guest
boots show promising median boot/CPU numbers with substantial overlapping
variation. A real Settings icon launch remains slow.

No production code or runtime defaults were changed during this measurement pass.
The final Simulator run retains the prototype enabled.

## Comparison

Same Release executable, kernel, Simulator, two parallel native vCPUs, 1 GiB
configured guest RAM, and interaction tracing enabled. The sole runtime toggle
was `SIMCTL_CHILD_PINECONE_THREADED_PROTOTYPE=0` versus `1`. Other recently
integrated arithmetic, memory-copy, and graphics changes are present in both
arms; this comparison does not isolate their individual gains.

Order: off, on, on, off, off, on. Before every run the stopped Simulator's rootfs
was restored from the same private APFS clone and its SHA-256 checked. The image
contains persisted user state, not a factory-clean filesystem. Host filesystem
caches were not flushed. The initial uncontrolled trial was excluded after
detecting that the live-backed rootfs changed between runs.

| Run | Prototype | Shell s | Phosh ready s | App CPU-seconds at readiness | Peak sampled RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Off | 3.000 | 68.308 | 71.71 | 743.3 |
| 2 | On | 2.931 | 73.107 | 70.83 | 784.8 |
| 3 | On | 3.056 | 77.512 | 69.56 | 723.7 |
| 4 | Off | 2.791 | 91.719 | 93.74 | 683.4 |
| 5 | Off | 4.252 | 81.689 | 80.81 | 725.9 |
| 6 | On | 3.697 | 73.242 | 77.80 | 715.9 |

| Metric, median of three | Off | On | Observed change |
| --- | ---: | ---: | ---: |
| Phosh readiness | 81.689 s | 73.242 s | 10.3% lower |
| Process CPU time at readiness | 80.81 s | 70.83 s | 12.3% lower |
| Shell readiness | 3.000 s | 3.056 s | 1.9% higher |
| Peak sampled resident memory | 725.9 MiB | 723.7 MiB | 0.3% lower |

These are observations, not statistically established effect sizes. Readiness
ranges overlap: off 68.308-91.719 s, on 73.107-77.512 s. CPU ranges overlap too:
off 71.71-93.74 s, on 69.56-77.80 s. Three samples per arm are insufficient to
attribute these median differences confidently under this host's variability.
The first adjacent pair had slower readiness with the prototype enabled.

CPU seconds cover the entire Pinecone process through the profiler's detection
of readiness, including launch/host work and up to roughly one polling interval
of delay. RSS was sampled approximately once per second; it is neither total
physical footprint nor exact peak memory. The raw collector's `idleCPUPercent`
field is a ten-second **post-readiness** window, not proven steady-state idle:
median 95.9% off versus 94.4% on, with on spanning 84.4-111.2%. One hundred percent
means one host CPU core. There is no defensible idle-CPU improvement claim.

All six runs reached Phosh with zero Swift fallback on both vCPUs. Enabled runs
retired 5.18-8.82 million primary instructions through the prototype, only
0.392-0.438% of primary-vCPU instructions at readiness. Instruction fraction is
not a CPU-time fraction. Secondary prototype coverage is not exported by the
current report and is not inferred here.

## Application And Unlock Diagnostic

After run 6, the first full-height guest accessibility swipe unlocked to the
home grid. This is functional smoke, not an ordinary-pointer swipe latency test.
No valid repeated touch-latency distribution was collected.

Settings was launched by tapping its actual Phosh dock icon, not a TTY helper.
The host timeline recorded:

- Launch request: 185445.896625 ms since guest execution started.
- First application surface: 220477.511875 ms.
- Request-to-first-surface: **35.031615 s**.
- Additional native work between those markers: 929,812,699 primary plus
  726,750,944 secondary instructions, approximately **1.657 billion total**.
- Zero Swift fallback at both markers.

Screenshots in the task showed the splash at 20.177 s after the icon tap, no
usable content at 34.314 s, and the populated Wired/VPN/Proxy Settings page at
45.975 s. Thus usable content was observed within the interval
**(34.314, 45.975] seconds**, not at an exactly measured 45.975 seconds. No
controlled off-mode Settings launch was collected. This single diagnostic,
which includes stack-sampling overhead, does not establish an app-launch gain.

The cumulative host commit-to-presentation p95 was about 21.1 ms during launch;
that is neither touch-to-photon latency nor a guest rendering duration. It does
not explain away the 35-second application-startup delay.

## Stack Sample

A ten-second host sample was collected during the middle of Settings startup,
separately from all six boot timings. Largest relevant exclusive/top-of-stack
counts from the sample's collapsed summary:

| Function | Samples |
| --- | ---: |
| `avz_native_run_threaded_decoded_block_cpu_mapped` | 2684 |
| `avz_native_run_checkpointed_chain_with_memory_mode` | 597 |
| `avz_entry_code_is_current` | 340 |
| `avz_fast_translate_instruction` | 269 |
| `avz_native_fast_memory_translate_pair` | 236 |
| `avz_find_successor` | 192 |
| `avz_native_fast_memory_write` | 149 |
| `avz_native_fast_memory_read` | 124 |
| `avz_fast_mark_dirty` | 122 |
| `avz_guest_memory_lock_small_pair` | 75 |
| `avz_native_block_cache_threaded_program` | 36 |

These are sample counts, not percentages of wall time or additive inclusive
stack costs. The mapped executor is the existing C path, not the new musttail
subset. The iOS main thread was in its Mach-message wait in 7312 of 7344 samples.
The secondary worker was in its waiting-for-interrupt condition wait in 3747 of
7344 samples. That alone does not prove a scheduler bug: guest WFI may be valid.

The evidence favors work inside native guest execution and validation/memory
helpers over additional SwiftUI presentation tuning for this launch workload.
It does not prove a specific instruction or synchronization check can be removed.

## Next Measured Changes

1. Optimize the existing paired load/store path first. It appears prominently
   under mapped execution. Preserve page crossing, permissions, alignment,
   observation locks, atomics, dirty tracking, and precise faults; benchmark
   actual cached-chain mixed-memory workloads, not arithmetic-only loops.
2. Reduce redundant code/mapping validation within a validated execution span.
   Measure generation-check and mapping-check frequency. Retain invalidation
   on writes, remaps, TLBI, callbacks, and cross-vCPU changes; do not simply
   delete `code_is_current` checks.
3. Expand musttail coverage using those measured hot instruction forms. The
   current all-supported-block selection and small subset leave nearly all
   primary instructions in the existing executor. Avoid losing superblock
   chaining benefits or adding per-block allocation/validation overhead.
4. Repeat actual icon launches and valid full-travel gestures with semantic
   observation, alongside boot A/B. Accept a UI improvement only when that
   workload improves; microbenchmark ratios and retired instruction counts
   are not substitutes.

## Environment And Evidence

- Apple M2, eight logical CPUs, 24 GiB RAM; macOS 26.5.1 (25F80).
- Dedicated Pinecone Graphics Regression Simulator, iOS 26.2. No connected
  physical device was used.
- Other host applications remained running. A mid-test snapshot showed active
  WindowServer/Codex work and about 11.6 GiB swap usage. Swap usage alone does
  not establish active swapping as the cause of variance; no causal attribution
  to host memory pressure is made.
- Executable SHA-256:
  `9344a25f0fe36eaa0fb69f90d8860e847c64afad181a1adaa76629bc23d2533a`.
- Restored baseline rootfs SHA-256:
  `c69030c1b26559c1f4d431b2e5ef22750a8c0e507cf1f291d8837a4f74152e27`.
- Kernel unchanged from the installation pass:
  `bd5a7aaa772fe98a070d9581a76d50b64dddf34b65853df5cd9d82c9c68798be`.

Raw profiles, process samples, UART/runtime logs, identity, the collector, and
host stack samples are archived in
`performance-evidence/threaded-simulator-2026-10-26.tar.gz`. The large disk clone
is excluded. The collector is an environment-specific measurement script, not
a general deployment tool: inspect its paths before reuse; it restores the test
Simulator disk before each run. Live working evidence is also at
`/tmp/pinecone-threaded-ab-controlled-20261026`.

Final observed state: Settings rendered, prototype enabled, no unsupported
instruction, kernel panic, segmentation-fault, runner-failure, or EXT4 error
marker in the collected final runtime/UART logs. This is not an Android
compatibility signoff or a native-like responsiveness claim.
