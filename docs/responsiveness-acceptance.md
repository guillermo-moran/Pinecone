# Repeatable Phosh interaction acceptance

This is an **offline collection contract and validator**, not a Simulator driver.
The parent owns CUA input, screenshots, profiling, image identity, and observation.
`scripts/phosh-interaction-acceptance.py` never launches, restarts, installs, builds,
changes vCPUs, changes guardrails, or enables fallback. It uses only Python's
standard library and supplied files. The existing profiling script received only
the schema-compatibility changes described below; it is not invoked by this harness.

## What counts

Three kinds of evidence stay separate:

- **Functional:** an identified observer sees the specific requested state in
  before/after evidence. Frame production, injection, accessibility actions,
  a compile pass, and the number of trace records do not establish success.
- **Semantic timing:** same-clock input and timestamped observations provide
  `[last absent - input start, first present - input start]`. Reports summarize
  the upper bounds, not exact touch-to-photon latency. Observation/screenshot
  polling delay is included. A late screenshot is not an exact completion time.
- **Runtime diagnostics:** current frame associations are uncorrelated or expired.
  They remain raw with source provenance, never enter semantic percentiles, and
  never prove unlock. Guest and host clocks are never subtracted.

Passing means the supplied observer evidence satisfies the declared protocol and
budgets. It does not mean native responsiveness, absence of unseen faults, or a
measured improvement. No automatic speedup claim is generated.

## Canonical workload

Generate at least ten attempts in each mandatory cohort. Keep all failed attempts;
do not replace them with retries. Execute sequentially, restore each precondition,
and finish the current observation window before preparing the next attempt.

| Cohort | Precondition and action | Required observation |
| --- | --- | --- |
| `unlock-full` | Locked, awake display; continuous full bottom-to-top swipe inside the guest viewport | Lock screen gone and unlocked home content visible after pointer release |
| `scroll-short` | Same scrollable content/initial position; ordinary short swipe | Identifiable content anchor has moved in the intended direction |
| `scroll-long` | Same scrollable content/initial position; ordinary longer swipe | Identifiable content anchor has moved in the intended direction |
| `keyboard` | Same empty editable field; focus by tap, type the fixed test string with individual on-screen key taps | Keyboard visible and exact typed string appears in the intended field |
| `app-cold` | Target process absent, then real Phosh icon tap | Target app's usable expected content visible, not just splash/loading/window creation |
| `app-warm` | Same previously presented target process remains resident; return to shell and tap its icon | Same usable app content visible |

**Unlock requires full travel, not a short swipe.** Coordinates are normalized to
the guest display viewport, excluding Simulator chrome, device bezel, and host
window controls. The canonical path is `(0.50, 0.98)` to `(0.50, 0.02)`, tolerance
0.02 per coordinate, duration 120-1200 ms. Record actual pointer-down/up duration,
actual endpoints, continuous contact, and at least four motion samples. The report
includes actual vertical travel in viewport heights and duration. This range is
a reproducible test definition, not evidence that every duration performs equally.

Optional `unlock-short` attempts use `(0.50, 0.85)` to `(0.50, 0.35)`, 120-350 ms.
They are diagnostic only: remaining locked is not a mandatory acceptance failure
or a regression. They do not substitute for any `unlock-full` repetition. Keep
their before/after observations but omit timing if no unlock occurred.

Scroll-short uses that short path/duration; scroll-long uses `(0.50, 0.85)` to
`(0.50, 0.15)`, 650-1100 ms. Do not include a failed short unlock in the scrolling
cohort. Long slow **accessibility swipe actions** and auto-unlock are diagnostics,
not evidence of ordinary full-travel input. Store them outside the acceptance
attempt set with their actual method; labeling one ordinary makes the evidence
false. An acceptance attempt with a nonordinary method fails validation.

### Actual input-tool limitation

The parent's currently available CUA drag emits only three events in approximately
1 ms. It does **not** implement the continuous gesture protocol above and cannot
produce a valid ordinary-pointer acceptance sample. Do not invent intermediate
motion events, durations, or timestamps in the manifest. A separately validated
continuous input driver plus synchronized observation evidence is needed before
this gate can be completed. The parent's final full-height guest accessibility
`Swipe Up` is explicitly **functional smoke only**, even when it unlocks; it is
not ordinary-pointer acceptance and cannot make the performance gate pass.

## Launch and image provenance

The mandatory app workload uses `launchMethod: "phosh-icon"`. Record the launch
environment and exact profiling settings in the identity configuration. A
`pinecone-launch-settings` TTY helper is not the same launch path: outside the
Phosh session bus it can emit `dconf: Cannot autolaunch D-Bus without X11 DISPLAY`.
Its request/presentation milestones may be diagnostic but cannot be compared to
icon-tap acceptance as equivalent launches. Preserve warnings with the UART log.

`app-cold` means **`cold_process`**, not `clean_image`: verify the target process
is absent immediately before the icon tap and record the absence-check artifact.
The existing rootfs retains earlier dconf settings; filesystem and service caches
are not cleared. Record `imageState: "persisted_user_state"`. A separately prepared
clean image would use `imageState: "clean_image"`; do not prepare/rebuild one as
part of this harness. Record mutable-state hashes/settings under configuration
when they can affect the workload. `app-warm` requires PID plus start identity and
proof the same process previously presented; an earlier launch attempt alone is
not evidence of a warm process. Cold and warm results are never pooled.

## Collect a run

1. Prepare an identity JSON object with `rootfsSha256`, `kernelSha256`, and
   `appSha256` as lowercase SHA-256 strings. Hash the actual tested artifacts;
   do not infer identity from a package version. Its `configuration` must contain
   `vcpuCount`, `swiftFallbackEnabled` (false), `guardrailProfile`, `host`,
   `viewport`, `inputDriver`, `profiling`, `backgroundWork`, `appId`, `scrollTarget`,
   `keyboardTarget`, `launchMethod`, `launchEnvironment`, and `imageState`.
   Include OS/build, viewport scale, enabled tracing/hot-PC/diagnostic flags,
   environment variables, mutable user state, and observation cadence. No device
   identifier is hardcoded. Keep environment secrets out of evidence.
2. Generate an incomplete manifest in a new dedicated directory:

   ```sh
   python3 -B scripts/phosh-interaction-acceptance.py plan \
     --identity /tmp/owner6-input/identity.json \
     --output-dir /tmp/owner6-collection
   ```

3. Before capture, set a unique `runId` and positive `requirements.p95BudgetsMs`
   for all six cohorts. Budgets deliberately have no success-producing defaults.
   Freeze the plan before collecting. Default correlation windows are 5000 ms
   for interactions and 120000 ms for launches; these are expiration windows,
   **not** responsiveness goals or the application's boost duration. Record a
   different predeclared window in both comparison runs if needed. Do not extend
   it afterward to relabel an expired result. The versioned gesture protocol is
   fixed; changing it requires a new protocol version, not silent editing.
4. Parent supplies immutable before/after profile JSON, runtime log, UART log,
   input trace, screenshots/recording, process-state proof, and observations for
   every attempt. Capture the runtime log through the end of the observation.
   File paths may be absolute or relative to the manifest directory. Do not point
   every capture at a mutable live metrics file. Captures must be ordered.
5. Fill the generated attempt entries without deleting failures. Use a monotonic
   collector clock for capture times, input times and observation times. An entire
   synchronized recording can define that clock if capture/input annotations are
   in the same timebase. Do not copy guest elapsed times or wall-clock timestamps
   into this clock. Assign a fresh collector epoch after every runtime reset;
   no attempt may straddle epochs. Record reset failures rather than guessing.
6. Validate and generate JSON plus Markdown in another new directory:

   ```sh
   python3 -B scripts/phosh-interaction-acceptance.py report \
     /tmp/owner6-collection/manifest.json --output-dir /tmp/owner6-report
   ```

Exit 0 from `report` means evidence/protocol/budget acceptance. Exit 1 means
validation failure; inspect `report.json` and `report.md`. Exit 2 means malformed
input or an output/path error. Existing output directories are never overwritten.
The harness source, input manifest and every referenced file are SHA-256 recorded. Archives must
retain the referenced files too; hashes do not make temporary files permanent.

### Capture and observation shape

Each `captures` entry contains:

```json
{
  "id": "unlock-01-before", "epoch": "runtime-A", "clockId": "collector-A",
  "capturedAtMs": 10000, "metrics": "captures/unlock-01-before.json",
  "runtimeLog": "captures/unlock-01-before.runtime.log",
  "uartLog": "captures/unlock-01-before.uart.log"
}
```

Every attempt references `beforeCapture` and `afterCapture`, has that same
`clockId`, `startedAtMs` (first pointer down), and `finishedAtMs` (observation
window end). Before/after capture timestamps must bracket the entire attempt.
Its `input` contains `method: "ordinary-pointer"`, `evidence` (raw CUA/input trace),
and `completedAtMs` (last pointer up/key tap). Swipes also contain `durationMs`,
normalized `start`/`end`, `continuous: true`, and `moveSampleCount`.
App attempts additionally contain `input.launchMethod: "phosh-icon"`.

`precondition.state` is `locked`, `scrollable-content`, `editable-field`,
`process-absent`, or `same-process-resident` as applicable. App preconditions also
contain `appId` matching configuration, `processIdentity` (PID/start identity or
explicit absence-check details), and `evidence` pointing to the process-state
artifact. Cold attempts require `precondition.coldState: "cold_process"`.

An example observation (values illustrate the format, **not measured evidence**):

```json
{
  "status": "pass", "assertion": "unlockedHomeVisible", "observer": "operator",
  "beforeState": "awake lock screen visible", "afterState": "home app grid visible",
  "isolated": true, "noInterveningInput": true, "resetObserved": false,
  "beforeEvidence": "images/unlock-01-before.png",
  "afterEvidence": "images/unlock-01-after.png",
  "timing": {
    "source": "timestamped-semantic-observation", "clockId": "collector-A",
    "lastAbsentAtMs": 10500, "firstPresentAtMs": 10900
  }
}
```

Use the assertion names in generated attempts. A different after-evidence file
is required for each attempt. A frame, changing pixels, input delivery, guest
commit, or splash screen must never be transcribed as an observation of home or
usable application state. `lastAbsentAtMs` must actually show the expected state
absent; `firstPresentAtMs` must show it present **after scripted input completion**.
Reference recording frame numbers/timestamps in the observation notes and keep
the input recording. Keyboard timings include the declared typing sequence;
they are not individual key latency. Other input within that declared sequence
is allowed, but unrelated inputs invalidate isolation and correlation.

The harness validates structure, files, clocks, bounds, counts, and assertions;
it cannot inspect semantics of screenshots or verify an observer's honesty.
Missing an observation is `not_observed`, never inferred success. A functional
`fail` is reported separately from unavailable/expired/invalid latency.

## Runtime schema and reset handling

### Profiler compatibility

`scripts/profile-pinecone-phosh.sh` forwards
`SIMCTL_CHILD_PINECONE_INTERACTION_TRACE` to the host as well as setting the guest
autorun trace environment. `PINECONE_PROFILE_MIN_INTERACTIONS` must be zero;
positive values fail immediately with exit 2, before any `xcrun` command, because
host-to-Phoc causal interaction identity is unavailable. No success is inferred
from a nonempty attribution ring or any input disposition.

With auto-unlock requested, the profiler no longer waits for retired
`touchSampleCount` or `interactions` latency metrics. It emits an explicit stderr
warning: readiness neither waits for injection completion nor proves semantic
unlock. The script can return when readiness/presentation milestones are met;
parent must still observe the UI separately. Requested application presentation,
native-only checks, step and launch-duration limits remain diagnostic gates.
The command-line helper is still not an icon launch. This compatibility fix does
not certify the helper's injection path as an ordinary gesture.

### Capture validation

Legacy `elapsedMilliseconds`, `executionAtMilestones`, `framePipeline`,
`graphics.virtioGPU`, and `interactions` are consumed directly. Required readiness
milestones, fallback counters on both vCPUs, graphics failure counters, and final
runtime fallback counters must be present. Crash signatures in either log fail.
Write-once milestones changing/disappearing, decreasing frame counts, conflicting
generation reuse, invalid stage sums, and mixed clocks fail clearly. Unknown or
malformed JSON is not salvaged by guessing where an object starts.

Owner 1 additions are retained: `inputFrameCorrelation`, `inputAttribution`,
`attributionCounts`, and `guestFrameStages`. Host input identity uses numeric
`epoch`/`sequence` UInt64 values, preserved as Python integers even above 2^53.
Input timestamps are host uptime, not guest timestamps. Injection is not delivery.
`attributionCounts` are cumulative transition counters while the input ring is
bounded; sums need not equal ring length. `reset` and `sequenceWrap` dispositions
are diagnostic outcomes, not automatic semantic failures. Only an actual attempt
crossing a reset fails. New empty `interactions`/zero `touchSampleCount` are valid.
Guest frame-local stage measurements still cannot establish semantic completion.
`handlerCPUUs`, `renderCPUUs`, `submitCPUUs`, and `commitCPUUs` and their derived
millisecond spans use guest `CLOCK_THREAD_CPUTIME_ID`, not host interpreter CPU.
`commitToPresentCallbackMilliseconds` ends at a guest callback, not physical
presentation. End-to-end host-to-Phoc identity intentionally remains unavailable.

## Inspect existing evidence

```sh
python3 -B scripts/phosh-interaction-acceptance.py inspect \
  /tmp/pinecone-nine-acceptance-ui-metrics.json \
  --output-dir /tmp/owner6-nine-diagnostic
python3 -B scripts/phosh-interaction-acceptance.py inspect \
  /tmp/pinecone-remaining-baseline-profile.json \
  --provenance /tmp/owner6-input/tty-launch-provenance.json \
  --output-dir /tmp/owner6-baseline-diagnostic
```

`inspect` creates byte-identical `profile.raw.json` and `diagnostics.json` with
source SHA-256, every raw interaction, and optional launch provenance JSON/hash.
Exit 0 here means only that diagnostic schema checks passed, **never acceptance**.
The historical generation-90 52369.294125 ms sample is retained as expired at the
5000 ms window. Other legacy samples remain uncorrelated. No diagnostic sample
is silently trimmed or reclassified as a successful normal gesture.

Record the baseline's TTY helper, diagnostics/hot-PC environment, persisted dconf
state, and lack of icon-tap equivalence in its provenance file. Missing provenance
is explicitly unknown. If profile stdout includes launcher errors or non-JSON,
`inspect` exits 2; preserve that raw file and ask the parent for a dedicated JSON
capture rather than hiding the failure. Profiles alone cannot become baselines.

To compare completed acceptance manifests, add `--baseline /path/manifest.json`
to `report`. Both are independently revalidated. Run IDs must differ; exact
identity/configuration, gesture protocol, sample requirements and budgets must
match. Mismatched rootfs/kernel/app, launch method/environment, mutable state,
image state, profiling, or viewport refuses comparison. Cross-image performance
experiments require a separately designed controlled comparison, not an override
in this acceptance tool. Outliers are retained; nearest-rank P50/P95 and maximum
are reported per cohort alongside attempted, attested-pass, and valid counts.

## Tests

```sh
python3 -B scripts/test-phosh-responsiveness-acceptance.py
python3 -B scripts/test-profile-phosh-responsiveness.py
python3 -B scripts/test-responsiveness-analysis.py
```

Tests use independent temporary directories. Synthetic passes establish validator
behavior only, not UI responsiveness. Coverage includes the unrelated 52-second
frame, no/incomplete metrics, fallback/crashes, reset, clocks, outliers, insufficient
samples, cold/warm separation, schema additions, large identities, image/config
and launch-provenance mismatches, full-travel unlock, optional short unlock,
accessibility exclusion, strict JSON, artifact preservation, and no overwrite.

## Owner 6 local validation, October 26

Changed repository paths are this document,
`scripts/phosh-interaction-acceptance.py`,
`scripts/test-phosh-responsiveness-acceptance.py`,
`scripts/profile-pinecone-phosh.sh`, and
`scripts/test-profile-phosh-responsiveness.py`. No runtime/guest edits,
build/install, or Simulator actions were performed. The shell compatibility suite
uses a fake `xcrun` in a dedicated temporary directory and real `jq`; it never
calls the actual Simulator tool.

- `python3 -B scripts/test-phosh-responsiveness-acceptance.py -v`: 33 tests pass;
  output `/tmp/pinecone-owner6-acceptance-tests.log`.
- `python3 -B scripts/test-responsiveness-analysis.py`: 3 tests pass;
  output `/tmp/pinecone-owner6-analysis-compatibility-tests.log`.
- `python3 -B scripts/test-profile-phosh-responsiveness.py -v`: 8 tests pass;
  output `/tmp/pinecone-owner6-profiler-compatibility-tests.log`.
- `bash -n scripts/profile-pinecone-phosh.sh`: passes.
- `inspect` of the nine-agent UI profile preserves 11 raw samples: one expired
  (generation 90, 52369.294125 ms), ten uncorrelated. Source SHA-256:
  `f15f64ab005384328e756459bda43775fecf097e38796f0579d9f77d0b527315`.
- `inspect` of the remaining-work baseline preserves two raw samples: one expired
  at the declared 5000 ms window, one uncorrelated. Source SHA-256:
  `6a0c7ba69c03839592550973b9398bf8739553e14f14c7e055d2c6a6cf71931d`.
- Final diagnostic artifacts: `/tmp/pinecone-owner6-nine-diagnostics-final/` and
  `/tmp/pinecone-owner6-baseline-diagnostics-final/`, each containing
  `profile.raw.json` and `diagnostics.json`. Earlier verification outputs remain
  in `/tmp/pinecone-owner6-nine-diagnostics-20261026/` and
  `/tmp/pinecone-owner6-baseline-diagnostics-20261026/` with the same filenames.
  Parent-described launch provenance is recorded separately in
  `/tmp/pinecone-owner6-baseline-provenance.json`; exact environment and process
absence were not independently verified.

The parent integration targets Phoc 0.57.0-r7 and wlroots 0.20.2-r6. Record those
as package metadata for the actual final run, together with verified artifact
hashes; this owner did not build or verify those packages.

These diagnostic counts describe evidence classification, **not responsiveness**.
There is no completed real acceptance manifest or controlled performance result
from Owner 6. Parent must still collect semantic observations and repeated icon
launches. An earlier repository-wide whitespace check flagged the two Phoc
interactions patches; Owner 1 corrected them in its scope. This owner did not edit
them. Final repository-wide `git diff --check` passes; Owner 6's new files also
have no whitespace-check diagnostics.
