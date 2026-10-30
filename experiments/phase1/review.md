# Phase 1 Independent Experimental Review

## Parent Retry Approval: 2026-10-29

The user authorized a fresh timing cohort. Parent ran `fresh_cohort.py` into
`results/20261029-retry-01`; its source/binary/tool/verification hash checks
passed. Structured comparison of old and new review bundles confirms that
only the `run` output-directory field differs; all 12 arm identities and all
other fields are identical. No native test, compilation or timing samples
were copied/re-executed by this metadata preparation. Maxwell's previously
reviewed source and verification scope therefore remains unchanged.

Parent accepts the new exact bundle for the same selected cells, fixed-4096
fixture and 11 serial alternating rounds, subject to the unchanged live load
gates. No production safety claim, relaxed load limit, pooling of the previous
84 samples or new executor default is authorized. Parent owns the timing lease
and stopping/restoring only the original Pinecone app for this run.

ACCEPTED_BUNDLE_SHA256: e530182a7c96c2473926279869e25b385759d464accb074e59cb7a5d8e6eec24

Reviewer: Maxwell. Measurement owner: Hypatia
(`01a185f4-4dd4-7153-b210-947abfde98e8`).

Status: exact bundle passed the gate in Review 3, but collection aborted on
load; the entire partial cohort is ineligible for attribution (Review 4).
Earlier held decisions are retained as review history and superseded only for
that bundle. No compilation, fixture/test execution, timing, production edits,
or Simulator actions by the reviewer. Reviewer checks read source, hashes and
retained owner outputs; they do not rerun the owner's tests or establish timing
results or causal conclusions.

## Acceptance Gates

### Snapshot Isolation

- Require a regular `.pinecone-phase1-snapshot` marker; reject the real repository
  root after canonical path resolution. Reject destination symlink escapes and
  source files that alias production files (including hard links). The runner
  must copy files, not create mutable links to the checkout.
- Validate advertised variant IDs and exact expected source patterns/counts
  before writing. Fail closed on drift, duplicate application, and partial
  preparation. Preserve the immutable base snapshot and independent arm copies.
- Record the dirty source snapshot, all source/header/tooling hashes, compiler
  identity/target/options, overrides, exact transformation diffs, and binary
  hashes. HEAD alone is insufficient. Verify production hashes remain unchanged.
- Do not load omission variants into general correctness/concurrency tests or
  the app. Their only valid fixture has one thread, immutable decoded code and
  translation state, no devices, no observer publication, and no reclamation.

### Architectural Equivalence

- Use explicit expected-state assertions, not merely equal values from two
  potentially wrong implementations. Verify completed steps, status, PC, all
  scalar/vector registers, SP, PSTATE, FPCR/FPSR, halt state, local exclusive
  fields, and entire fixture RAM. Identify any intentionally excluded field.
  Avoid relying on uninitialized struct padding in memcmp.
- Initialize architectural state and unused RAM with deterministic sentinels
  where practical. Assert code bytes/mappings never change and stores remain
  within the intended data location. Assert host alignment and width.
- Exercise partial budgets as well as the million-step multiple-of-four case
  in the owner's untimed verification. Assert no progress beyond the requested
  budget and exact expected prefix state. A final RAM value alone is inadequate.
- Check checkpoint totals and individual deltas. Invocation-limit controls
  must remain bounded by requested/checkpoint remaining steps; verify retained
  per-instruction validation. A control that also removes validation is a
  separate interaction experiment, not a clean invocation contrast.

### Warmup And Instrumentation

- Distinguish allocation/setup, preparation/cold execution, and prewarmed
  execution. State exactly which cache layers each warmup establishes.
- Reset CPU, data, and diagnostic baselines outside timing without clearing or
  forging retained cache metadata. Restore data through a valid access path;
  ensure state/clock/checkpoint accounting is also reset consistently. Subtract
  baseline counters where resetting them would invalidate cache state.
- Keep diagnostic hooks/counters out of timing binaries. Retain hashes and
  diffs proving diagnostic and timing builds differ only by instrumentation.
  Emit logs/assertions outside timing where possible; assertions remain active.
- The untimed ledger must distinguish executor entries, preparation/lookups,
  superblocks/semantic steps, prototype steps, checkpoints, hot read/write
  success, complete-helper access, side-exit reason, commit/invalidation work,
  and faults. Checkpoint count is not invocation count. Ordinary RAM hit counters
  alone do not distinguish inline hot success from full-helper RAM completion.
- Statistics-omission arms may intentionally lose internal statistics, but
  independent diagnostic counters must still establish equal execution policy
  and work. Never use disabled counters as evidence that work did not occur.

### Contrasts And Sampling

- Enumerate changed factors for each variant and name its matched control.
  Invocation sweeps retain validation/statistics policy. Validation/statistics
  contrasts retain invocation policy. Superblock suppression is an execution-
  policy contrast, not a pure dispatch instruction contrast.
- Preserve an unchanged baseline and independent controls. Do not pool cold
  and warm samples or attach-guest-memory and raw-RAM fixtures. Attaching guest
  memory changes epochs, observation, dirty tracking, and commit behavior as a
  bundle; it cannot alone isolate one helper's cost.
- Hypatia alone compiles/runs. Before timing, require process/load evidence and
  parent resolution of any active test VM. The reviewer does not stop user
  processes. Do not overlap compilation, diagnostics, or other benchmarks.
- Require at least nine alternating samples per accepted arm, matched budgets,
  retained failures and raw distributions, and medians/spread. Record order and
  whether runs share a process. Recheck load, do not hide early slow samples.
- Changed source/tooling hashes invalidate prior acceptance until the delta is
  reviewed. Approval names exact variants, hashes, fixture, exclusions, and
  pending verification conditions. It never authorizes production deployment.

## Interpretation Exclusions

- Static host instruction counts are not cycles or measured cost fractions.
- Same C RAM helper does not guarantee same emitted code/register traffic;
  equal helper counts cannot establish zero differential cost.
- The raw-RAM memory fixture has no shared guest-memory object. Observer locks,
  translation/code-epoch contention, native page walks, or exclusive generations
  cannot be blamed for its steady-state regression without a different fixture.
- A store still reaches the shared commit/invalidation check in raw-RAM mode.
  This is common work, not automatically a prototype-only cost.
- Arithmetic and memory loops differ in instruction mix. Subtracting their
  total regression gaps is not memory-helper attribution.
- A budget sweep changes frequency of wrapper/chain work, counters, and related
  cache/accounting calls together. Its gain does not assign independent costs
  to those components. Omission effects and budget effects need not add.
- No synthetic omission control proves full-system correctness, interrupt
  latency, cross-vCPU visibility, or a safe production slice size. Phase 1 stays
  open if measured evidence is incomplete.

## Variant Decisions

| Artifact | Decision | Reason |
| --- | --- | --- |
| `prototype-limit-4/16/64/256/4096` | Static source accepted; timing held | Four-word fixture only; runner/ledger verification pending |
| `established-superblock-off` | Static source accepted; timing held | Mode 0 only; whole-policy contrast; runner verification pending |
| All five cost-control variants | Static source accepted; timing held | Fixed invocation; immutable single-thread fixture; runner verification pending |
| Runner/fixture/ledger | Changes required | Preliminary findings below |
| New result interpretation | Pending | No new results reviewed |

The parent subsequently required exact-artifact approval for baseline too.
The table records the preliminary decisions; Review 3 supersedes these holds
for its named bundle only. No baseline exception applies to the final run.

## Review 1: Boundary Source And Runner Preflight

Boundary author ready notice reviewed against:

- `prepare_boundaries.py`: `7bdf354230c64600d33186b07f7264d7e57582dbb98b04de2fa6310f7f61a6d6`
- `boundaries.md`: `2a876c82a2f38c3fb62c5cda03362257f9de2436abf59e7b6a3422571694aead`

The module validates six source/header hashes and all exact replacement counts
before atomically replacing only copied ARM64VizNative.c. It rejects production
root/descendants/ancestors, linked source components, multi-link files, and Git
checkout roots. Parent path aliases are canonicalized, not all forbidden; this
is adequate for Hypatia's exclusively owned external snapshots, not concurrent
adversarial path replacement. No preparer execution was performed by reviewer.

The cap sweep retains the decoded-count getter, only widens count==4, retains
the requested-step clamp, and leaves TP guards/pinning/accounting unchanged.
Cold suffix blocks keep their original cap. Limit-4 is a policy-equivalent
source control, not asserted byte-identical code; keep the unchanged baseline.
Superblock-off disables both lookup and composition in the checkpointed chain;
direct links and semantic handlers remain. These are valid source contrasts
with the author's documented instruction-bound versus block/timer limitations.
No non-checkpointed, live-deadline, device, observer, or concurrent use accepted.

Preliminary runner findings sent to Hypatia, all awaiting verified resolution:

1. **Timing gate and verification identity:** measure.py's initial approval
   parser accepts variant IDs alone; verified.json initially contains only a
   pass flag and budgets. Bind acceptance to the exact run/fixture/runner/module
   hashes and verification to binary hashes. Do not reuse approval across a
   changed snapshot, build, or verification implementation.
2. **Executor selection:** initial verify/timing loops run every mode for every
   variant, ignoring boundary `required_executor`. Superblock-off is mode 0
   only. Prototype-limit primary contrasts are arithmetic mode 1 and memory
   mode 2. Additional unchanged mode controls belong to baseline, not evidence
   that the transformed path executed.
3. **Diagnostic preparation:** initial instrument_ledger.py matches both enabled
   and disabled avz_tp_create definitions, despite requiring a unique match.
   Scope insertion explicitly to enabled code. Validate all patterns/paths
   before writes and add snapshot-only/link protections; a marker check alone
   is insufficient for a standalone mutator.
4. **Independent work ledger:** wrapper entries survive statistics omission,
   but add independent returned-step/status counts and invocation-size
   distribution. Retain explicit hot/full helper counts; disabled internal
   statistics must not stand in for work counts. Budget list must include
   255/256/257 for the 256-step arm.
5. **Load-failed samples:** retain samples when a post-round load gate fails,
   but mark them excluded from valid matched summaries. The initial summarizer
   pools all successful process outputs regardless of later load failure.
6. **Manifest timestamp:** freeze's `name` loop variable overwrites the timestamp
   with ledger.h before writing created_utc. Correct it and retain failure/
   superseded artifact provenance rather than rewriting an old manifest.

Positive preliminary fixture observations: one thread; deterministic scalar,
vector, FP, PC, SP state; independent expected arithmetic/RAM model; full RAM
and CPU comparison outside timing; no devices or attached shared memory; warmed
data restored through the helper; code bytes/epoch checked unchanged; ledger
build refuses timed execution; counter deltas exclude warmup. Struct padding
comparisons can yield false failures across builds and should be made
deterministic or compared by semantic fields. Timer state is zero in this
fixture; no active timer reset or latency claim is supported.

The fixed 4096 checkpoint bound is asserted. Smaller checkpoint budgets and
zero-return termination were requested as untimed checks; otherwise approval
must explicitly remain limited to fixed4096 and make no general checkpoint
contract claim. No owner-reported pass has yet been reviewed here.

## Review 2: Cost-Control Source

Reviewed author-ready artifacts:

- `prepare_cost_controls.py`: `8327a868c0b99cb2fcf6d8294800de7feedbc4639b7e4fa221ec62f150cb6e50`
- `cost-controls.md`: `bbe2dc98ad63bc515528372497a79fd6fdfd284cf43b91d0e124f99901741183`

All five advertised variants pass static source review within the immutable,
single-thread, no-guest-memory-object fixture scope. No timing acceptance yet.

| ID | Accepted source contrast | Exclusions |
| --- | --- | --- |
| `cost-reference` | Unmodified source, explicit detailed memory stats on | Not interchangeable with a differently built baseline without identity checks |
| `cost-validation-entry-only` | Remove only TP_NEXT post-instruction currency guard | Entry validation/pinning remain; no shared-epoch contention attribution; current runner narrows to arithmetic |
| `cost-prototype-stats-off` | Remove only wrapper block/step atomic increments | Independent ledger required; does not remove all counters or all atomics |
| `cost-memory-stats-on` | Unchanged source plus explicit setter=1 | Memory workload only; returned setting must reach actual fixture |
| `cost-memory-stats-off` | Unchanged source plus explicit setter=0 | Contrast includes predicate-selected updates in shared helpers, not a new memory implementation |

The seven-source hash allowlist, exact pattern checks, entry/pin preservation,
regular-file/link checks, canonical checkout rejection, JSON safety declaration,
and exclusive one-use preparation record are adequate for declared quiescent
owner snapshots. A partial preparation is marked unusable. Modified C files
have a compile-time opt-in gate; the runner must use that define identically
for reference and all matched arms. At most one C source is transformed by each
omission variant. Memory-statistics arms are metadata-only and intentionally
do not patch the unused original benchmark function.

The runner must honor `prepare_summary.detailed_memory_statistics` and the
allowed-workload intersection, and verify execution policy independently of
omitted counters. Arithmetic-only validation testing is a valid conservative
restriction; acceptance does not silently add unverified memory cohorts.
No live fault/mutation/concurrency regression suite may use omission variants.
No preparer import, negative-path test, build, or execution by this reviewer.

## Verification Status Correction

Hypatia reported an initial baseline pass, then a refreshed ledger-only failure:
the recorder incorrectly assumed statuses were below 16, but TP REVALIDATE is
258. TP MEMORY_FAULT is 259; DISABLED/INVALID_ARGUMENT are 256/257, while native
statuses are 0 through 4. The parent requires explicit known-status
classification and unknown rejection, plus targeted owner-run untimed checks.
Merely increasing the histogram capacity to 260 does not meet that requirement.

No earlier pass is carried into a refreshed bundle unless its exact fixture,
instrumentation and binary identities match. All failed attempts must remain
retained as superseded/failed verification, never timing evidence. Runtime code
is unchanged by this diagnostic correction. Timing approval remains withheld.

Checkpoint approval will be limited to the actual fixed-4096 fixture; smaller
limits and zero-return termination are generalization-only extensions, not
mandatory blockers for this bounded experiment. A measurement blockage must be
reported to the parent, who owns any required original-app restoration. The
reviewer will not change Simulator/app state.

## Review 3: Exact Final Instrumentation And Timing Gate

Accepted run: `experiments/phase1/results/20261029T044919Z`.
Accepted `review-bundle.json` SHA256:
`53ed86869263b518c5e5ad7f09777d96c2bdaf5f4c340a78c35904badf4a3dee`.
This is acceptance to collect timing, not acceptance of results or production
changes. It replaces the preliminary holds for the following exact artifacts.

### Artifact Identity And Evidence

The reviewer independently read and SHA256-checked the bundle, manifest, seven
current tool/test files, five evidence files, all 12 arm and verified manifests,
24 binaries, and recorded frozen/timing/ledger sources: 651 hash comparisons in
total, including current native and script files against the dirty frozen base.
All matched. Snapshot source files checked were regular, non-symlink files with
one link. Build records have returncode 0 and commands matching arm manifests;
only ledger commands define P1_LEDGER. No verification executable or project
test module was executed by the reviewer. No timings.jsonl existed at review.

The bundle binds the final runner hash
`8604b146de97b8a6702ba0c76d6ebb0c0b57276584f65d0bf7ca202cf696fed8`,
fixture hash `39907d1a83e227055e1efded0d785f4a654b89de39872bef249da63968991b0a`,
and ledger hash `7ecc930ea25420b4028f1ac38c68144b7fa00024288bfffe673f7f3c07c1f203`.
Preparer hashes remain those accepted in Reviews 1 and 2 and are checked through
each arm. The freeze manifest retains earlier runner/test-preparation hashes;
these are historical freeze identities, not the final review identities. The
final bundle explicitly binds the reviewed revisions and owner evidence.

Direct read-only examination of verification.jsonl confirmed 1,920 successful,
untimed records: 1,856 prefix cases and 64 million-step ledgers. Each of 64
arm/workload/mode/warmness cells has exactly the 29 declared prefix budgets
plus one million-step ledger. CPU bytes, RAM fingerprint and final status agree
across matching workload/budget records. The fixture itself asserts full CPU
and all 8,192 RAM bytes against an independent expected-state model, exact
steps/status and checkpoint total (`fixture.c:55`). Recorded per-checkpoint
maxima are at most 4096; code bytes and code epoch remain asserted unchanged
(`fixture.c:143`). Prefixes include 255/256/257 and 4095/4096/4097.

The nine symbolic statuses, including REVALIDATE=258 and MEMORY_FAULT=259,
map explicitly; unknown values trap (`ledger.h:7`, `ledger.h:36`). The retained
owner status test reports all nine classifications and unknown-42 rejection,
with matching reviewed header/test hashes. Fifteen retained rejection checks
cover real root, missing marker, source drift, symlink and hardlink for each
preparer/instrumenter. This does not certify unrun malformed-marker,
duplicate-preparation, concurrent path mutation, or other negative cases.

### Mandatory Findings Resolved

- Exact bundle, arm-bound verification, source/binary rechecks and approval
  hash gate replace ID-only acceptance (`measure.py:279`, `measure.py:307`).
- Workload/executor selection honors the narrow tested contrasts
  (`measure.py:197`, `measure.py:205`). Superblock-off records only mode 0 and
  zero superblocks. Invocation arms use arithmetic mode 1 and memory mode 2.
- Enabled-definition instrumentation and staged snapshot-only mutations were
  reviewed; diagnostic changes stay in distinct ledger trees. The timing
  build has no diagnostic hooks, and the ledger refuses timed execution
  (`fixture.c:97`). Translation counters are independent of detailed stats.
- Independent requested/limit/executed/status histograms match invocation
  totals and weighted prototype steps. All recorded invocation statuses are
  max_steps or the expected cold-memory revalidate exits. Entry-only validation
  retains 250,000 entry checks for one million arithmetic steps versus
  1,250,000 total checks in the reference. Wrapper-stat omission leaves the
  independent 250,000 entries and one million steps intact.
- Warm reset uses the existing memory write helper, restores CPU and resets
  diagnostic baselines outside the measured interval (`fixture.c:123`).
  Memory statistics policy is explicitly set on the actual fixture at line114.
- Timestamp shadowing is fixed. Raw failed/contaminated cohorts are retained;
  post-round load failure marks invalid_load and incomplete cohorts cannot be
  eligible (`measure.py:350`, `measure.py:378`). Earlier verification attempts
  are not carried forward merely because they reported passes.

### Accepted Contrasts And Limits

All 12 named arms are accepted for their current runner-selected cells only:
baseline and cost-reference; prototype-limit-4/16/64/256/4096; established-
superblock-off; arithmetic-only cost-validation-entry-only and cost-prototype-
stats-off; memory-only cost-memory-stats-on/off. Limit-4 remains a source-policy
control, not assumed binary-identical to baseline. The sweep changes repeated
wrapper/lookup/pinning/accounting/entry-validation frequency as a bundle.
Superblock-off changes a whole execution policy, not just dispatch syntax.

Cold-versus-warm timing MUST be labeled a mixed preparation/execution-policy
contrast, never pure preparation cost. In cold memory mode 2, the reviewed
ledgers contain 998,779 prototype steps plus 1,221 established-C steps,
two revalidate exits, 244 superblocks and 247 checkpoints. Warm mode 2 has
one million prototype steps, zero established entries/superblocks/revalidate
exits and 245 checkpoints. Established steps here are exact-total minus
independently recorded prototype steps, not generic_dispatches. That latter
counter covers generic fallback only. Warmup itself executes 8,192 guest steps;
its duration is not a pure cache-preparation measurement either.

Across memory cells, cold records have one full read, one full write and two
translation callbacks; warm records have none. Hot read/write counts are
249,999 cold and 250,000 warm. Both executor paths retain 250,000 invalidation
checks/skips with zero invalidations. Shared helper counts do not prove equal
emitted-code cost; common commit work is not prototype-only overhead. No
observer/shared-memory contention or exclusive-generation claim is supported.

Scope is a single-thread, immutable four-instruction arithmetic/raw-RAM fixture,
fixed4096 checkpoint bound, this compiler/build, and these diagnostic workloads.
No live IRQ/timer, attached shared memory, devices, mutation, concurrency,
non-checkpointed path or production safety claim is approved. Smaller bounds,
zero-return cases and broad architectural coverage are extensions, not blockers
for this scope. Expected-state comparisons and checkpoint assertions add common
fixture machinery; timings are not interchangeable with historical medians.

Hypatia alone may collect the planned serial 11 samples per cell, alternating
forward/reverse order, after confirming no compiling/diagnostics/VM overlap and
passing live load gates. Keep cold/warm cells separate, retain every failed
sample, and review raw distributions and paired round contrasts before causal
interpretation. Hash drift requires renewed acceptance. If collection is
blocked, notify the parent and require parent-owned original-app restoration.

ACCEPTED_BUNDLE_SHA256: 53ed86869263b518c5e5ad7f09777d96c2bdaf5f4c340a78c35904badf4a3dee
ACCEPTED_FOR_TIMING: baseline, prototype-limit-4, prototype-limit-16, prototype-limit-64, prototype-limit-256, prototype-limit-4096, established-superblock-off, cost-reference, cost-validation-entry-only, cost-prototype-stats-off, cost-memory-stats-on, cost-memory-stats-off

## Review 4: Aborted Collection Disposition

The accepted bundle remains unchanged, but its timing cohort is NOT accepted
for attribution. Direct inspection confirms 84 successful samples: six rounds
in each of 14 cold-arithmetic cells, all at one million instructions. No warm
or memory samples exist. This is below the predeclared minimum of nine samples
per cell. No ranking, speedup, cost fraction or causal conclusion is accepted.

The three preflight observations and all before/after load files for rounds
0 through 5 meet the recorded gates. Before round 6, the retained observation
shows Codex Renderer PID25697 at 335.8% CPU and total 452.3%, exceeding the
process100/total400 gates; Pinecone is absent. Passing earlier snapshots does
not prove absence of between-snapshot disturbance and does not rescue the
under-sampled cohort. Do not selectively promote these six rounds or append
new samples to this failed cohort.

The owner's terminal timing-status.json explicitly records aborted_load,
84 retained samples, and all_samples_excluded_from_attribution=true.
summary.json reports eligible_for_attribution=false. This disposition is
consistent with the declared handling of partial/contaminated cohorts. The
source/instrumentation and untimed correctness evidence remain useful within
their stated scope; the timing attribution question remains open.

Reviewed artifact hashes:

- timings.jsonl: `457db84d2c4d8b5f542f7639dd35c8472189f122597c945026315e796de993a6`
- timing-status.json: `ef45c99271ac6d6a26087c32e54fae9b2e732afc4b779ea838d2145a510b3546`
- summary.json: `e73da61b6fb7aebe266fd0d432f4873508c2d42eaf48c98958fd15986f2b7f2c`
- arithmetic-0-6-before-load.json: `1ad7ef2228336e52b4067504ac983139d67ad85a8f9c6dfc54fde7bd90ce0717`
- app-restoration.json: `51dd9ddae22c87e06e1e038d98517153996a51518ee9608cd79f8959fb9d71db`

Hypatia reports parent-delegated original-app restoration. The retained log
records simctl launch success (returncode0, PID68383) for the existing app,
prototype=0, threaded-memory=0, vCPU count2 and the listed baseline environment;
it declares no install/reset/image/default changes. This is reviewed launch
evidence, not independent inspection of the running guest or proof of complete
live-state restoration. Reviewer performed no app/Simulator actions.

The Review 3 acceptance lines remain historical evidence for this run; they do
not authorize a retry, pooling, or a different bundle. No rescheduling or
termination of unrelated processes is requested. Parent and measurement owner
were notified of the ineligible disposition and restoration evidence.

## Review 5: Report Interpretation

The measurement report's blocked/no-ranking disposition, mixed cold/warm
policy warning, shared-helper limitations, and launch-versus-guest-ready
distinction agree with the reviewed evidence. No measured causal attribution
is accepted. Two precision corrections were requested from its owner:

- Full expected-state checks and JSON output follow timing, but checkpoint
  invariant CHECKs execute inside the measured path (`fixture.c:16`). They
  must not be described as entirely excluded assertion overhead.
- Warmup has CPU/RAM/step assertions, but the code-epoch baseline is captured
  after warmup (`fixture.c:137`). The final code/epoch comparison protects the
  measured interval, not an independently checked warmup epoch interval.

The report should describe absence of an accepted complete-cohort estimate,
not mathematical impossibility of a finite interval from partial samples.
The corrections were subsequently verified and final wording signed off below;
failed-cohort disposition remains accepted and unchanged.

fresh_cohort.py was read statically only. It checks original bundle identity,
requires a new direct-child output directory, and copies untimed metadata while
referencing existing source/binary artifacts; it does not run native code.
It is outside the approved timing bundle and has not been executed or approved
for a retry by this reviewer. No inference of restored host quietness or renewed
VM authority follows from metadata reuse. Any retry needs a new exact bundle
and explicit parent/measurement-owner coordination.

### Final Prose Signoff

Accepted the corrected wording of docs/phase1-attribution-results.md at SHA256
`202967205404adb2906273fa935fd210e111165647a183c24e74c0bd50cbf231`.
All three requested corrections are present: checkpoint invariant checks are
inside the measured path; warmup expected-state checks are distinguished from
the post-warmup code-epoch interval; the report makes no inferential performance
claim from the protocol-excluded cohort. The cold/warm mixed-policy caveat and
the launch-success-versus-guest-ready limitation remain explicit.

Reviewer independently rehashed all 114 entries in final-artifact-hashes.json
with zero mismatches, checked all 19 preservation-file hashes, and compared the
current Sources/scripts/Apps dirty diff to the retained freeze manifest: equal.
Static assembly is retained evidence only; no cost/ranking conclusion is
certified from it. No reviewer compilation or native execution was performed.

This is final prose/failed-cohort-disposition signoff only. The 84 partial
samples remain excluded, timing attribution remains open, and no new timing,
retry, rescheduling, app action or production change is authorized.

## Review 6: Completed Fresh Cohort

The user subsequently authorized a fresh cohort and the parent accepted its
exact bundle before collection, as recorded at the top of this document.
This review accepts the measured interpretation of that completed retry within
the limits below. Earlier blocked-cohort decisions remain valid for their own
84 samples, which are not rehabilitated or pooled with the retry.

Run: `experiments/phase1/results/20261029-retry-01`.
Artifact SHA256 identities independently checked:

- review-bundle.json: `e530182a7c96c2473926279869e25b385759d464accb074e59cb7a5d8e6eec24`
- timings.jsonl: `25baa4f80d7f0a8e1676eb61891e88665be7c520e6393894c3bf3d48b6642721`
- summary.json: `d0670b7cdd7b52979ab7ef3bc3b4b85d360a127ad2cbfdad1553293100831fe1`
- contrasts.json: `07034ab9d09d5f53535945d488b3197f34997f3be78459b8408502eff0e46a58`
- app-restoration.json: `ae10b48dd15c970b6536dadfd41561868730e110b4b763ee536228cdf6522757`

### Collection And Identity Checks

Structured comparison confirms that only bundle.run differs from the prior
accepted bundle. The reviewer repeated 651 hash comparisons covering the
manifest, tooling, verification evidence, all arm/verification records, source
trees and binaries, plus current native/script sources against the frozen base.
All matched. Build commands/return codes match the arm manifests, and timing
commands omit P1_LEDGER. The copied approval text contains the new bundle hash,
its own recorded SHA matches, and it specifies 11 samples. Untimed results are
reused evidence for identical artifacts, not newly executed tests.

The reviewer read all 704 timing records and independently enumerated the
expected cells from the selected workloads/executors: 14 arithmetic cells and
18 memory cells per warmness, 64 in total. Each has exactly rounds 0 through10,
one successful sample per round. Chronological order matches the declared
forward/reverse alternation exactly. No duplicate, missing or extra cell/round
was found. The four workload/warmness groups contain 154,154,198,198 records.

Every record runs the matching timing binary with the correct workload/mode,
statistics setting, warmness, one-million-step budget and timing enabled.
All returncodes are zero; full CPU/RAM assertions are reported, final steps
and status are correct, checkpoint maxima are <=4096, and memory faults are
zero. CPU bytes, RAM fingerprint and retained checkpoint/superblock/semantic/
prototype/revalidation/invalidation counters match the corresponding reviewed
million-step verification record. This confirms observed architectural and
policy agreement without mistaking omitted statistics for absent work.

All 89 load files were inspected: 91 observations including three preflight
observations and both sides of all 44 rounds. Every declared load gate passes;
maximum sampled total CPU is 128.6%, maximum individual CPU44.9%, and Pinecone
is absent. No compiler or fixture process appears in these snapshots. These
are sampled observations, not proof of continuous absence of interference.
timing-status.json is complete, summary eligibility is true, and all summary
sample arrays/counts/medians reproduce from the raw records.

### Contrasts And Ranking

The reviewer independently recomputed every paired effect array and median in
contrasts.json from the raw rows. The analyzer was read, not executed; its
bootstrap intervals are descriptive n=11 within-cohort intervals, not formal
cross-host guarantees. Alternation does not eliminate drift, temporal dependence,
frequency variation or layout effects, and there is no multiplicity correction.

The dominant demonstrated intervention among these tested controls is reducing
short-invocation frequency while retaining per-instruction guards. Cap4->4096
paired warm reductions are 11.844 ms arithmetic and 14.865 ms memory per million
steps, with the reported descriptive intervals [11.693,11.964] and
[14.793,15.017] ms. This is a wrapper/lookup/pinning/entry-validation/statistics/
outer-accounting frequency bundle, not dispatch-only cost or independent cycle
shares. The experiment establishes a large sensitivity to this policy; it does
not allocate the gain separately among its components.

Arithmetic entry-only validation at the original cap reduces the paired
prototype-minus-C gap by 0.649 ms warm [0.532,0.739]. Wrapper block/step-statistic
omission reduces it by 0.128 ms [0.087,0.224], a much smaller and less robust
effect: one warm paired difference is negative, and its cold interval includes
zero. These omission contrasts are arithmetic-only and must not be generalized
to memory or treated as safe production changes. Their CPU-time paired medians
(approximately0.658 and0.150 ms warm) agree in direction, not exact magnitude.

Memory detailed-statistic omission gives a warm gap change of -0.105 ms
[-0.243,0.027], not evidence of a meaningful differential improvement. It
changes shared helper work in both executors. This does not prove that the
statistics cost is exactly zero, that emitted helper costs are equal, or that
all memory overhead has been ruled out. No shared-epoch contention exists in
this raw-RAM fixture. None of these effects may be summed as independent costs.

### Plateau And Control Compatibility

The sweep supports diminishing returns, not a flat plateau or an optimal safe
cap. The directly paired warm256->4096 improvement is0.246 ms arithmetic
(all11 differences positive) and0.256 ms memory (10of11 positive). These differ
from the valid differences of cell medians,0.236 and0.271 ms respectively.
The report labels the latter as median elapsed-time reductions correctly.
The gains remain material relative to the remaining runtime, but no experiment
above4096, active deadline, interrupt latency or real working set selects an
optimal production window.

Baseline and cost-reference timing binaries are byte-identical; their timing
source hashes differ only in the preparation metadata record. This is a strong
compatibility check, not permission to pool their separately ordered samples.
Warm reference-minus-baseline paired medians are -0.038 ms for both arithmetic
executors, and -0.149/-0.145 ms for memory C/prototype. That variation is relevant
to interpreting sub-millisecond controls. Cap4-minus-unchanged-prototype paired
warm medians are0.007 ms arithmetic and-0.024 ms memory: consistent controls at
this resolution, not proof of exact timing equivalence. Keep matched references.

analyze_results.py:57 always writes the unchanged baseline TP-minus-C median
into paired_baseline_gap_median_ms, even when the actual contrast reference is
cap4 or cost-reference/stats-on. The effect arrays themselves use the correct
matched references at lines41 and46. Do not relabel that field as the matched
reference gap, or subtract displayed median gaps to reconstruct paired effects.
The reviewed report uses the correct formulas, so this presentation caveat is
not a blocker for its current tables.

### Superblocks And Noise

Disabling established superblock lookup/composition improves warm established
C by paired medians0.401 ms arithmetic and1.582 ms memory (11of11 positive
for each). Thus loss of a beneficial superblock path is not supported as this
tiny-loop regression's explanation. The unchanged established semantic handlers
and direct links still execute; the entire policy changes, not just one dispatch
instruction. The ledgers show established entries falling from7813 warm to245
with suppression. This is not a recommendation to disable general superblocks.

Cap4096 prototype remains faster than superblock-off C by paired warm medians
0.981 ms arithmetic and1.225 ms memory. This closes the immediate comparison
confound but still does not measure native-host execution, general interpreter
throughput, application latency or a production-safe continuation policy.

All outliers remain included. Warm-memory round6 includes baseline C17.960 ms
and cap4 prototype25.274 ms; their thread CPU times also rise to17.138458 and
25.004166 ms. Do not label these solely descheduling delays or infer that
passing process gates proves perfect quiet. The large invocation effect is
well separated from the smaller controls in this cohort; exact small-effect
rankings and bootstrap endpoints deserve less weight than that broad result.

Cold memory retains998779 prototype steps plus1221 established steps, versus
one million prototype steps warm. Cold-minus-warm is still a mixed preparation/
execution-policy contrast, not pure preparation cost. Equal hot-helper counts
and static emitted instructions identify work structure, not cycle fractions.

### Scoped Signoff

Reviewed docs/phase1-clean-cohort-results.md at SHA256
`6cf9fe6f2dbba98e663d9aaa1a7ea0f700854498c75b79a13468963a1d575e6a`:
no blocking numerical or interpretation issue. Its medians, paired contrasts,
superblock finding, diminishing-return language, retained-outlier disclosure
and bounded claims match the inspected evidence. Parent owns any subsequent
report/roadmap edits; reviewer changed only this append-only review section.

Accept completion of Phase1's bounded synthetic attribution objective and
advancement to Phase2 contract design, prioritizing continuation boundaries,
precise exits, event/deadline service, visibility and two-vCPU reclamation.
Do not describe this as exhaustive attribution of every handler/helper cycle
or fulfillment of production correctness/latency gates. Further implementation,
guard removal, assembly rewriting and default changes are not authorized by
this signoff. The established app executor remains the production reference.

Restoration evidence records successful original-app launch PID70641 with
established C, prototype/memory disabled and two parallel vCPUs. This is launch
evidence, not a new independent guest-ready observation. No native runs,
compilation, Simulator actions, source changes or additional timing were
performed by this reviewer. No new experiment or retry is requested.
