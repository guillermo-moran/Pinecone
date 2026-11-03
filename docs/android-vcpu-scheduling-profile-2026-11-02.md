# Android vCPU scheduling and checkpoint profile

Read-only `sample 40288 5` capture at 2026-11-02 09:37:49 CST from the running
iOS Simulator app (`EA4C15A7-F725-4321-82FD-70E9F32A7645`). Launch time was
09:21:54. No app restart, installation, CPU-count change or runtime-setting
change was performed. Physical footprint was approximately 2.2 GiB.

## Findings

All four guest vCPUs were executing. Workers 1–3 have dedicated threads; the
primary vCPU appears across cooperative pool threads as expected. There is no
evidence in this capture for adding vCPUs or changing work distribution.

The table counts inclusive stack samples, aggregated by path. A sample can
appear in several columns; columns must not be added together or interpreted
as CPU time. Thread waiting is included in `sample` observations.

| Path | Native fast-memory chain wrapper | Swift checkpoint | Swift translation sync | IRQ pending peek | Mutex wait |
| --- | ---: | ---: | ---: | ---: | ---: |
| vCPU 1 | 3,066 | 201 | 68 | 151 | 106 |
| vCPU 2 | 3,143 | 171 | 42 | 120 | 67 |
| vCPU 3 | 3,210 | 239 | 55 | 158 | 93 |
| Primary cooperative threads combined | 3,063 | 177 | 42 | 123 | 81 |

Checkpoint samples are about 6.3% of the native-wrapper samples in this capture.
Their main contention path is
`NativeChainCheckpointContext.checkpoint → InterruptController.peekPending →
NSRecursiveLock → pthread mutex wait`. Swift shared-translation synchronization
is another visible checkpoint cost. The native timer-advance function is much
smaller in the flat profile; widening its allowance or removing service is not
justified by these observations.

Selected collapsed top-of-stack samples:

| Function | Samples |
| --- | ---: |
| Native C instruction executor | 2,917 |
| Native checkpointed chain wrapper | 1,505 |
| Code-current validation | 719 |
| Instruction translation | 685 |
| Decoder | 504 |
| Block-cache lookup/decode | 504 |
| Mutex wait | 346 |
| Assembly program creation | 76 |
| Native timer advance | 67 |

Assembly handlers and `ag_run_memory` also appear in the capture. This is a
mixed execution workload, not a pure assembly throughput benchmark.
The cached performance JSON was last written at 09:31:08 and reported zeroed
assembly-cache fields, so it is not used as current coverage evidence.

## Integrated follow-through

`SimpleInterruptController.pendingLine` and `globalPendingLine` run while the
controller's recursive lock is held. They previously called public `isEnabled`
methods, which acquired the same lock again for each candidate interrupt.
The Swift integration now replaces these internal calls with private helpers
that require the lock already be held, keeping public methods locked. This removes recursive
lock/unlock work without changing checkpoint cadence, pending-interrupt
semantics, wakeups, target routing, active/pending handling or synchronization.
No `ARM64VizNative.c` change is needed for that improvement. No isolated timing
or Android responsiveness gain is claimed for this lock simplification.

A later lock-free "possibly pending" summary could avoid the contended outer
lock on negative queries, but it needs release/acquire publication after every
raise/clear/enable/acknowledge/EOI/reset/routing mutation. False negatives must
be impossible. Do not replace the authoritative locked acknowledgement path
with a cached line number or skip checks merely because one earlier query was
empty. This is a recommendation, not an implemented feature.

Native code already preserves exact checkpoint retirement budgets and services
time/IRQ state. Its hot-PC profiling guards remain intact. This task adds no
speculative native scheduling optimization and claims no Android speedup.
The raw temporary sample was removed after recording these findings.
