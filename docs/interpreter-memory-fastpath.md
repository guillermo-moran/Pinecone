# Native Memory Fast Path: Bounded Copy Optimization

## Scope and Baseline

Workstream date: 2026-10-26. Production changes are confined to
`Sources/ARM64VizNative/ARM64VizGuestMemory.c`. The private header, public
headers, executor, caches, graphics, runtime defaults, and shared tests are
unchanged by this workstream. No guest images, SwiftPM/Xcode builds, Simulator,
Swift fallback, JIT, QEMU, commits, resets, or changes to others' work.

Before the first production edit, both owned files were copied using:

```sh
cp -p Sources/ARM64VizNative/ARM64VizGuestMemory.c Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h /tmp/avz-memory-baseline.eLV5A1/
shasum -a 256 /tmp/avz-memory-baseline.eLV5A1/ARM64VizGuestMemory.c /tmp/avz-memory-baseline.eLV5A1/ARM64VizGuestMemoryInternal.h
```

Baseline SHA-256:

- C: `fc6eb384ed7003a08cde96a3486e3caff1c4b690ecc118636c2d54c3c0923a35`
- Internal header: `33a2e4771c8da43800357e022cfafdd1aa289b5fcca53b9c95b5ae37d35c3622`

The directory also retains raw benchmark logs and assembly. It is temporary
local evidence, not a committed copy of the source. Harness build directories
are removed by the runner's exit trap.

## Inspection and Change

`avz_native_fast_memory_try_{read,write}_hot` already checks shared translation
epochs, private hot generations, address/context identity, contiguous spans,
RAM bounds, and page observation flags. Dirty-code and exclusive accounting
remain on the existing commit paths. Context/ASID switches invalidate hot
generations; shared TLBI journal consumption takes the publication lock before
using page-table updates. Journal overflow falls back to full invalidation.
These checks and their memory ordering are not changed.

Observation flags distinguish host access, retained bulk readers, and exclusive
monitoring. Host-observed access must retain the stripe-lock protocol. Exclusive
slots and global statistics create contention even on disjoint RAM; hashed
exclusive slots can conservatively conflict. Repeated observation publication
also incurs atomic metadata traffic. This work measures these costs but does
not replace their synchronization or add an unchecked cached-observation path.

The retained change is an aligned eight-byte inner loop in
`avz_fast_atomic_read_bytes` and `avz_fast_atomic_write_bytes`. The baseline
emits a variable-length `memcpy` call for each chunk. The new inner loop emits
ordinary host buffer loads/stores around the existing atomic guest access,
without a per-chunk `memcpy` call. The existing chunk selector handles initial
unaligned bytes and trailing 1/2/4-byte chunks. Once the selector returns eight,
adding eight preserves alignment, and each iteration checks remaining length.
The load/store helpers still perform relaxed atomic access to guest RAM.
There is no widened atomic access, vectorized guest access, changed lock,
removed fence, altered epoch load, or changed dirty/exclusive/code notification.

An initial constant-size branch was rejected because Clang merged it back into
the baseline machine code. A first separate-loop version added short-copy
overhead; it was replaced by reusing the existing chunk-width decision. In a
targeted eight-run rerun, seven-byte copy medians were 67.368 -> 66.977 ns
(one thread), 36.446 -> 33.526 ns (two split), and 38.194 -> 35.744 ns
(two shared). These are noisy microbenchmark results, not UI measurements.

## Correctness

The standalone harness compiles the selected memory implementation and its
matching private header directly. Six cache callbacks are spies, so no cache
or executor files need to be built or modified. The same harness runs against
the saved baseline and the retained candidate.

Coverage includes:

- 24,000 deterministic seeded hot-plus-fallback versus general-path operations,
  with independent expected values, final RAM/dirty-epoch comparison, widths
  1/2/4/8, unaligned and cross-page addresses, invalid widths and RAM bounds.
- Public bulk-copy differential checks across 16 alignments, 14 sizes up to a
  page, both observed and unobserved pages, output canaries, and page crossings.
  Writes are split into the API's supported maximum of 64 bytes.
- 2,048 guarded-buffer cases with inaccessible neighboring host pages, testing
  short and aligned chunks at exact source/destination ends.
- Host/bulk/exclusive flag union and stopped-VM clear/re-registration behavior;
  exclusive success, interference, pair conflicts, and same-value bulk writes
  invalidating reservations; acquire/release u16 API checks.
- Code generation changes and cache invalidation callbacks for scalar and bulk
  writes; shared TLBI mismatch, journal overflow, ASID and TTBR changes.
- 10,000 concurrent host-copy/guest-write coherence iterations and 2,000
  release/acquire handoffs between separate vCPU memory contexts, changing real
  four-level page tables and publishing full or VA-specific TLBI. The reader
  must reject stale hot entries and observe the new page. Read-only page-table
  permissions must suppress writes and the slow callback.
- 36 two-thread benchmark-shaped correctness scenarios plus the two handoff
  scenarios. Successful exclusive updates plus conflicts must equal attempts.

Optimized and UBSan builds pass **38,535 cases / 38 threaded scenarios**.
Guard pages are additional evidence, not a replacement for a working sanitizer.
ASan+UBSan attempts produced no output and were interrupted; UBSan alone passed.
TSan exited 139 with a segmentation fault before a useful diagnostic. This is
not a TSan clean bill of health. Instruction-level acquire/release and atomic
execution, actual cache behavior, integrated guest boot, graphics and UI remain
the parent's integration responsibility.

## Reproduction

Run from `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
sh scripts/native-memory-fastpath-run.sh --check
sh scripts/native-memory-fastpath-run.sh --check /tmp/avz-memory-baseline.eLV5A1/ARM64VizGuestMemory.c
sh scripts/native-memory-fastpath-run.sh --ubsan
RUNS=6 ITERATIONS=500000 sh scripts/native-memory-fastpath-run.sh --benchmark /tmp/avz-memory-baseline.eLV5A1/ARM64VizGuestMemory.c > /tmp/avz-memory-baseline.eLV5A1/retained.log
python3 scripts/native-memory-fastpath-summary.py /tmp/avz-memory-baseline.eLV5A1/retained.log
sh -n scripts/native-memory-fastpath-run.sh
git diff --check -- Sources/ARM64VizNative/ARM64VizGuestMemory.c
```

`MODE=bytes7`, for example, selects a targeted workload. `RUNS`, `ITERATIONS`,
and `CC` are configurable. `--asan` and `--tsan` are also available for the
parent's environment. Benchmark order alternates baseline/current on each run;
both binaries pass the correctness suite before timing. No privileged affinity
or scheduler tuning is used.

## Measurement Interpretation

Host: Darwin 25.5.0 arm64, Apple clang 17.0.0 (clang-1700.6.3.2), `-std=c11 -O3
-Wall -Wextra -pthread`. CPU model discovery via sysctl was denied. Other agents
were compiling concurrently, so these are rough initial measurements for a
serial parent rerun. The harness includes the implementation in one translation
unit to test internal helpers; inlining and cache spies mean absolute costs do
not represent the integrated executor.

Reported ns/iteration = wall time / (threads * iterations). For two threads it
is reciprocal aggregate throughput, **not individual request latency**. The
start gate and thread join are timed; allocation, setup and thread creation are
not. Control-loop results estimate part of the harness overhead, and are not
subtracted. Every worker has a private fast-path/context and shares guest RAM.
Split mode uses regions one MiB apart; shared mode uses the same region.

Scalar iterations perform one eight-byte load plus one store across 64 cache
lines. The working-set mode covers 256 KiB (64 pages). Native mode uses enabled
stage-1 translation through a valid 1 GiB block mapping. Hot-stats enables
detailed counters only in the harness. Bulk iterations read N bytes then write
N bytes in <=64-byte API calls; the 256-byte case has one read and four writes.
The unaligned 64-byte case starts at offset three. Host-copy performs a real
256-byte copy under page locks, with a compiler barrier to prevent elision.
Metadata isolates repeated publication; exclusive attempts may legitimately
fail and are counted. Plain load/store increments are not atomic RMWs.

### Retained Candidate Results

Raw log: `/tmp/avz-memory-baseline.eLV5A1/retained.log`. Six alternating runs,
500,000 iterations per worker. Entries are baseline -> candidate medians in
ns/iteration. These are the final production-code version, not the earlier
candidate's larger apparent gains.

| Workload | One thread | Two split | Two shared |
| --- | ---: | ---: | ---: |
| Control overhead | 1.307 -> 1.275 | 0.658 -> 0.641 | 0.645 -> 0.639 |
| Hot scalar | 17.771 -> 18.237 | 8.827 -> 9.567 | 11.136 -> 11.963 |
| Hot, counters on | 17.643 -> 18.780 | 8.930 -> 9.484 | 11.155 -> 12.008 |
| 256 KiB working set | 18.557 -> 18.797 | 8.915 -> 9.672 | 10.278 -> 10.498 |
| Native stage-1 hot | 18.955 -> 18.987 | 10.074 -> 9.599 | 12.136 -> 12.465 |
| General scalar API | 43.546 -> 41.499 | 21.907 -> 21.977 | 17.798 -> 18.285 |
| Host-observed scalar | 50.613 -> 51.011 | 25.621 -> 25.880 | 119.785 -> 130.435 |
| Unaligned scalar | 51.655 -> 54.739 | 27.215 -> 27.913 | 138.416 -> 144.932 |
| 1-byte copy | 40.646 -> 41.222 | 20.570 -> 22.227 | 21.480 -> 22.079 |
| 7-byte copy | 58.914 -> 59.495 | 29.469 -> 29.977 | 30.646 -> 29.346 |
| 8-byte copy | 41.489 -> 42.019 | 20.700 -> 21.398 | 20.922 -> 22.068 |
| 16-byte copy | 45.470 -> 43.130 | 22.507 -> 21.761 | 23.013 -> 22.484 |
| 64-byte copy | 71.068 -> 49.704 | 35.356 -> 25.174 | 36.167 -> 25.822 |
| Unaligned 64-byte copy | 108.003 -> 81.800 | 54.291 -> 41.119 | 59.398 -> 42.398 |
| 256-byte copy | 247.773 -> 163.342 | 125.628 -> 88.594 | 129.200 -> 95.866 |
| Exclusive attempt | 48.013 -> 52.193 | 132.867 -> 150.861 | 256.298 -> 284.804 |
| Locked host copy | 12.801 -> 14.040 | 6.503 -> 6.988 | 69.388 -> 76.846 |
| Observation metadata | 3.214 -> 3.531 | 1.643 -> 1.842 | 11.913 -> 13.283 |

The changed helpers reduce median 64-byte iteration time by 28.6-30.1%, unaligned
64-byte iteration time by 24.3-28.6%, and 256-byte iteration time by 25.8-34.1% in this
run. The one-thread 256-byte ranges were 230.662-267.670 ns baseline versus
139.734-193.942 ns candidate. The two-shared 256-byte ranges were
126.603-157.325 versus 79.056-154.862 ns, illustrating substantial noise.

Contention remains significant: candidate host-observed scalar changes from
25.880 ns two-split to 130.435 ns two-shared, exclusive attempts from 150.861
to 284.804, and observation metadata from 1.842 to 13.283. Detailed-statistics
overhead is not resolved reliably by this run (18.237 versus 18.780 ns
one-thread, but two-thread medians fluctuate). The control loop is only a
partial overhead estimate, not a complete decomposition of all dispatch logic.

Do not hide the worse medians: unchanged exclusive split/shared workloads were
13.5%/11.1% slower in this sweep, and unchanged host-copy shared was 10.7%
slower. Even the unchanged isolated metadata mode was about 10-12% slower.
Standalone `-O3` assembly's first difference from baseline is in the bulk-read
function, after the scalar/exclusive routines. These observations are
consistent with substantial host/scheduling noise, but do not prove its cause
or rule out code-layout effects. The parent must rerun serially, especially
short copies and these negative controls; this is not an unconditional
performance-regression-free signoff.

No whole-UI speedup, frame-time improvement, or integrated regression-free claim
is made. Repeated functional checks found no correctness regression. Performance
differences outside the changed copy helpers require a serial rerun before any
broader conclusion or runtime-default change.
