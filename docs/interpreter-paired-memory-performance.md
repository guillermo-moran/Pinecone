# Paired Native Memory: Same-Page Translation Reuse

## Scope

Task 1, 2026-10-26. Read
`docs/interpreter-simulator-performance-2026-10-26.md` before implementation.
The reported Settings launch and mapped-executor samples motivate targeting the
existing native LDP/STP helpers, not claiming a UI improvement from a small
prototype or a microbenchmark.

Changes made by this workstream:

- `Sources/ARM64VizNative/ARM64VizGuestMemory.c`: pair-only hot span lookup.
- `scripts/native-pair-memory-harness.c`: differential fixtures, concurrency
  checks, untimed work-count probe and opt-in mixed/cached-chain benchmarks.
- `scripts/native-pair-memory-run.py`: frozen-dependency builds, digest checks,
  raw logs, exact hashes and alternating serial benchmark support.
- `docs/interpreter-paired-memory-performance.md`: this report.

No changes to the private header, public headers, executor, cache, Swift,
graphics, CPU/RAM defaults, guest images, Simulator or devices. No JIT, QEMU,
Swift fallback, commits, resets, or reverts. The prior bulk-copy improvement is
present in both frozen baseline and candidate and is preserved byte-for-byte.

Before editing, `cmp` confirmed both owned memory files exactly matched
`/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative`. That immutable
snapshot, not git HEAD or another agent's current sources, is the reference.

## Implementation and Invariants

`avz_native_fast_memory_translate_pair` tries a combined translation whose
width is twice the element width. Four-byte elements already obtain one
eight-byte translation. Eight-byte elements request sixteen, which the scalar
translator rejects, so a warm 64-bit pair previously performed two full
eight-byte translation lookups.

The candidate adds a hot-entry-only case for eight-byte elements entirely
inside one virtual page. It performs the existing shared-epoch synchronization,
then validates the hot generation, virtual page, current low/high context tag,
non-null RAM/host mapping, full sixteen-byte contiguous span, and physical
address addition. Both element pointers are derived only after this proof.

- Shared TLBI publication/consumption locks, journal ordering, generation
  invalidation and ASID/TTBR context handling are unchanged. The hot-generation
  certificate already represents ASID/TLBI validity. A concurrent invalidation
  is handled by the same existing single-span protocol used for 32-bit pairs;
  there is no global check elision or new synchronization protocol.
- The contiguous span is populated/clamped by the existing translation path.
  A short RAM tail cannot certify the second element. No sixteen-byte scalar
  access is enabled and translation callbacks never receive a new width.
- A cold entry, stale entry, non-RAM mapping, insufficient span or page crossing
  retains the original fallback with independent translations. In particular,
  the second page still receives its own permission/fault checks before either
  element is copied. A failed pair does not partially write or alter outputs.
- `read_pair` and `write_pair` are untouched. Natural alignment checks,
  per-range observation checks, sorted page-stripe locks, two scalar atomic
  loads/stores, exclusive invalidation, dirty epochs, executable generations and
  cache invalidation are unchanged. LDP/STP does not become a 128-bit atomic RMW.
- 32-bit pair behavior is unchanged. Hot 64-bit pairs now count one
  `read_tlb_hits`/`write_tlb_hits` event for their single span lookup, like the
  existing 32-bit path. Element `read_hits`/`write_hits` remain two per pair.

The change is 34 added C lines relative to the supplied frozen baseline.
No cross-file API requirement exists. The cold path now attempts an additional
hot-span probe before the old fallback; the benchmark includes a cold control
to expose its cost. Acceptance awaits the parent's serial measurements.

## Correctness and Work Counts

The harness links real **frozen** `ARM64VizNative.c` and
`ARM64VizBlockCache.c` objects with either frozen or candidate memory. It uses
separate translation units, rather than whole-implementation inclusion or cache
test doubles. Public and private dependency headers come from the snapshot;
the runner refuses to silently mix private structure layouts. It copies and
hashes the candidate and harness before building and will not overwrite a
nonempty evidence directory.

Coverage:

- 4,096 matrix cases: four mapping configurations (callback identity plus
  native noncontiguous, second-page read-only and second-page unmapped), both
  widths 4/8, warm/cold access, observed/unobserved RAM, code/data pages, and
  starts at offsets 0-31 and 4072-4103. This covers alignment, adjacent elements
  across a boundary and individually cross-page elements. Full surrounding
  32 KiB RAM canaries, read values/output sentinels, fault address/access/level/
  status, write/code generations and no-pair-fallback-callback behavior are
  checked and hashed against the frozen binary.
- Short final RAM page, unsupported width, null arguments and virtual overflow.
  ASID, TTBR0, TTBR1/high addresses, targeted ASID invalidation, and a 65-entry
  TLBI journal overflow with actual page remapping.
- 4,000 observed pair writes concurrent with a host reader taking the same
  range lock; every observed pair must be complementary, never torn.
- Two vCPU contexts exercising exclusive-pair success and invalidation by
  same-value ordinary pair writes at both widths. Two real threads perform
  4,000 total successful exclusive increments alongside ordinary pair writes;
  the shared counter must equal 4,000, with both final pairs verified.
- 1,000 two-vCPU release/acquire handoffs that mutate a real four-level page
  table and publish full or VA-specific TLBI; the peer's pair must resolve to
  the newly published page and values.
- Six bounded mixed-memory correctness workloads and an 8,192-instruction
  cached-chain correctness run with actual native decoding, instruction
  translation, cache validation, checkpoint callbacks and superblock dispatch.

Final optimized result, baseline **and** candidate:

```text
PASS cases=13109 digest=8f097d8756b4b775
```

Final UBSan builds (`-O1 -g -fsanitize=undefined
-fno-sanitize-recover=all`) pass with the identical case count/digest for both
variants and no sanitizer diagnostic. The untimed probe also matches the table
below under UBSan.

Untimed 1,000-iteration warmed 64-bit pair read/write probe:

| Counter | Frozen baseline | Candidate |
| --- | ---: | ---: |
| read_tlb_hits | 2000 | 1000 |
| write_tlb_hits | 2000 | 1000 |
| read_hits | 2000 | 2000 |
| write_hits | 2000 | 2000 |
| new translation walks | 0 | 0 |

This establishes reduced lookup work, **not a latency or throughput gain**.
No timing benchmark was run while other agents were active.

Early harness failures were preserved, not hidden: warm-up scalar accesses can
legitimately call the fallback, so their counters needed resetting before the
pair assertion; the cached-chain API requires a non-null checkpoint/positive
interval; and instruction fetching requires an explicit instruction translator.
These baseline-only fixture failures occurred before candidate execution.
The first UBSan attempt reached the same missing-translator fixture failure,
not a sanitizer finding. Raw failed-run directories are
`/tmp/native-pair-memory-check-20261026`,
`/tmp/native-pair-memory-check-v2-20261026`,
`/tmp/native-pair-memory-check-v3-20261026`, and
`/tmp/native-pair-memory-ubsan-20261026`.

## Evidence and Identities

Final optimized evidence:
`/tmp/native-pair-memory-final-check-20261026`.
Final sanitizer evidence:
`/tmp/native-pair-memory-final-ubsan-20261026`.
Each contains `commands.log`, `compiler.txt`, `hashes.json`, both correctness
outputs, both untimed probes, the exact harness/runner/candidate snapshots and
binaries. The manifest includes every linked source and public header.
Compiler: Apple clang 17.0.0 (clang-1700.6.3.2), arm64-apple-darwin25.5.0.

SHA-256 identities:

| Input | SHA-256 |
| --- | --- |
| Frozen memory C | `cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f` |
| Candidate memory C | `e3d9b1408acf715c88cd312c02264c3eff13f6d190a02dc90c3c9eae5ae0d491` |
| Unchanged private header | `33a2e4771c8da43800357e022cfafdd1aa289b5fcca53b9c95b5ae37d35c3622` |
| Frozen executor C | `d4409d07012afe1563c3137c2a29d0d57df7d48bd3be5a575914134258a2617c` |
| Frozen cache C | `c8d181bad0da1bb89f39ab77d9f8cb988d9c97fad65222210d3acc995b8e7122` |
| Harness | `01d97b6f19869046defdcc19ce442865e0c77ef9c9aaaea260cc89dde0d19e6b` |
| Runner | `891d25b5653571cc1493f61fafce592adee33bc85c3a3203cb75e727301f48db` |
| Optimized baseline binary | `ae518e56cbab824025fd87cde6267e7e91010426069e7a6e53878370edf9031d` |
| Optimized candidate binary | `9c4a171908b7026d6522b61eea09a9262c905e5708299dd65abbf44038236374` |

## Commands and Parent Benchmark

Executed from `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
python3 scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-pair-memory-final-check-20261026
python3 scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --ubsan --output /tmp/native-pair-memory-final-ubsan-20261026
git diff --check -- Sources/ARM64VizNative/ARM64VizGuestMemory.c
```

Exact **parent-only serial benchmark** command, from any directory (use a fresh
output directory):

```sh
python3 /Users/gmoran/Documents/Projects/arm64viz/scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --benchmark --rounds 8 --steps 8000000 --output /tmp/native-pair-memory-parent-serial
```

Both correctness binaries run before timing. Eight baseline/candidate rounds
alternate order. Raw output goes to `benchmark.txt`; `summary.txt` gives median
time changes. Each workload checks identical checksums, retirement and chain
metadata between all runs and variants. Source/binary hashes are persisted.

Mixed workloads use one pair read, one pair write, one scalar read and one
scalar write per iteration over 256 cache lines: 64-bit, 32-bit, unaligned,
observed, page-crossing and cold controls. The cached-chain workload executes
four linked eight-instruction blocks: LDP, two arithmetic instructions, STP,
scalar LDR/arithmetic/STR, and a branch. It requires superblock dispatch and
checkpoints and verifies RAM values against completed loop iterations. This
uses the existing native cached-chain path; the experimental subset is not
enabled by the harness. It is a controlled workload, not a guest instruction
distribution captured from Settings.

The parent should reject or refine the change if the mixed/cached-chain gain
does not offset cold-path overhead. After integrating other workstreams, repeat
native-only guest runs and actual Settings icon launches using the parent's
controlled setup. Preserve the frozen baseline and CPU/RAM/guest inputs.
Standalone tests do not establish whole-guest/UI correctness or performance,
and UBSan is not a data-race detector. No UI-speedup or performance-regression-
free claim is made here.
