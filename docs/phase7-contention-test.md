# Deterministic native spinlock contention test

## Scope

Changed only `testNativeExclusiveSpinlockIsCorrectUnderParallelContention`
and its nested helper in `Tests/ARM64VizCoreTests/ARM64VizCoreTests.swift`.
Existing dirty changes, including page permissions and PSTATE setup, were preserved.
No runtime edits, full test suites, benchmarks, simulator, or device work.

## Interleaving

The test now executes ten native instructions in fixed, bounded batches:

1. Both VMs execute LDAXR against the unlocked word and observe zero.
2. The first VM executes CBNZ, MOV, and STXR, acquiring the lock.
3. The second VM executes CBNZ, MOV, and STXR with its stale reservation.
   Its STXR must fail with status one due to the first VM's real store.
4. The second VM executes the retry branch and LDAXR, observing the held lock.

Each batch asserts its instruction count, stop reason, PC, and native single-step
counter delta. Basic blocks are disabled only during each batch and restored
before parallel stress. Before starting workers, the test asserts exactly one
successful exclusive write, one conflict, one nonzero read, and a zero counter.
No guest state or statistics are fabricated to produce these observations.

The same VMs then resume on parallel dispatch workers with 10,000 iterations each
still remaining. All original final assertions remain, including exactly 20,000
successful acquisitions and counter increments, positive conflict/nonzero-read
counts, released lock, both halts, and no Swift fallback. A timeout still fails
the test but now returns before inspecting state that workers might still mutate.

## Validation

Host macOS arm64 debug build, 2026-10-29. Separate scratch build avoids contention
with the parent's assembly profiling build:

```sh
swift test --scratch-path /tmp/arm64viz-contention-test \
  --filter ARM64VizCoreTests.ARM64VizCoreTests/testNativeExclusiveSpinlockIsCorrectUnderParallelContention
```

Passed once. A subsequent SwiftPM `--skip-build` attempt failed before test
execution because its manifest compilation could not write the sandboxed user
Clang module cache. Used the freshly built test bundle directly instead:

```sh
xcrun xctest \
  -XCTest ARM64VizCoreTests.ARM64VizCoreTests/testNativeExclusiveSpinlockIsCorrectUnderParallelContention \
  /tmp/arm64viz-contention-test/arm64-apple-macosx/debug/arm64vizPackageTests.xctest
```

Passed once, then passed 30 consecutive repetitions in separate processes:
32 successful focused executions total, zero test failures.
