# Phase 7: Native ALU Cost And Rejected Guard Experiment

Date: 2026-10-29. The accepted production change is limited to mapped C
shifted-register ADD/SUB instructions that do not set flags. Assembly executor
selection, execution budgets, memory guards, guest packages and images are
unchanged. This improves a measured instruction workload, not a demonstrated
Phosh interaction-latency distribution or the assembly promotion gate.

## Accepted Change

`op_add_sub_shifted_register` previously called `add_with_carry_nzcv` even when
the instruction discarded NZCV. The no-flags path now uses unsigned addition
or subtraction followed by the existing width mask. Shift handling, XZR,
32-bit zero extension, all PSTATE bits, PC advancement and retirement are
preserved. Flag-setting operations retain their original helper.

This handler is used by established C execution and by the C blocks/semantic
dispatch infrastructure retained when the assembly prototype is enabled. It
does not introduce Swift fallback or enlarge an execution slice.

The frozen pre-edit C source has SHA-256
`3b0f7a363110cd6c7d0b7a432a5be0a23014517371fd081874f0c73c70a48c99`.
Final C source SHA-256 is
`24934a3736bd4546bcb1dd43adab0307d42f77b86163541646b98e43f9bbbe68`.
The source diff contains only this handler change. All pre-existing dirty
changes are retained; neither hash describes a clean Git revision.

## Measurements

`scripts/run-native-alu-fastpath-regressions.sh --benchmark /absolute/before.c`
builds the same harness against frozen before/current C, with the same live
headers, cache and memory implementations. Both binaries use `-O3`; assembly
and the older threaded prototype are disabled in this C-only microbenchmark.
Six alternating before/after rounds cover 32 cases each, including unchanged
flag-setting, extended-register and carry controls: 384 samples total.
Each sample executes 1,280,000 instructions in 64-instruction mapped calls.
Full architectural comparisons and exact accounting checks are outside timing.
Timing includes entry/exit, dispatch, PC reset and result accumulation.

Median thread CPU nanoseconds per instruction, final shifted-only candidate:

| No-flags operation | Before | After | Change |
| --- | ---: | ---: | ---: |
| 32-bit shifted ADD | 7.322 | 3.657 | -50.1% |
| 32-bit shifted SUB | 7.363 | 3.615 | -50.9% |
| 64-bit shifted ADD | 7.320 | 3.638 | -50.3% |
| 64-bit shifted SUB | 7.323 | 3.643 | -50.2% |

Flag-setting shifted controls range from -0.9% to +0.4%; unchanged extended
and carry controls range from -2.2% to +3.3%. These small movements are retained,
not declared a universal no-regression result. The user's existing Simulator
remained running; no other build, test or sample ran during the timed cohort.
The host was not isolated. These are synthetic CPU-cost results, not boot,
Settings-launch, touch-to-frame or physical-device performance measurements.

Raw artifacts are retained locally in
`experiments/phase3/results/phase7-guard-coalescing/`, notably
`alu-shifted-benchmark.log`, `alu-summary.json` and `final-sources.sha256`.
A short sample of the existing prototype is also retained, but its uncontrolled
interactive workload is not used to attribute a particular UI delay.

## Rejected Changes

1. **Duplicate shared-code guard coalescing:** checking identical token addresses
   and expected epochs permits retaining just the memory-view acquire check.
   Correctness tests passed, but two same-binary screens found approximately
   24% slower single-instruction register calls and 9% slower 16-instruction
   register loops, despite roughly 3% faster longer load/store loops. Production
   `ag_run_memory` retains its original uncoalesced behavior. The internal
   `ag_run_memory_coalesced` entry and benchmark remain experimental only, with
   no VM selection path. Do not infer a proven branch-prediction cause.
2. **Extended-register and carry flag avoidance:** the first bundle worsened
   several controls by approximately 3-15% at `-O3`. Both handlers were restored
   exactly to the frozen baseline. Their regression and benchmark coverage is
   retained. Compiler elimination/layout is a hypothesis, not measured cause.

The historical preparation benchmark now compares inline uncoalesced entry
against outline uncoalesced entry, keeping preparation attribution independent
of the guard experiment. Same-binary guard measurements use identical inline
preparation and assembly handler addresses, with alias and nonalias controls;
they include result-buffer stores and are not pure atomic-load cost measures.

## Verification

- 3,485,568 mapped/generic arithmetic cases pass for both baseline and final
  candidate; raw execution is an additional reference for shifted forms.
- The final arithmetic matrix passes UBSan. It exercises edge operands,
  widths, shifts/extensions, carry inputs, SP/XZR, aliases, NZCV and budgets.
- All 674 Swift tests pass.
- Focused dispatcher tests pass optimized and UBSan, including stale selection,
  exact timer budgets, helper pin/retirement, independent guard tokens and a
  peer code publication after a RAM signal followed by a register-only loop.
- Final native runtime matrices pass optimized and UBSan, including memory
  observation, precise faults, two-vCPU code/TLBI publication, timer/checkpoint
  deadlines, TLBI journal overflow and preserved native semantic accelerators.
- Final Release Simulator build succeeds. Executable SHA-256:
  `3a3d57a1874d5db4f05c5f353132f3b92ed21e7f09cee05112d40d429bdf32cd`.
- Installed only on disposable Simulator
  `C20024A2-E866-468D-BDC6-C44E6F01E0A3`. Assembly is enabled on two parallel
  vCPUs, older threaded paths disabled, detailed cache diagnostics disabled.
  Shell and the rendered Phosh lock screen are verified, with zero Swift
  fallback on both vCPUs. Guest readiness was observed at 75.655 seconds in
  this single smoke run; existing disposable disk state was retained and the
  user's other VM was active. This is not a matched before/after boot result.
- **Unlock/Settings/return-Home smoke remains incomplete.** Native Simulator
  menus and app controls respond, but guest coordinate clicks fail at the host
  input layer with `windowNotFoundAtPosition`. Reconnecting, raising and resizing
  the test window did not resolve it. No failed host click is counted as guest
  input latency or successful unlock. The user was asked to unlock the Mac.
- Saved the metrics, UART and lock-screen screenshot, then stopped the disposable
  VM through its native Stop control and verified quiescence. The user's original
  process remained running throughout; its app, executor selection and disk
  were not replaced. No physical device was modified or tested.

## Follow-Up Simulator Smoke

After the user made the Mac available, coordinate input worked on the same
disposable Simulator. The installed executable still matched the SHA-256 above.
The VM was already running and unlocked when inspected. Home and the existing
Settings window responded to taps. The guest reboot control only echoed a
`reboot` command into the foreground session, so the host Reset VM control was
used for the fresh-boot check instead.

The reset reached persistent root, automatically started Phosh, and rendered
the lock screen. The first unlock tap did not visibly dismiss it; a second tap
did. Settings then showed its loading screen before rendering Network settings,
and the Home button returned to the launcher. The visible native/fallback badge
remained at zero fallback throughout. This completes the previously blocked
functional sequence, but does not establish reliable single-tap latency, a
cold-launch improvement, or a performance promotion result. Settings startup
remained visibly slow; its header was not visible in the final sampled frame,
so this is not a comprehensive text/layout correctness sign-off. No guest-event
identity trace or controlled timing cohort was collected. The disposable VM
was left running at Home; the user's other Simulator and physical device were
not modified.
