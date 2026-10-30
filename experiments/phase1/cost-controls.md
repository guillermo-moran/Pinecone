# Fixed-Invocation Cost Controls

Status: authored for independent review; not approved or executed. Author did
not compile, import/run the preparer, execute tests, or run timings. Hypatia
(`01a185f4-4dd4-7153-b210-947abfde98e8`) alone owns compilation and execution.
Maxwell (`01a185e8-20e8-7031-8747-945feed97c05`) must accept exact tooling and
fixture hashes before timing. The snapshot preparer is not a runtime patch.

## Interface and Contrasts

`prepare_cost_controls.py` exports `variants()` and `prepare(snapshot, variant)`
as required by `README.md`. `snapshot` is an absolute `pathlib.Path` naming a
fresh disposable source root; `variant` is one advertised string ID. Both
return JSON-serializable values. No module import side effects, compiler,
subprocess, benchmark, warmup, or fixture execution are included.

| ID | Matched Control | Exactly Changed Experimental Factor |
| --- | --- | --- |
| `cost-reference` | Unmodified reference | None; source bytes unchanged, memory statistics explicitly on in runner setup. |
| `cost-validation-entry-only` | `cost-reference` | Remove only `TP_NEXT`'s post-instruction `tp_is_current(execution)` conditional/status/return block. Guarded entry validation, snapshots, pin/unpin and all other validation remain. |
| `cost-prototype-stats-off` | `cost-reference` | Remove only the two unconditional `threaded_prototype_blocks` / `threaded_prototype_steps` atomic fetch-adds at wrapper exit. No other counters or validation change. |
| `cost-memory-stats-on` | Explicit on reference | No source edit; runner sets detailed memory statistics to 1 in its actual raw-RAM memory fixture. |
| `cost-memory-stats-off` | `cost-memory-stats-on` | No source edit; runner sets detailed memory statistics to 0 in that fixture. |

These are independent single-factor contrasts, not a factorial set. Do not
combine them with each other or the boundary owner's invocation/superblock
controls. The first three allow arithmetic and memory loops; the memory pair
allows only the memory loop. Record executor enable/memory-enable mode
separately and keep it matched within each contrast. Run the memory pair for
established and eligible prototype modes separately to distinguish common cost
from a change in the executor gap. An ineligible prototype arm is a useful
negative control, not evidence about executing prototype handlers.

All variants retain the original
`min(avz_native_decoded_block_instruction_count(block), requested_steps)`
invocation policy. No PC commit, result step increment, remaining decrement,
step-budget check, checkpoint logic, memory helper, guest instruction, or
semantic/superblock eligibility policy is edited. There is no all-validation-
off variant. The entry-only label specifically means omitting **post-instruction**
currency checks, not entry validation or pinning.

Modified C files receive a compile-time `#error` gate requiring
`AVZ_PHASE1_OFFLINE_COST_CONTROL=1`. Hypatia must supply
`-DAVZ_PHASE1_OFFLINE_COST_CONTROL=1` identically for **all** matched cost arms,
including reference and metadata-only memory controls. The gate emits no
hot-path work. It is a deliberate-build safeguard, not a security boundary or
approval. No production build/default is modified.

## Safety Envelope

Every arm is limited to the immutable, single-thread synthetic arithmetic and
raw-RAM loops from `scripts/threaded-runtime-regression.c`. A runner-owned
fixture may reuse their callbacks and run functions, with stronger expected
CPU/RAM assertions. It must preserve the code words, fixed translations,
single-thread ownership, data-only store range, checkpoint budgets and
invocation policy. No attached `AVZGuestMemory`, peer publication, device/MMIO,
observer activity, invalidation, mutation callbacks, reentrant cache eviction,
or general regression/concurrency test suite is allowed with omission controls.

The marker is an explicit runner attestation, not dynamic proof of these
conditions. Maxwell reviews the actual fixture; Hypatia performs untimed
prefix/full-state verification and an independent event ledger before timing.
Compare status, PC, completed steps, all scalar/vector state, SP/PSTATE,
FPCR/FPSR, halt and exclusive fields, and all fixture RAM against explicit
expected outcomes, including partial budgets. Do not treat two implementations
agreeing on an incorrect result as sufficient.

Omitting post-instruction validation is unsafe for mutable code, pending TLBI,
callbacks that retire programs, or concurrent execution. The program pin still
protects lifetime, but it does not make stale execution valid. Nothing here
authorizes production use, a change in cross-vCPU visibility, delayed event
service, or a Phase 2 contract. Memory statistics controls retain guest memory
semantics but do not validate general runtime behavior either.

## Snapshot and Marker Contract

The runner must copy files rather than link them and retain the immutable base.
The preparer rejects the real repository, descendants/ancestors of that root,
any Git checkout/worktree ancestor, a symlink snapshot root, symlink components
in every inspected source/marker path, and regular files with link counts other
than one. It also checks `samefile` against repository paths. `/tmp` may resolve
to `/private/tmp`; canonical containment checks still apply. Use an exclusively
owned snapshot: concurrent directory/file replacement during preparation is
outside the supported contract.

`.pinecone-phase1-snapshot` must be a regular, unshared UTF-8 JSON file. It can
have other runner metadata, but must contain this declaration (duplicate JSON
keys are rejected):

```json
{
  "cost_controls": {
    "fixture": "threaded-runtime-regression-benchmarks-v1",
    "single_thread": true,
    "immutable_guest_code": true,
    "no_external_writers": true,
    "no_invalidation": true,
    "invocation_policy": "decoded-block-count",
    "allowed_modes": ["--dispatch-benchmark", "--benchmark"]
  }
}
```

`allowed_modes` may be narrowed to a nonempty unique subset. `prepare` returns
the intersection with its variant's modes and rejects an empty intersection.
The boolean fields require JSON `true`, not strings or numbers. The fixture
identity includes the remaining safety limits above; the booleans alone do not
authorize new fixture behavior.

Before edits, all seven pinned hashes must match: Native, TP, BlockCache,
GuestMemory, GuestMemoryInternal, the TP header, and the original runtime
regression fixture. The module lists the exact hashes inspected in the dirty
worktree. Unknown IDs, missing marker, mismatched hashes, changed invocation
cap, missing/duplicated target blocks, and unexpected entry/pin patterns fail
closed. Do not relax these checks to accommodate drift; update the reviewed
snapshot and obtain fresh review. Apply `prepare` **before** ledger
instrumentation or runner edits to the original source files. The runner's
separate fixture may be added later with its own retained hash/review.

After preflight, the preparer exclusively creates
`.pinecone-phase1-cost-controls-preparation.json` in state `preparing`, including
for metadata-only variants. It atomically replaces at most one C source file,
checks resulting source hashes, then replaces that record with the complete
summary in state `prepared-awaiting-review`. Any exception after the claim
leaves a non-reusable snapshot; discard it rather than delete the record/retry.
An existing record, even partial or symlinked, rejects another preparation.
This prevents accidental reapplication and composition of metadata-only arms.
The marker and repository files are never rewritten. Scratch temporary files
are created only beside a target in the snapshot and removed on replacement.

## Runner Integration

The summary contains `changed_factors`, `changed_files`, source hashes before
and after, `required_compile_defines`, `allowed_modes`, `safety_declaration`,
`review_required: true`, and **mandatory** `detailed_memory_statistics` (0 or 1).
The memory pair deliberately does not patch the old `memory_benchmark()`:
Hypatia's new fixture includes/reuses source callbacks but does not call that
function. A patch there would create a no-op contrast.

In the actual memory fixture, outside the measured interval and before any
warmup, the runner must apply the summary value using:

```c
avz_native_memory_fast_path_set_detailed_statistics_enabled(memory, requested_value);
```

Record/assert the effective setting in fixture diagnostics. For non-memory
cost arms it is 1 whenever the memory fixture is selected. The original
fast-path constructor defaults it to 1, but relying on an implicit default
would weaken reproduction. There is no runtime flag/default change outside
the temporary fixture. Detailed-statistics counts are not architectural steps;
their absence must not weaken expected-state or budget assertions.

Disabled prototype block/step counters will remain zero in newly allocated
contexts (or retain preexisting values if a context is reused). Boundary/fault
counters, enable flags and `AVZNativeBlockResult.steps` remain intact. Do not
infer eligibility, execution count, zero work or equal work from intentionally
disabled counters. The independent untimed ledger must count executor entries,
lookups, steps, hot/helper accesses, exits and checkpoints directly. Keep that
instrumentation out of timing binaries. Verify unchanged invocation frequency
in both sides of each contrast, not merely equal final guest steps.

Warmness/preparation remains exclusively runner-owned. This module performs
source preparation only; it neither creates nor warms/resets CPU/cache/memory
fixtures, changes batch sizes, nor chooses the timing boundary. Keep cold and
prewarmed cohorts separate; resets must preserve valid cache metadata and
occur outside timing. Use the same source controls and fixture policy for each
matched cohort. Preserve failures, load evidence, raw distributions and full
build identities. Hypatia must coordinate any active VM with the parent, never
stop an unrelated process or overlap builds/benchmarks.

## What the Experiments Can Establish

- Reference versus entry-only measures the net emitted-code impact of the
  post-instruction guard in this immutable fixture at unchanged invocation
  policy, including optimizer/register-allocation effects. It does not assign
  cycles separately to retirement, null-token checks, branches, or loads.
- Neither original microbenchmark attaches shared guest memory. This validation
  contrast therefore cannot attribute shared acquire-load or coherence cost.
- Reference versus prototype-stats-off measures the combined effect of the
  two recurring block/step atomic updates, not every statistic or all atomics.
  Counter removal can also change register allocation. Do not add its delta
  linearly to validation or boundary deltas.
- Memory-stats-on versus off changes the existing statistics predicate and
  its gated updates in the actual memory fixture, without removing predicate
  source code or guest bookkeeping. Both executors use these helpers, so
  report absolute changes and change in the executor gap separately.

No timing result is supplied by this author. Remaining readiness gates are
Maxwell's exact-artifact review, Hypatia's preparer rejection-path checks,
source-diff/assembly inspection, fixture/ledger equivalence checks and serialized
measurement under the coordination contract. Only source inspection and
documentation/diff whitespace checks were performed in the authoring task.

## Review Requests

Review the exact transformation scope, seven-source freeze, snapshot guards,
one-use preparation record, compile opt-in, marker attestation, and runner's
application of metadata-only memory settings. Required untimed owner checks
include rejection of real root/aliases/subtrees, missing/malformed marker,
duplicate keys, false/nonboolean declarations, source drift, symlinked parents,
hard-linked sources, duplicate or partial preparation, and unknown variants.
Check that failures before the exclusive claim write nothing and failures after
it never yield a reusable arm. No such tests were run by this author.

`send_input` is unavailable in this worker. Hypatia and Maxwell are being
notified directly via the available task-message API instead; this does not
create another task or authorize any timing before review.
