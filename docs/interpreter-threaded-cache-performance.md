# Threaded Auxiliary Cache Churn

## Scope And Result

**Current revision: FIFO, handed off to parent validation. This agent has not
built or run tests for the FIFO revision.** The parent reports integration
validation passes and has started the 2,000,000-iteration FIFO comparison; see
the handoff status below. Earlier LRU results are not FIFO validation.

Task 4, 2026-10-26. This changes only `ARM64VizBlockCache.c` and adds the
`scripts/threaded-cache-churn-*` harness/runner plus this report. No public header,
Swift, instruction implementation, memory implementation, code-validity predicate,
guest, device, or runtime default was changed.

The frozen comparison is `/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative`,
not git HEAD. The revised runner snapshots that directory for the baseline and
separately snapshots `CHURN_CANDIDATE_NATIVE` (default: current native sources)
for the candidate, including each tree's own headers, Native, GuestMemory, and
ThreadedPrototype. The frozen baseline is never edited. This supports the
parent's current memory-aware prototype without injecting stubs or altering
frozen inputs. Cross-tree timing includes all dependency changes and must not
be attributed solely to FIFO. The historical runs below used identical frozen
dependencies for both caches.

Deterministic work counts establish less auxiliary-cache churn in these synthetic
streams. **No application or interpreter throughput gain is claimed.** The
2,000-lookup correctness runs happened while other implementation workers could
be active. Raw CPU timings are retained for transparency, not interpreted as
performance evidence. Settings icon launch, guest coverage, and integrated serial
benchmarking remain the parent's work. These streams model locality and sparse
eligibility; they are not captured guest traces or calibrated coverage models.

## Implementation And Invariants

- Keep the existing cap of **256 programs per cache/vCPU**, with global FIFO
  replacement. Each slot has an owner, immutable program, and two 16-bit links.
  Decoded entries have a one-based slot back-reference, so hits and replacement
  are constant-time, without a hash probe or serial lookup. Positive hits no
  longer touch the replacement list. Only insertion/free-slot maintenance moves
  slots; free slots precede live slots, and the oldest live insertion is evicted.
  Internal `threaded_lru`/helper names are retained to minimize production diff.
- Cache eligibility in decoded-entry lifetime: unknown, register-supported,
  unsupported, allocation failure, or memory-supported (parent's class 4).
  The existing class-4 `allow_memory` gate is unchanged, including when a
  program is already allocated. Unsupported blocks do not consume capacity.
  A supported entry evicted from the auxiliary cache retains its eligibility,
  avoiding another adapter eligibility scan when reconstructed. Program creation
  still performs its original decoding/support work.
- Allocation failure returns NULL, allowing the existing C path; it is negatively
  cached until decoded-entry invalidation/replacement/clear. This intentionally
  suppresses allocation retry storms. Unlike the baseline, unrelated auxiliary
  collisions do not trigger retries. No guest instruction or failure semantics
  depend on successful auxiliary allocation.
- Entry invalidation, stale discard, and decode-cache replacement detach and free
  owned programs before reuse. Auxiliary replacement clears the old entry's
  back-reference. Clear/destroy free every program. Eviction precedes creation,
  including transient ownership, keeping the bound at 256.
- Every eligible lookup still passes through the original
  `avz_entry_code_is_current` predicate **before** positive or negative reuse.
  Local/shared code generations and mapping/TLBI checks are unchanged. Failed
  validation also detaches the program and forgets eligibility. Lazy generation
  invalidation may leave an unexamined allocation resident, but it cannot be
  returned without the existing validity check.
- As before, callers must exclusively own a stopped/nonconcurrently-mutating
  cache/vCPU while changing ownership. Returned programs must not be retained
  across cache mutations. No locking or cross-vCPU ownership was introduced.
- Ownership does not depend on serial uniqueness. A forced serial wrap/recycle
  can no longer revive a stale auxiliary program. Existing serial contracts for
  successor links are unchanged and outside this task.

An initial 64-set, four-way LRU prototype was **rejected**: five forced same-set
entries reconstructed 2,000 programs where the frozen direct cache needed five.
Global replacement eliminates that artificial conflict. Its remaining
replacement pressure is actual capacity. The FIFO revision removes only the
positive-hit touch from production behavior; validation, ownership cleanup,
negative caching, class 4, and allocation bounds are otherwise preserved.

## Historical LRU Counts

All streams perform 2,000 adapter lookups over decoded eight-instruction blocks.
Hot uses 32 supported entries. Direct collision uses four entries separated by
256 decoded positions. Four-way collision uses five positions hashing into one
set of the rejected policy. Negative collision uses four unsupported blocks with
the old direct-slot collision. Mixed uses 90% references to a 64-entry hot set,
10% to a sequential 3,072-entry cold set, with 75% unsupported blocks (YIELD).
Capacity visits successive supported entries. Supported execution is sampled;
every lookup's supported/unsupported result is asserted.

| Stream | Baseline scans | LRU scans | Baseline creations | LRU creations |
| --- | ---: | ---: | ---: | ---: |
| Hot | 32 | 32 | 32 | 32 |
| Direct collision | 2,000 | 4 | 2,000 | 4 |
| Four-way collision | 5 | 5 | 5 | 5 |
| Negative collision | 2,000 | 4 | 0 | 0 |
| Mixed hot/cold | 325 | 264 | 82 | 66 |
| Capacity | 2,000 | 2,000 | 2,000 | 2,000 |

Mixed LRU diagnostics: 484 positive hits, 1,252 negative hits, zero capacity
replacements. Capacity LRU diagnostics: 1,744 replacements, peak 256 programs.
Positive-result counts and checksums match the baseline for all six streams.
Diagnostics enabled/disabled have identical deterministic results.

## Historical Memory Bound

Measured with Apple clang 17.0.0, arm64-apple-darwin25.5.0:

| Object | Frozen | LRU |
| --- | ---: | ---: |
| Decoded entry | 944 B | 944 B |
| Enabled cache, diagnostics off | 135,624 B | 137,680 B |
| Enabled cache, diagnostics on | n/a | 137,736 B |
| Prototype-disabled cache | 131,528 B | 131,528 B |

Eligibility/back-reference use existing decoded-entry tail padding on this ABI;
there is no per-decoded-entry allocation. Additional enabled-cache storage is
2,056 B, plus 56 B with diagnostics. Maximum frozen program payload for a
16-instruction block is 1,240 B, so 256 program allocations total at most
317,440 B of requested payload (allocator overhead excluded). The eight-instruction
capacity stream reaches 169,984 B. Other agents' program-layout changes can
change payload bytes, but not the 256-program bound; rerun the size probe after
integration.

## Diagnostics And API Proposal

Define `AVZ_THREADED_CACHE_DIAGNOSTICS=1` when compiling the cache to opt in.
Default is zero: counter fields and increments compile out, with no runtime
diagnostics flag checks. Private counters are `hits`, `negative_hits`,
`collisions`, `creations`, `destructions`, `eligibility_scans`, and
`allocation_failures`. Here `collisions` means a full-capacity replacement;
there are no hash collisions in the final policy. Counts persist across clear
and are cumulative over cache lifetime. Destruction counters count non-NULL
allocations, not calls to destroy(NULL).

The standalone harness includes the cache translation unit and validates its
counters against independent wrappers. No public API is required to integrate
this patch. Proposed parent-owned follow-up, if runtime reporting is needed:
`AVZNativeThreadedCacheStatistics avz_native_block_cache_threaded_statistics(const AVZNativeBlockCache *)`,
with the seven uint64_t counters above plus a diagnostics-enabled field. It
should return zeros when disabled and require stopped-vCPU ownership to read;
do not add atomics to the hot path. No header or Swift changes are included here.

## FIFO Test Revisions (Not Run By This Agent)

The harness now asserts that a positive hit leaves the FIFO head and all links
unchanged, then evicts the oldest insertion despite that hit. It still checks
ring integrity, the 256-allocation bound, ownership detachment, and free-slot
reuse. When both the candidate source and its snapshotted header expose the
memory-aware API, additional tests cover class-4 rejection without memory,
creation with memory, rejection even when cached, eviction/recreation without
rescanning, and resetting classification on a new decoded lifetime. These test
adapter eligibility and ownership, not memory execution semantics. Additional
memory-support predicate calls are reported separately as `memory_supports`.

The runner's default candidate dependencies are now current, so the older LRU
cache snapshots must not be paired with the revised FIFO-order harness. Replay
historical LRU results with their original archived runner and harness instead.

## Historical Tests And Evidence

Enabled correctness and UBSan (`-fsanitize=undefined -fno-sanitize-recover=all`)
exercise diagnostics on/off, forced collisions, negative caching, code/shared
generation rejection, mapping rejection, physical invalidation, stale discard,
public decode-cache eviction, clear/destroy, program allocation failure and
recovery after invalidation, actual nonzero serial allocator wrap, LRU ordering,
ring integrity, and free-slot reuse. Prototype-disabled builds also exercise
cache create/invalidate/clear/destroy and disabled program creation.

Historical LRU evidence directories contain raw commands/stdout/stderr, full source and
binary SHA-256 identities, compiler identity, and the exact copied sources:

- `/tmp/pinecone-threaded-cache-churn-final-check-task4`
- `/tmp/pinecone-threaded-cache-churn-final-ubsan-task4`
- `/tmp/pinecone-threaded-cache-churn-final-disabled-task4`

The rejected four-way candidate is preserved in
`/tmp/pinecone-threaded-cache-churn-check-task4` with its raw adverse counts.
No candidate correctness failure was observed. The baseline's forced serial
recycling test reports `known_baseline_serial_recycling_stale=1`; this is an
explicit expected baseline defect, not counted as a candidate pass or silently
ignored. It requires forced wrap/reuse in the harness and is not evidence that
the real guest reached serial exhaustion. No full Swift/Xcode build or integrated
guest run was performed.

Historical LRU input SHA-256 values (not the current FIFO sources):

```text
c8d181bad0da1bb89f39ab77d9f8cb988d9c97fad65222210d3acc995b8e7122  frozen ARM64VizBlockCache.c
fc085f450baded682a48cd7bcb65c79d7057e1e106049511f8fc4b88411e3465  candidate ARM64VizBlockCache.c
d4409d07012afe1563c3137c2a29d0d57df7d48bd3be5a575914134258a2617c  frozen ARM64VizNative.c
cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f  frozen ARM64VizGuestMemory.c
cfe4fcd11bef6c7b67d54edd3c3d30b3b936a29d4c883315cd382c6a91623a74  frozen ARM64VizThreadedPrototype.c
14803d3483fe0c05979491d2da93b67888c8b5aa7c49fac0a7dc08a6dac2f4b1  threaded-cache-churn-harness.c
5bec7e34ddfe2e4efb4239671c15103d4379d140a0a2e550e268a62c9cf69008  threaded-cache-churn-run.sh
```

## Parent Serial Assessment

The parent's 200,000-lookup serial run is archived in
`/var/folders/1f/ktctp6mx2176_6k6ggnlrrch0000gn/T/pinecone-threaded-cache-churn.QWXpO9/raw.txt`.
Diagnostics-off LRU versus frozen baseline: hot +12.3%, five-entry collision-free
+122.9%, mixed +22.8%, capacity +11.7%. Forced direct collisions improved strongly.
These short, single-order measurements do not establish stable effect sizes,
but do not justify accepting true LRU as a performance improvement. FIFO targets
hit-path list writes; it cannot by itself fix the zero-hit capacity regression.
Its replacement behavior may also increase allocations in some mixed streams.
No completed FIFO timing result has been assessed here.

## Parent Handoff Status

At the latest handoff, the parent reports these validation passes:

- Full Swift: 653.
- Prototype, normal and UBSan: 507,622.
- Integrated: 3,136.
- Validation and pair: 13,109.

These are parent-reported suite counts, not reruns or independently verified
results from this agent. They do not establish a FIFO performance gain.

The parent has started the current code/harness/runner snapshot comparison with
**2,000,000 iterations** at `/tmp/threaded-cache-fifo-parent-final`.
Its `manifest.txt` and `raw.txt` are the authoritative input identities and
results once the run completes. No completion or timing outcome is claimed in
this handoff. Production, harness, and runner edits are finished; this status
update changes only the report.

To reproduce that exact snapshot after the parent run has captured its inputs,
use a fresh output directory (the runner selects one when unset):

```sh
evidence=/tmp/threaded-cache-fifo-parent-final
BASELINE_NATIVE="$evidence/frozen" \
CHURN_CANDIDATE_NATIVE="$evidence/candidate-native" \
CHURN_CANDIDATE_SOURCE="$evidence/candidate.c" \
CHURN_HARNESS_SOURCE="$evidence/harness.c" \
CHURN_ITERATIONS=2000000 \
sh "$evidence/runner.sh" --bench
```

## Exact Reproduction After Measurements

**Parent only, after Simulator observations finish and source edits stop.** First
capture and check a current memory-aware candidate against the frozen baseline.
Use an empty/nonexistent output directory; the runner refuses nonempty ones:

```sh
BASELINE_NATIVE=/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative \
CHURN_CANDIDATE_NATIVE=/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative \
CHURN_OUTPUT=/tmp/pinecone-threaded-cache-fifo-parent-check \
sh /Users/gmoran/Documents/Projects/arm64viz/scripts/threaded-cache-churn-run.sh --check
```

Then run UBSan, prototype-disabled correctness, and the serial benchmark against
those exact captured sources, not later workspace contents:

```sh
evidence=/tmp/pinecone-threaded-cache-fifo-parent-check
for mode in --ubsan --disabled --bench; do
    BASELINE_NATIVE="$evidence/frozen" \
    CHURN_CANDIDATE_NATIVE="$evidence/candidate-native" \
    CHURN_CANDIDATE_SOURCE="$evidence/candidate.c" \
    CHURN_HARNESS_SOURCE="$evidence/harness.c" \
    CHURN_ITERATIONS=200000 \
    sh "$evidence/runner.sh" "$mode" || break
done
```

Each invocation prints a fresh evidence directory. `manifest.txt` records all
copied source/header SHA-256 identities, compiler identity, flags, and dependency
provenance; `raw.txt` retains exact build commands, binary hashes, and results.
Sources remain separate from generated object directories, allowing replay of
the captured runner with the environment above. Baseline uses frozen dependencies;
candidate diagnostics on/off share the same candidate dependency objects. Both
dependency sets and all three executables are built/run serially.

This intentionally tests complete source revisions, not an isolated replacement
policy. Do not compare memory-aware candidate timings to the old LRU run and
attribute the difference solely to FIFO. Harness wrappers add overhead even
with diagnostics off. Integrated serial execution and icon-launch measurements
remain necessary. This agent has not executed the commands in this section.
