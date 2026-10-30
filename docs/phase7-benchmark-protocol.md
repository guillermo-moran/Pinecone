# Phase 7 Benchmark Preparation

Status: protocol and offline harness preparation only. No timed cohort, build,
Simulator action, seed modification, speedup claim or promotion is authorized
by this preparation. The main agent owns serialization of any later cohorts.
Read this with `roadmap.md` and `docs/phase7-assembly-integration.md`. Earlier
adapter smoke runs are diagnostic evidence, not a matched baseline.

## Fixed Contract

Use one already-built Release app containing both executors, one frozen seed
and its matching bundle fingerprint, two parallel vCPUs, and one explicitly
selected disposable Simulator. Do not build/install/update between variants.
Never use the user's working Simulator or its active disk as the seed.

The harness sets all five executor flags on every launch:

| Mode | ASSEMBLY_EXECUTOR | ASSEMBLY_CHAINING | ASSEMBLY_BOUNDED | THREADED_PROTOTYPE | THREADED_MEMORY |
| --- | ---: | ---: | ---: | ---: | ---: |
| established | 0 | 0 | 0 | 0 | 0 |
| assembly | 1 | 0 | 0 | 0 | 0 |
| assembly-chain | 1 | 1 | 0 | 0 | 0 |
| assembly-bounded | 1 | 1 | 1 | 0 | 0 |
| threaded | 0 | 0 | 0 | 1 | 0 |
| memory | 0 | 0 | 0 | 1 | 1 |

Each name has the `PINECONE_` prefix. Assembly and threaded C are mutually
exclusive; the memory mode is explicitly the threaded-C scalar-memory variant.
Inherited direct and `SIMCTL_CHILD_PINECONE_*` variables are removed. Fixed
settings enable performance JSON, UART and interaction tracing; disable hot-PC
profiling and automatic unlock. Do not change instrumentation between modes.
Unsupported assembly work continues in established C, never Swift fallback.
Current builds must publish `chainEnabled`, `chainRuns`, `chainVisits`, and
`chainSteps` in assembly statistics. The harness rejects missing or conflicting
chain flags/counters and requires nonzero primary chain work at readiness for
`assembly-chain` and `assembly-bounded`. Current builds must also publish
`boundedEnabled`, `boundedRuns`, `boundedVisits`, and `boundedSteps`. Bounded
counters are a subset of aggregate chain counters, must remain zero when
disabled, and must show actual primary work at readiness in bounded mode.
The bounded switch alone does not enable assembly execution or chaining.
Older builds without these fields need the older harness;
an absent field is not evidence that chaining was disabled. Matching ordinary
assembly and assembly-chain in the same binary isolates runtime selection;
comparison against a frozen earlier binary is still needed to detect changes
to the ordinary assembly entry itself.
`PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS=0` is explicitly set for every variant by
default, including when the parent environment requests instrumentation.

## Prerequisites and Manifest

The coordinator must supply real paths; this document does not identify or
invent an available seed. Before any live invocation:

- Obtain explicit authorization to overwrite the selected disposable app's
  `rootfs.ext4`, replace its fingerprint, clear its rolling telemetry and
  terminate/relaunch its app. The device must already be booted with the app
  installed. The harness does not boot, shut down, erase or install devices.
- Preserve an immutable, quiescent, independently verified seed and matching
  fingerprint outside the disposable container. Verify packaged kernel/rootfs
  provenance and guest versions. A mismatched fingerprint can trigger app-side
  bundle restoration and invalidate the measurement.
- Freeze the executable hash, seed hash and fingerprint hash. Freeze source
  revision plus dirty diff/untracked-source content hashes, toolchain/version,
  build configuration and compiler flags. Do not discard dirty source changes.
- Record kernel hash, guest package versions, Simulator runtime/device model,
  host model/OS, power/thermal state and background load. Disable concurrent
  builds, test VMs, profiling, video analysis and other cohorts. Any necessary
  recording must use the same predeclared configuration in both modes.
- Validate the input driver's coordinates, down/up sequence and actual contact
  duration. Record the tap-to-unlock protocol, not the historical swipe protocol.
- Predeclare workload state, cold/warm classes, observer/guest deadlines,
  acceptance budgets and handling of interruptions before collecting results.

Supply a JSON object using this schema. Values in angle brackets are required
provenance to fill, not usable hashes or discovered paths:

```json
{
  "schemaVersion": 1,
  "cacheDiagnostics": "off",
  "appSHA256": "<64 lowercase hex digits for the installed Pinecone executable>",
  "seedSHA256": "<64 lowercase hex digits for the immutable seed>",
  "fingerprintSHA256": "<64 lowercase hex digits for the fingerprint file>",
  "kernelSHA256": "<64 lowercase hex digits for the matching kernel>",
  "sourceState": "<revision, dirty diff and untracked source hashes; archived evidence>",
  "compilerFlags": "<toolchain version, Release configuration and exact flags>",
  "guestPackages": "<kernel, Phosh, Firefox and relevant package versions>",
  "hostConditions": "<hardware, power/thermal/load conditions and instrumentation>",
  "inputProtocol": "<validated driver/contact/coordinates, workload classes, deadlines and budgets>"
}
```

The manifest is copied into `identity.json`. Executable, seed and fingerprint
hashes are checked before/after every attempt; the cloned rootfs is hashed
before replacement. `--plan-only` checks local seed/fingerprint identity but
cannot check the installed executable without contacting Simulator. Kernel,
build, source and package provenance are coordinator attestations: this harness
does not locate/re-hash bundled kernel resources, prove package versions or
verify whole-bundle identity. Archive their supporting evidence separately.

## Separate Cache Attribution

`--cache-diagnostics {off,counts,time}` defaults to `off`. Counts maps to runtime
`PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS=1`; preparation timing maps to `time`.
Enabled runs require a separately supplied binary built with
`AVZ_ASSEMBLY_CACHE_DIAGNOSTICS=1` and matching executable hash/compiler provenance.
The manifest must explicitly declare `cacheDiagnostics` with the same value as
the CLI. Existing manifests must add `"cacheDiagnostics": "off"` for clean runs.
Settings preserve the exact runtime value; identity and per-attempt results
declare `instrumentation.cacheDiagnostics` and `cohortKind` (`clean` or
`attribution`). Here "clean" means runtime cache diagnostics off, not absence of
the other fixed tracing. Record compile-time diagnostics in compiler provenance
even when runtime-disabled; do not pool different binaries as a clean cohort.

For later attribution, use the invocation below with a **new attribution
manifest/output**, its matching installed diagnostic binary, and add
`--cache-diagnostics counts` or `--cache-diagnostics time`. Use `--plan-only`
first for local validation. No diagnostic build or installation is performed by
this harness. Never merge counts/time observations with clean boot or interaction
latencies, or with each other: timing includes additional clock overhead.

At readiness, requested enabled diagnostics require nonempty primary and
secondary cache records, each with integer `compiled=1`, `enabled=1`, the
requested `timingEnabled` (0 for counts, 1 for time), and
`publishedHostNanoseconds`. Present records are checked on every poll; mismatches
fail and retain evidence. Clean runs reject present enabled/timing telemetry.
Older reports lacking cache telemetry can still be read in off mode; missing
records are not evidence of zero activity or verified compile-time exclusion.

## Planned Cohorts

### Before/After Fix Screening

Read `phase7-cache-integration-results.md` first. Its C/assembly screen rejected
the previous candidate; it did not compare this round's performance fixes.
The retained clean baseline is `/tmp/pinecone-phase7-cache-clean.app`; its
`Pinecone` executable was verified read-only for this preparation as
`7388d149e15ccc5b0457a094f1178b00c1d06dc2f4acf4c78fa1ad9349178ef2`.
Use that binary, not a rebuild of the now-dirty source, as the before build.

The harness deliberately never installs or switches builds. One invocation has
one executable identity. `--compare-to /absolute/reference/identity.json` allows
a different app hash/source state across invocations while requiring identical
seed/fingerprint/kernel, compiler configuration, guest packages, declared host
conditions/input protocol, runtime settings, instrumentation, vCPU setup,
deadlines, harness hash and per-mode attempt counts. Order may reverse, and
observer file paths may differ, but boot-only and observer runs cannot mix.
Live comparison also checks actual host OS/hardware before any app termination.
The comparison records both hashes, both orders, and the reference identity
file hash. It validates the contract, not successful completion or stable load.
Inspect every summary/failure and raw observation independently. Historical
cohorts without this harness hash are context only: collect fresh baseline runs
with the same frozen harness used for the candidate.

The predeclared screen in `phase7-dispatch-retention-results.md` is authoritative:
baseline assembly, candidate assembly, baseline assembly, candidate assembly,
then a separate current-candidate established-C control. Five single-run
invocations, restoring the same seed each time; no expanded cohort is implied.
The C control checks current competitiveness, not before/after C regression:
historical C results remain context, not a matched current baseline. Do not
attribute an integrated bundle's change solely to cache policy. This screen
cannot close the five-pair/interaction promotion gate. Retain every failed or
interrupted attempt; do not repeat runs merely to find a favorable sample.

Prerequisites: coordinator authorization, frozen baseline/candidate source and
binary identities, passing owner-supplied correctness results (invalidation,
pinned retirement, checkpoint/timer accounting and two-vCPU cases), identical
guest assets/fingerprint, clean diagnostics off in both builds, no concurrent
builds/tests/profiling, and an unchanged Simulator runtime/device model. Runtime
identity and thermal/background load remain coordinator checks. Freeze manifest
`inputProtocol` to this schedule in both builds; do not copy the old screen's
PID-specific host observations as current facts. `sourceState` must differ to
describe actual sources; `compilerFlags` must describe equal build settings.

Disk check during this preparation: approximately **3.3 GiB available**, not a
capacity guarantee. The previous install already failed for lack of disk space.
Before staging/installing, coordinator checks `df -h /tmp` and actual app/data,
clone copy-on-write, log/video and temporary install space requirements. Leave
an explicit reserve; do not start if headroom is insufficient. Do not copy full
seed disks per attempt, delete evidence, or clean unrelated data to make room.
APFS cloning avoids an eager full copy, not subsequent guest-write allocations.

Coordinator-only command outline, **not executed during preparation**. Export
verified `DEVICE_UUID`, `SEED`, `FINGERPRINT`, `BASE_MANIFEST`, `CAND_MANIFEST`,
`CANDIDATE_APP`, and fresh `BEFORE1`, `AFTER1`, `BEFORE2`, `AFTER2`, `CONTROL` output paths.
The saved clean manifest identifies seed/fingerprint paths under
`artifacts/linux-shell/out/`; these are historical locations, not proof they
still have the recorded hashes. The harness rechecks supplied files. Do not
invent or silently substitute a seed. Each install below requires the coordinator
to confirm the disposable app is stopped first; stop no unrelated VM/process.

```bash
HARNESS=/Users/gmoran/Documents/Projects/arm64viz/scripts/benchmark-simulator-executors.py
BASELINE_APP=/tmp/pinecone-phase7-cache-clean.app
bench() {
  local manifest="$1" output="$2"; shift 2
  python3 -B "$HARNESS" --device "${DEVICE_UUID:?}" \
    --confirm-disposable-device "$DEVICE_UUID" \
    --seed "${SEED:?}" --fingerprint "${FINGERPRINT:?}" \
    --manifest "$manifest" --output "$output" \
    --cache-diagnostics off --timeout 600 --idle-seconds 15 "$@"
}
# Before any installation: local-only manifest/seed checks for each build.
bench "${BASE_MANIFEST:?}" "${BEFORE1:?}" --order assembly --plan-only
bench "${CAND_MANIFEST:?}" "${AFTER1:?}" --order assembly --plan-only

# Later, coordinator confirms stopped disposable app and installs baseline.
xcrun simctl install "$DEVICE_UUID" "$BASELINE_APP"
bench "$BASE_MANIFEST" "$BEFORE1" --order assembly
# Inspect BEFORE1; coordinator confirms stopped app before replacing its build.
xcrun simctl install "$DEVICE_UUID" "${CANDIDATE_APP:?}"
bench "$CAND_MANIFEST" "$AFTER1" --order assembly --compare-to "$BEFORE1/identity.json"
# Inspect AFTER1; coordinator confirms stopped app before baseline reinstall.
xcrun simctl install "$DEVICE_UUID" "$BASELINE_APP"
bench "$BASE_MANIFEST" "${BEFORE2:?}" --order assembly --compare-to "$BEFORE1/identity.json"
# Inspect BEFORE2; coordinator confirms stopped app before candidate reinstall.
xcrun simctl install "$DEVICE_UUID" "$CANDIDATE_APP"
bench "$CAND_MANIFEST" "${AFTER2:?}" --order assembly --compare-to "$BEFORE1/identity.json"
# Separate C control on the same candidate; do not compare unlike executor settings.
bench "$CAND_MANIFEST" "${CONTROL:?}" --order established
```

These are staged commands with inspection/stop checkpoints, not an unattended
paste-and-run script. The preserved baseline bundle remains untouched; the last app is left active
by the harness and cleanup remains coordinator-owned. A successful screen only
permits the separately coordinated semantic checks/full matched cohorts below.
Use separate single-mode invocations with completion JSON for interactions;
boot-only readiness or application milestone timestamps cannot replace them.

Primary comparison: five matched pairs, ten boots total, ordered
`established assembly established assembly established assembly established assembly established assembly`.
Restore the exact same seed before every boot. Keep the pair identity and order
in analysis. A later independent reversed-order cohort can assess order effects;
do not silently merge it with the first. Optional threaded/memory comparisons
are separate declared cohorts, not replacements for either primary mode.

At least 20 valid semantic interaction attempts **per mode, per applicable
workload/state cohort** are required; twenty total across all workloads is not
sufficient. Plan four repetitions per boot across five matched boot pairs when
the state permits it. Cold launches require a genuine predeclared process/state
reset and cannot be counted as repeated warm activations. Use separate matched
boot pairs where needed. The boot-only command below does not drive or count
interactions, and the harness does not enforce the aggregate sample quota.

Record lock-screen rendering, ordinary tap-to-unlock to Home, Settings launch
with legible text/icons, and return Home. Keep cold launch and warm activation
distributions separate. Firefox local-page launch, changed button text, exact
entered text and a reached scroll target are separate workloads, gated on a
reliable passing Track U baseline. An unresolved Firefox event remains a
failure, not a latency sample or permission to promote assembly.

For every attempt retain workload/state, mode, boot/pair ID, validated input,
expected result, observed result, raw video/screenshots/traces, timestamps,
latency if actually measured, and outcome. Distinguish semantic failure,
invalid input, guest-reported timeout and observer deadline. A click tool return,
injected event, unrelated frame or existence of a completion file is not success.
Count failures in denominators; do not replace or drop them. Extra attempts
needed for the valid-attempt quota are explicitly appended, matched and labeled.

## Invocations for Later Use

Requires macOS, Xcode `xcrun simctl`, APFS clone support for `cp -c`, and Python
3.9+ using only its standard library. The coordinator must first export
`DEVICE_UUID`, `SEED`, `FINGERPRINT`, `MANIFEST` and `OUTPUT` to verified absolute
paths/values; `OUTPUT` must be new and outside the Simulator container. Never
run two harnesses against the same device. No seed path is supplied here.

Local-only validation, with no Simulator commands or output directory creation:

```sh
python3 -B /Users/gmoran/Documents/Projects/arm64viz/scripts/benchmark-simulator-executors.py \
  --device "${DEVICE_UUID:?export the disposable Simulator UUID}" \
  --seed "${SEED:?export the verified immutable seed path}" \
  --fingerprint "${FINGERPRINT:?export the matching fingerprint path}" \
  --manifest "${MANIFEST:?export the completed manifest path}" \
  --output "${OUTPUT:?export a new output directory path}" \
  --order established assembly established assembly established assembly established assembly established assembly \
  --timeout 600 --idle-seconds 15 --plan-only
```

Ready-to-run boot cohort, **only after later authorization and serialization**:

```sh
python3 -B /Users/gmoran/Documents/Projects/arm64viz/scripts/benchmark-simulator-executors.py \
  --device "${DEVICE_UUID:?}" --confirm-disposable-device "${DEVICE_UUID:?}" \
  --seed "${SEED:?}" --fingerprint "${FINGERPRINT:?}" --manifest "${MANIFEST:?}" \
  --output "${OUTPUT:?}" \
  --order established assembly established assembly established assembly established assembly established assembly \
  --timeout 600 --idle-seconds 15
```

The 600-second observer ceiling is a predeclared operational limit, not an
expected duration or performance budget. Set acceptance budgets from Phase 0
before running. Each attempt stops the app before restoring the disposable disk.
Only a successful termination or the explicit simctl "found nothing to
terminate" result permits restoration. Unknown termination errors abort.
The last app remains active; failures can also leave it active for inspection.
No automatic cleanup may erase failure evidence. The coordinator owns cleanup.

For an interaction-observed boot use the same options but a single `--order`
mode and add `--completion-file "${COMPLETION:?export a new observer JSON path}"`.
Serialize these single-boot invocations in the same alternating order, use new
output/completion paths each time, and keep a separate pair/cohort ledger.
The observer must atomically publish JSON after observing outcomes, for example:

```json
{
  "attemptId": "01-assembly",
  "variant": "assembly",
  "attempts": [{
    "id": "unlock-1",
    "workload": "tap-to-unlock",
    "inputProtocol": "<validated driver and contact trace reference>",
    "expected": "Home is rendered",
    "observed": "<actual semantic observation>",
    "evidence": "<retained video/frame/trace reference>",
    "outcome": "observer_timeout",
    "latencyMilliseconds": null
  }]
}
```

This is a schema example, not a recorded attempt. Allowed outcomes are `success`,
`failure`, `observer_timeout`, `guest_timeout`, `invalid_input`. Success requires
a finite nonnegative measured latency plus observation/input/evidence strings.
The harness validates structure and identity, not the truth of external visual
evidence. It rejects old empty sentinel files; any failed semantic outcome
fails the boot record while retaining all attempts. A marker cannot bypass
guest readiness. Record partial observations as they happen in an independent
append-only ledger so an observer crash cannot erase them. The completion JSON
is only the final batch handoff, not the sole raw evidence store.

`--firefox-local` and `--firefox-blank` retain their explicit fixture behavior:
launch after readiness plus 15 seconds with a fresh `/tmp` browser profile on
the restored guest. These are not normal warm-profile activations. Do not use
them in the boot-only cohort; they alter the post-readiness workload.

## Evidence and Gaps

`summary.json` initially lists the whole order as `notAttempted`. Every attempted
run gets its own directory with settings, a persistent `result.json`, rolling
samples, raw performance JSON/log and UART when available. Readiness gets
`ready.json` and a diagnostic screenshot. `latest-report.json` preserves parsed
input even on a flag/schema failure. Launch/termination failures, sampling
errors, timeout, mismatched identity, screenshot errors and KeyboardInterrupt
remain failures. The cohort stops at the first failure and leaves later rows
`notAttempted`; it never auto-retries or silently counts them as successes.
Container-safety/argument rejection happens before starting an attempt; later
cohort setup errors are retained in `cohort-failure.json`.

`owner-telemetry.jsonl` retains each polled `assemblyExecutorSecondaryByVCPU`,
`assemblyCachePrimary` and `assemblyCacheSecondaryByVCPU` record, including
unknown future counters, string vCPU IDs and exact integer publication times.
These fields also survive readiness/latest summary parsing and raw report
archival. Cache snapshots are owner-published at most once per second, not
atomic with primary statistics, guest milestones or each other. Repeated
`publishedHostNanoseconds` values are the same publication, not new samples;
compute deltas only within a vCPU/window and retain timestamp/reset boundaries.
Do not treat host monotonic nanoseconds as epoch time or observer elapsed time.
Before/after counter meanings also need review: removing duplicate preparation
changes cache-request/hit counts per executed block, and slice-boundary execution
counter publication changes observation lag. A lower raw request count alone is
not improved retention; a report-time steps ratio is not an atomic milestone
measurement. New budget/byte counters remain preserved without hard-coded FIFO
capacity assumptions. Cache-owned bytes exclude retired-but-pinned programs and
allocator overhead; they are not an absolute live-memory bound.

`milestone-observations.jsonl` records each first-observed boot/application
milestone, its app-relative time, observer-relative time and any both-vCPU
execution counters. Repeated polls are not repeated launches. A milestone
changing during one run fails the attempt (possible reset/mixed telemetry).
All published execution-milestone counters are validated, and nonzero Swift
fallback fails even after readiness. Reports still do not provide continuous
end-of-interaction execution totals. Repeated interactions require external
semantic evidence and unique attempt IDs; app first-frame/surface milestones
alone do not acknowledge an input or prove Settings rendered correctly.

- `guestReadySeconds` is `interactiveWorkloadReady`, timed by the app's guest
  execution timeline. `firstVisibleFrameSeconds` is recorded separately and may
  be an early/blank frame. Neither proves a rendered lock screen or usable UI.
  `observedReadySeconds` starts before simctl launch and includes launch/polling
  delay; it is not interchangeable with guest readiness.
- Primary native/fallback and secondary total/native/fallback counters are
  required at readiness. Combined native work sums both native counters; never
  use the primary badge alone. Both fallback counts must be zero. Milestone
  counters are not continuous end-of-interaction totals; later milestones and
  raw telemetry must be inspected for failures after readiness.
- Assembly enabled/blocks/steps/boundaries/faults and threaded primary stats
  are retained at readiness and latest observation, plus raw reports. Assembly
  mode requires nonzero primary assembly work. Faults can be ordinary guest
  memory exceptions, not necessarily unsupported opcodes. Stats are sampled at
  report publication, not atomically at the earlier readiness milestone.
- Secondary assembly stats now use `assemblyExecutorSecondaryByVCPU`; present
  secondary enabled flags are checked against the selected executor. Legacy
  missing records remain `null`, never inferred zero. Secondary threaded stats
  and complete helper/checkpoint attribution remain unavailable. Enabled cache
  attribution provides request/hit/preparation/eviction and program-byte counters
  through the owner-published snapshots; it is not total process or guest memory.
- `ps` CPU seconds/%CPU and RSS concern the app process only. They exclude
  Simulator services, GPU/WindowServer work and total machine CPU. CPU sampling
  is about once per second, includes polling/observer delay and uses a different
  start point from guest readiness. Mean app CPU can exceed 100% with threads;
  it is not host utilization or per-vCPU accounting.
- `sampledPeakRSSMiB` is the largest observed RSS, not a true peak, physical
  footprint, executable/cache allocation growth or guest memory pressure. No
  samples means `null`, not zero. Diagnostic program/cache bytes supplement RSS
  only in separate attribution runs; physical footprint, other allocation growth
  and guest memory-pressure gaps remain open gates.
- Hashing/cloning warms host file caches; they are not flushed. Tracing, metric
  writing, UART, screenshot and observer/recording overhead are not calibrated.
  Keep them matched and report the limitation. Physical-device thermal/memory
  validation remains separate; Simulator evidence cannot establish iPhone gains.

Later analysis must retain paired raw distributions and every failure, report
successful latency medians/tails/max with sample counts and cautious small-sample
p95, and compare only identical identities/workload states. Do not tune budgets
after seeing results. Promotion also requires no crashes, corrupt text, lost
input, stale code, disk corruption or unexplained memory growth. Preparation
and passing harness unit tests make no performance or promotion claim.

## Offline Verification

```sh
python3 -B /Users/gmoran/Documents/Projects/arm64viz/scripts/test-benchmark-simulator-executors.py -v
```

The tests create tiny temporary fixture files, never seed disks or Simulators.
All subprocess entry points fail closed unless explicitly mocked; waits use a
fake clock. Coverage includes exclusive environment flags, manifest identity,
report counters/readiness, semantic completion, symlink/hardlink safety,
destructive authorization, and retained failures. These tests do not validate
simctl compatibility, actual bootability, input-driver accuracy or performance.
