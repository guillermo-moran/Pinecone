# Phase 6: Indirect Branches

Status: isolated assembly expansion; not installed or linked into the app.
The one production-source correction is BLR x30 target/link ordering in both C
execution handlers. Installed Pinecone remains unchanged. Phase 6 is open.

## Implementation

- Basic BR, BLR and RET capture the source before updating LR. Register 31 is
  XZR, not SP. Pointer-authenticated forms remain unsupported by this subset.
- A branch commits the target PC, retires exactly once and performs the existing
  generation/budget checks before target lookup. Missing or misaligned targets
  return OUTSIDE_BLOCK, preserving the target for the outer fetch/fault layer.
  No instruction-fetch exception delivery is newly implemented here.
- Lookup is an inline bounded binary search over immutable, sorted, owner-pinned
  ranges. A program has one range; a chain has at most 256. Results select
  operation data, never guest-controlled executable host addresses.
- Every chain target, including self-loops and interior instructions, lands on
  an existing service gate. Event and block limits cannot be bypassed.
- Target tables are retained with their parent until execution returns.
  Callback retirement/reentrancy and peer invalidation keep the existing
  lifetime rules. No extra C calls, stack frames or x18 use are introduced.

Per-operation size stays 48 bytes. Each program header grows by 8 bytes.
Chains additionally own a 24-byte range per block and an 8-byte table pointer.
Assembly __TEXT grows from 41,456 to 41,796 bytes (+340). These are real entry
and metadata costs to measure, not a claim that broader coverage is free.

## C Correctness Fix

Both the generic and computed-goto C handlers previously wrote x30 before
reading Rn. Consequently BLR x30 branched to the new return address rather than
the old x30 target. Both now capture the target first. Independent expectations
cover normal, zero, misaligned and maximal targets through both public runners;
the assembly tests also check target/LR state without relying on C equality.
The complete Swift suite passes: 670 tests, zero failures.

## Offline Verification

Optimized and UBSan suites pass all earlier tests plus:

- 8,640 BR/BLR/RET differential budget cases across all source registers,
  low/high PCs, internal/external/misaligned targets and LR aliasing.
- Independent target/LR checks for the 1,728 instruction/input combinations.
- 28,475 chain cases across 1/2/8/128/256 blocks, interior and missing targets,
  exact service/block budgets and concurrent code/context/event publication.
- 12 added callback cases reached through an indirect branch, including
  retirement with allocation churn, forbidden reentrancy and failure exits.
- Early indirect branches are rejected in chain basic blocks, just like direct
  terminators. Only block-ending branches may introduce a new edge.

The test-only C comparison covers both public runners and the direct CPU core.
UBSan instruments C, not the assembly instruction bodies.
This does not establish arm64e assembly, ASan/TSan or full-system correctness.
No fresh simulator install or experimental-backend UI smoke is implied.

## Reclassified Captures

Fully eligible retained prefixes before / after this batch, each out of 32:

| Capture | Primary | Secondary |
| --- | ---: | ---: |
| Phosh | 22 / 25 | 23 / 28 |
| Settings | 22 / 25 | 20 / 23 |
| Firefox-observed | 26 / 29 | 25 / 30 |

These reuse the saved captures and contain at most four words per prefix.
Sampling/window limitations in prior reports still apply. They are neither
retired-instruction coverage nor a measured end-to-end speedup.

## Measurement Scope

The new suite interleaves 15 rounds of two four-instruction loops at windows
4/64/256/4096, using public C, direct C, guarded assembly and an explicitly
offline unguarded control. Every sample executes 1,048,576 instructions and
checks full CPU equality outside timing. The old C prototype is excluded.

Pair-control retry `phase6-pairs-4` used the preserved pre-branch binary and
again failed the post-run load gate; it is not accepted timing evidence.
Current-source hashes collected against preserved binaries are not rebuild
attestations. No noisy sample is relabeled as a passed performance gate.

The current optimized binary is SHA-256
`39a6dc5b80319760f2d306442c9448b221cc44183d8c54c7af2d65f60beeee34`.
Optimized/UBSan logs, full Swift-suite output, generated offsets, emitted-code
and unwind inspection, and reclassified captures are retained under
`experiments/phase3/results/phase6-indirect-validation/`.

## Accepted Branch Cohorts

`phase6-indirect-1` and `phase6-indirect-2` both pass collection, completeness
and CPU-equality checks (960 samples total), and both confirm Simulator resume.
Guarded assembly / direct-C median wall-time ratios, cohort 1 / cohort 2:

| Loop | Window 4 | Window 64 | Window 256 | Window 4096 |
| --- | ---: | ---: | ---: | ---: |
| Register branch | .253 / .253 | .203 / .204 | .192 / .202 | .194 / .185 |
| BLR/RET cycle | .388 / .390 | .308 / .308 | .306 / .305 | .298 / .297 |

Guarded assembly uses approximately 61-81% less median wall time on these
loops. These use a one-range program, not large binary-search tables or a
full VM cache. They do not establish Phosh responsiveness, branch-prediction
behavior in real workloads, or a no-regression gate for existing scalar paths.

## Pair Follow-Up

The branch-capable binary also completes two accepted paired-memory cohorts:
`phase6-indirect-pairs-1` and `phase6-indirect-pairs-2` (720 samples), both with
full CPU/RAM equality and confirmed Simulator resume. Guarded assembly /
paired-helper direct-C median wall-time ratios:

| Loop | Window 4 | Window 64 | Window 256 | Window 4096 |
| --- | ---: | ---: | ---: | ---: |
| Offset 64-bit pairs | .329 / .326 | .261 / .260 | .251 / .253 | .241 / .241 |
| Pre/post-index 64-bit pairs | .334 / .333 | .259 / .259 | .252 / .253 | .241 / .242 |
| Signed-word pairs | .307 / .303 | .236 / .235 | .228 / .229 | .224 / .219 |

That is approximately 67-78% less median wall time on these hot same-page
loops, against C with its paired RAM optimization enabled. These measurements
close the earlier missing pair-throughput evidence on this newer binary, not
the separate scalar non-regression, full-VM or Phosh acceptance gates.

## Existing Scalar Controls

The pre-branch pair binary (SHA-256
`7fbf8f7548252f98edb0295a0a48692db7c62fa4595af3be02c40e642840890d`) and current
binary each ran two accepted 540-sample scalar cohorts. Order was old/new, then
new/old, in artifacts `phase6-indirect-scalar-before`, `-after`, `-after-2`,
and `-before-2`. All report CPU/RAM success and Simulator resume. Current/old
guarded-assembly median wall ratios:

| Loop/window | First comparison | Reverse-order comparison |
| --- | ---: | ---: |
| load64/4 | 1.007 | 1.047 |
| load64/64 | 1.006 | 1.004 |
| load64/256 | .974 | 1.001 |
| load64/4096 | .976 | 1.003 |
| store64/4 | 1.016 | .989 |
| store64/64 | 1.001 | 1.000 |
| store64/256 | 1.001 | 1.014 |
| store64/4096 | .996 | 1.028 |
| mixed64/4 | 1.003 | 1.006 |
| mixed64/64 | 1.012 | .998 |
| mixed64/256 | .985 | 1.027 |
| mixed64/4096 | 1.029 | 1.006 |

Most changes are a few percent. The reverse-order load64/4 cell is 4.7% slower,
with a 0.626 ms IQR around a 5.391 ms median. That wider variation does not prove
the regression is noise, and the new target metadata does add entry work.
No predeclared statistical equivalence margin exists, so this is **not** a
passed zero-regression gate. Short-entry cost/layout and a larger-workload chain
control remain open. Preserve these results rather than masking them with the
much larger gains on newly supported operations.

## Simulator State

After collection, the existing app remains at the unlocked Home launcher with
fallback 0 and an advancing native counter. This is a resume/display check of
the unchanged installed binary, not a new boot, unlock gesture or validation of
the source-level BLR fix inside the iOS app. No rebuild/install/reset occurred.

## Remaining Work

Tighten scalar/chain performance controls before promotion.
Conditional select/compare forms are the next sampled coverage candidates.
Production cache/lifetime integration and application-level measurements remain
necessary; neither a coverage increase nor an isolated loop closes Phase 6.
