# Offline Boundary Controls

Status: authored for independent review, not approved for timing. No module
execution, tests, compilation, or timing by the boundary owner. Hypatia alone
owns those actions; Maxwell must approve each changed arm before timing.
This implements Phase 1 experimental tooling, not Phase 2 production policy.

## Interface And Isolation

[prepare_boundaries.py](/Users/gmoran/Documents/Projects/arm64viz/experiments/phase1/prepare_boundaries.py)
exports `variants()` and `prepare(snapshot: pathlib.Path, variant: str)`.
Each advertised metadata dictionary contains the five required contract fields
plus executor selection, matched control and, for sweeps, limits. Import has
no write/compile/run side effects. Preparation changes one copied native C file
and returns JSON-serializable before/after hashes, exact replacements, original
line numbers, metadata and validated source hashes. It does not set flags or
select the fixture executor itself; the runner must honor `required_executor`.

Snapshots must be external disposable copies with repository layout, containing
a regular `.pinecone-phase1-snapshot` marker. Marker content has no extra schema.
The canonical real repository, any descendant, its ancestors, and roots with
`.git` are rejected, even if a marker is present. The root itself cannot be a
symlink; parent aliases such as macOS `/tmp` are canonicalized. Sources/marker
and their components below the root cannot be symlinks; files must be regular
with link count one. Hardlinked production source copies are rejected.

Six native source/header files are pinned by full SHA-256 in the module to the
currently reviewed dirty source. All must match before preparation. Every
replacement must occur exactly once. Unknown variants, absent markers, source
drift, a second application, and stacking boundary/cost variants fail closed.
The runner must use a fresh copy of its immutable base for each arm and apply
preparation **before** separate ledger instrumentation. Do not update expected
hashes merely to make preparation succeed; new inputs require re-review.

Only `Sources/ARM64VizNative/ARM64VizNative.c` in the copied snapshot is replaced.
The replacement is staged in the same directory; marker/source checks are
repeated before atomic replacement. Mode is preserved and temporary files are
cleaned on failure. No production source is opened for writing. This assumes
exclusive ownership of a quiescent snapshot; it is not a security protocol for
concurrent adversarial directory replacement. The marker establishes a declared
disposable destination, not proof that a later executable is used safely.

## Independent Arms

| ID | Runtime selection required | Exact changed factor | Matched comparison |
| --- | --- | --- | --- |
| `prototype-limit-4` | Prototype on; memory eligibility on only for memory fixture | Four-instruction cap explicitly set to 4; all other counts unchanged | Unchanged prototype baseline, then each sweep arm |
| `prototype-limit-16` | Same | Four-instruction cap set to 16 | `prototype-limit-4` |
| `prototype-limit-64` | Same | Four-instruction cap set to 64 | `prototype-limit-4` |
| `prototype-limit-256` | Same | Four-instruction cap set to 256 | `prototype-limit-4` |
| `prototype-limit-4096` | Same | Four-instruction cap set to 4096 | `prototype-limit-4` |
| `established-superblock-off` | Prototype and threaded memory both off | Disable both cached superblock lookup and new composition in checkpointed chain | Unchanged established baseline with superblocks available |

Do not combine the superblock control with a prototype cap change. The runner
must retain unchanged established/prototype controls, not replace them with
the limit-4 arm. Limit-4 is policy-equivalent for every decoded block length,
but source/compiler identity still needs capture; identical emitted bytes are
not asserted. All arms use the same compiler/options, immutable input fixture,
total instruction budget, checkpoint budget and warm/cold protocol.

## Invocation Sweep

The copied wrapper retains its decoded-count getter and changes only its
limit selection immediately before the existing clamp:

```c
uint64_t limit = avz_native_decoded_block_instruction_count(block);
if (limit == 4) limit = UINT64_C(N);
if (limit > requested_steps) limit = requested_steps;
AVZNativeBlockResult result = avz_tp_run_guarded(program, limit, &context->cpu,
    memory, cache, code_epoch, shared_epoch);
```

`N` is one of the advertised constants, never caller-provided C text. This
retains the count-getter call across arms instead of conflating fewer calls
with removing it entirely. Four-instruction scope matches the arithmetic
`ADD; ADC; AND; B` and memory `LDR; ADD; STR; B` loops. Shorter suffix blocks
after cold-memory helper exits retain their original caps. The check does not
recognize guest opcodes: the runner must constrain use to the reviewed fixtures.
It cannot authorize arbitrary four-instruction programs.

The following source facts were inspected, not dynamically verified here:

- [ARM64VizNative.c:14883](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14883)
  computes guest steps remaining and checkpoint steps remaining. A zero
  checkpoint remainder invokes the checkpoint first; zero returned budget stops.
- [ARM64VizNative.c:14907](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14907)
  selects `requested_steps = min(checkpoint_remaining, remaining_steps)`.
  [ARM64VizNative.c:14987](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14987)
  passes it without another clamp to the prototype wrapper. The modified
  wrapper passes `min(N, requested_steps)` for four-instruction blocks.
- [ARM64VizThreadedPrototype.c:568](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c:568)
  initializes `remaining` with that limit. Entry validation, active-run pinning,
  token acquisition, retirement and zero-budget handling are untouched.
- [ARM64VizThreadedPrototype.c:100](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c:100)
  increments completed steps, decrements remaining, validates, then checks for
  zero before dispatch. Register/PC updates and memory helper/fault/continuation
  semantics are unchanged. A validated in-block backedge can now repeat inside
  the invocation; outside-block/unsupported/fault exits still terminate it.
- [ARM64VizNative.c:15022](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:15022)
  adds actual returned steps to chain and checkpoint totals. The chain still
  checkpoints on limits/revalidation/faults/terminal states and respects a
  checkpoint returning zero. No speculative full-limit accounting is added.

Consequently the requested **instruction** bound reaches the executor by source
inspection, including non-multiples of four. This is not a claim of verified
architectural equivalence: Hypatia must run exact-prefix/full-state checks.
Partial final slices may stop at a different PC than the loop head, as they
must. Both public checkpointed entry points route to the same implementation
([ARM64VizNative.c:15159](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:15159)).
Do not use the non-checkpointed chain for the measurements: it calls the same
modified wrapper but has a different MAX_STEPS break policy at
[ARM64VizNative.c:14638](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14638).

Changed frequencies are a bundle: wrapper entry/exit, pin/unpin, eligibility
lookups, statistics increments, outer cache/direct-link selection, clock
advance and chain bookkeeping. Their individual costs cannot be recovered by
calling the sweep gain "tail-call overhead." The per-instruction generation
checks, handlers, CPU stores, completed-step accounting and statistics policy
remain in place, but per-invocation statistics updates occur less often.

There is no claim that all boundary behavior is unchanged. `chain.blocks` and
`checkpoint_blocks` count invocations/composed blocks, not backward-loop guest
traversals. Their frequency changes, so a block-count-triggered checkpoint
policy can move even while the instruction deadline remains bounded. Use the
reviewed fixture's nonbinding block limits (`max_blocks = budget + 1`, block
checkpoint interval 10000) and record checkpoint reasons. Guest timer advance
also occurs after an invocation, not after every step; no live IRQ/device/time
deadline is allowed in this diagnostic. These limitations prevent promotion
of the wider slices into production without the later execution contract.

## Established Superblock-Off Control

Two exact sites in the checkpointed implementation are replaced:

1. [ARM64VizNative.c:14727](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14727):
   replace `active_superblock = avz_native_find_superblock(...)` with NULL.
2. [ARM64VizNative.c:14836](/Users/gmoran/Documents/Projects/arm64viz/Sources/ARM64VizNative/ARM64VizNative.c:14836):
   remove the complete conditional composition block, including the assignment
   of `composed` to `active_superblock`.

This handles reuse as well as construction, including warmed contexts. The
prototype wrapper and all prototype files remain byte-identical to the base.
Direct-link and ordinary decoded-cache selection, per-entry validation,
checkpoint accounting, and established handler/semantic code remain present.
Mapped traces are no longer selected, so mapped-only semantic opportunities,
composition/lookup overhead, block grouping and register allocation may change
together. This measures superblock **policy**, not a pure branch instruction
or allocation effect. Ledger must show zero superblock dispatches; any
nonzero value blocks interpretation. Established controls must have zero
prototype steps regardless of whether prototype support is compiled in.

## Owner Verification And Review Questions

No preparation module or test was executed by this author. Before timing,
Hypatia should verify these properties serially and retain failures; Maxwell
must approve the resulting implementation/fixture contrast:

- Does preparation reject real root/aliases, missing or nonregular marker,
  unknown ID, linked source/parents, source drift, duplicate application and
  attempted combinations, without touching production? Use disposable inputs
  for negative cases and compare production hashes before/after. Never create
  a marker in the real checkout just to exercise rejection.
- Do both fixtures produce independently expected all-register/vector/SP/PC/
  PSTATE/FP/exclusive/halt state and entire RAM, not merely equal final x0 or
  one data word? Compare semantic fields rather than uninitialized padding.
- For limits 4/16/64/256/4096, verify budgets around each boundary and every
  residue modulo four: e.g. 1,2,3,4,5,15,16,17,63,64,65,255,256,257,
  4095,4096,4097, plus the million-step fixture. Verify smaller checkpoint
  limits such as 1,3,5,17, exact checkpoint delta totals, and no budget overshoot.
- Verify zero-budget behavior, zero-return checkpoint termination, cold memory
  read/write exits and warm hot access, and shorter suffix blocks with original
  caps. These are separate untimed checks, not additional timing arms.
- Does the ledger confirm four-instruction eligibility, actual returned steps,
  entries/lookups, no unexpected helper exits, matching step totals and bounded
  checkpoints? A checkpoint count is not an invocation count. Warmup/reset must
  retain valid cache metadata and reset CPU/data outside timing.
- Is the limit-4 source policy control acceptable alongside the unchanged
  baseline? Is four-instruction-only widening preferable to a global constant
  that would also alter cold suffix-block exits? Is superblock-off's whole-policy
  scope adequately separated from invocation effects?

At least nine alternating samples per accepted arm, cold/warm separation,
compiler/binary/tool hashes, and no competing VM/build/profile load remain the
measurement owner's requirements. No app installation, environment/default
change, guest-image edit, runtime-source modification, or production
correctness/concurrency claim is authorized by these files.
