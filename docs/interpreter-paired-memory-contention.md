# Native Layout Isolation and Epoch/Ticket Checks

## Scope

2026-10-26 follow-up to `interpreter-paired-memory-performance.md`. The earlier
report describes historical pair-only evidence; its runner/build description
does not describe the updated runner. This comparison is **frozen baseline
versus the current native implementation, not pair-only or padding-only**.

Changed in this follow-up only:

- `scripts/native-pair-memory-run.py`
- `scripts/native-pair-memory-contention.c` (new)
- `docs/interpreter-paired-memory-contention.md` (new)

The parent owns the production padding and offset assertions. No production
files, existing pair fixtures, public headers, Swift files or runtime defaults
were edited by this follow-up. No timing benchmarks, Swift/Xcode builds, guest
builds or Simulator operations were run.

## Consistent Builds

The immutable reference remains
`/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative`.
The runner snapshots each version's executor, cache, guest memory, prototype,
private header and public headers into its own source directory. It checks
hashes before/after copying to detect concurrent edits during collection.
Each version compiles its own objects, constructor and harness against only
that version's headers; no frozen object is reused by the candidate. In
particular, quoted private includes cannot resolve through a frozen source
directory when building the candidate. Baseline source files are not modified.

The prototype compile flag is explicitly zero for both versions, preserving
the previous pair runner's configuration. This does not test optional threaded
memory dispatch; the pair harness still exercises the real cached native chain.
Other current executor/cache/memory changes are included and must not be
attributed to the pair optimization or padding alone.

Each evidence directory retains source snapshots, per-version objects, binaries,
compiler version, complete commands/output, correctness output, probes and
SHA-256 hashes of all sources/headers/objects/binaries. Nonempty output directories
are rejected rather than overwritten.

## Focused Contention Harness

All objects use the real version-specific `avz_guest_memory_create`/destroy.
Four workloads run: one epoch reader, one ticket writer, both threads sharing
one memory object, and both threads using separate objects. A mutex/condition
gate starts ready workers; there is no additional synchronization in the loops.

The reader performs the existing acquire load on `code_mutation_epoch`. The
writer models the existing acquire-release fetch-add on
`current_write_generation`, not a full guest store. Every observed epoch must
equal one; every fetched ticket must equal its expected sequence; final ticket,
code epoch, translation epoch and the public epoch getter/token are checked.
Worker results are read only after joining. No epoch checks or ordering are
removed from production.

Default runs are correctness-only: four workloads, 50,000 iterations per worker,
150,000 epoch reads and 150,000 ticket increments per binary. Timing requires
`--benchmark`; `--contention-only` limits execution to the new harness. The
runner alternates baseline/candidate order across repeated rounds, validates
identical non-timing results, and saves raw timings and medians.

## Results

Normal (`-O3`) and UBSan (`-O1 -g -fsanitize=undefined
-fno-sanitize-recover=all`) both passed, for both versions:

```text
PASS cases=13109 digest=8f097d8756b4b775
PASS contention cases=4 iterations=50000 reader_checks=150000 ticket_updates=150000 epoch=1 writer_final_ticket=50001 mismatch=0
```

No compiler warnings or sanitizer diagnostics were emitted. Candidate source
snapshots from the two runs compare identical with `diff -qr` (exit zero).
The pair probe remains 2,000/2,000 baseline versus 1,000/1,000 candidate
read/write TLB hits, with 2,000 element reads/writes and zero new walks each.

| Layout property | Frozen baseline | Current candidate |
| --- | ---: | ---: |
| `sizeof(AVZGuestMemory)` | 1216 | 1472 |
| `_Alignof(AVZGuestMemory)` | 8 | 8 |
| Write-ticket offset | 112 | 112 |
| Code-epoch offset | 120 | 248 |
| Translation-epoch offset | 128 | 384 |
| Sampled ticket/code same 64-byte line | 1 | 0 |
| Sampled ticket/code same 128-byte line | 1 | 0 |
| Sampled code/translation same 128-byte line | 1 | 0 |

The line-sharing probes use separately allocated objects, not the allocations
inside later timing runs. They are structural evidence, not a speed result.
Padding adds 256 bytes without increasing the allocation's alignment requirement.

Evidence: `/tmp/native-pair-memory-layout-check-20261026` (3.4 MiB) and
`/tmp/native-pair-memory-layout-ubsan-20261026` (8.5 MiB). Apple clang 17.0.0,
clang-1700.6.3.2, target arm64-apple-darwin25.5.0. No correctness failures occurred
in these two runs. Initial inspection tried a nonexistent `.sh` runner; the
actual runner is Python. No timing mode was executed or validated dynamically.

Selected SHA-256 identities (complete manifests are `hashes.json` in each run):

| File | SHA-256 |
| --- | --- |
| Runner | `56752f3a1c2108dae82548663c53eb9957f332dc2940e663f29bc65ba62ccea1` |
| Contention harness | `75d137d6573555c2dc421be6cbc3db4d3fee44f5a1709a9a6b005146419394f5` |
| Candidate private header | `ae1d82fd71356eb0ff270d50e3daa5a886eecaeb863322a6eaa1735a3832acb9` |
| Candidate guest memory | `d2233c3b054b0cbffcd28e36ceb46451a2424ed4b3db590f2be1841994649266` |
| Candidate executor | `de77d923f66e1b1f14fd7771ff28a442f1d725e31a58b8cec63430c5a5bbec16` |
| Candidate cache | `7f18bbe2ee29157fd6d1aad8a09ae1273a999616013acc6a5ec195de87159e12` |

## Commands and Limits

Executed from `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
python3 scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --output /tmp/native-pair-memory-layout-check-20261026
python3 scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --ubsan --output /tmp/native-pair-memory-layout-ubsan-20261026
diff -qr /tmp/native-pair-memory-layout-check-20261026/candidate-source /tmp/native-pair-memory-layout-ubsan-20261026/candidate-source
```

Parent-only serial timing command, after profiling ends (fresh output required):

```sh
python3 /Users/gmoran/Documents/Projects/arm64viz/scripts/native-pair-memory-run.py /tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative --contention-only --benchmark --rounds 8 --steps 8000000 --output /tmp/native-pair-memory-epoch-parent-serial
```

Omit `--contention-only` to include mixed-memory and cached-chain timing too.
This snapshots the then-current candidate; compare its manifest with this
report before attributing results. The benchmark measures total worker completion
time including gate release/wakeup and joins, but excluding creation/allocation.
Threads are not pinned, simultaneous execution is not guaranteed, and the
reader may finish before the writer. It does not measure sustained per-reader
latency, actual guest exclusive traffic, translation-journal traffic, or UI
latency. Single-thread and separate-object controls expose some scheduling and
atomic-operation overhead, not all machine noise. UBSan is not a race detector.
Serial parent measurements are still required; no performance gain is claimed.
