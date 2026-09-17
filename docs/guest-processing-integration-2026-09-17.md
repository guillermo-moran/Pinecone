# Guest processing integration, 2026-09-17

## Scope

Eight audit actions were implemented, with six delegated workers and host-side
integration for the first two high-priority issues. Existing worktree changes
were preserved. Tests use the dedicated Pinecone Graphics Regression Simulator,
not a connected phone. Native-only execution and two vCPUs remain enabled.

| Priority | Action | Implementation |
| --- | --- | --- |
| High | Remove diagnostic-dependent scheduling | Phoc emits bounded, nonprinting app-presentation control records independently of optional trace records and their budget. The host preserves UART ordering, filters control records from terminal output, and expires abandoned launch boosts. |
| High | Preserve touch response scheduling | First-frame telemetry no longer clears the scheduling lifecycle or newer pending delivery. A bounded animation-settle policy keeps priority through successive frames; both vCPUs share continuous-execution pacing, with interruptible waits. |
| High | Establish Cairo/Pixman ownership | Patched Cairo acquires private CPU pointers within balanced scopes. Public exports and retained aliases remain permanent hazards. A rebuilt bridge tracks end-of-write generations and preserves fences. The rootfs validates the compiled Cairo overlay's provenance. |
| Normal | Remove hot SIMD double dispatch | DUP and single-structure lane/replicate operations use shared native helpers directly in the block dispatcher. Decode and fault semantics remain shared with the generic native path. |
| Normal | Scope TLB invalidation | VA/ASID/global metadata, indexed invalidation epochs, and an SMP journal retain unaffected translations. Decoded mappings are lazily revalidated without scanning all RAM or invalidating physical code. Unknown forms and journal overflow retain conservative translation flushing. |
| Normal | Avoid foreground OSK startup priority | Squeekboard starts at normal nice=0 instead of inheriting Phosh's nice=-5. It is not permanently demoted below ordinary applications. Priority-setting failure warns without removing the keyboard. |
| Normal | Measure and improve loader lookup | Optional build-time statistics measure index construction and lookup probes. Preserving the full hash reduces collisions; the eager index remains. Production musl r8 excludes statistics. |
| Normal | Fix Settings prewarm activation race | Explicit lifecycle state, cancellable hide timer, reference cleanup, and shutdown handling prevent a late prewarm timer from hiding an interactive window. Prewarm remains off by default. |

## Regression gates

- Full Swift suite: 529 tests pass, including the existing global-ASID retention
  test and warmed decoded-block/superblock VA-remap coverage.
- Native SIMD: 6,058 checks; 15,872 new and 5,536 existing ARM64 hardware
  differential executions without mismatches. UBSan passed. The separate ASan
  invocation stalled during initialization and was stopped, not counted as a pass.
- Metal: 3,528 Pixman differential cases pass in each of direct and simulator-copy modes.
- Cairo: aarch64 build, ownership hooks, escaping pointers, mapping, flush,
  finish, stock-pixel comparison, and stale-manifest rejection pass.
- Phoc control: tracing disabled/exhausted, dropped frames, and invalid IDs pass.
- musl: 36 instrumented loader cases plus 12 cases against the signed production
  package pass; symbol versions, binding, COPY relocations, TLS, and runtime
  loading remain covered.
- Settings prewarm: 14 lifecycle tests pass normally and with ASan/UBSan.
- OSK: mocked failure handling and unrestricted process-priority checks pass.
- Rebuilt pristine rootfs passes read-only e2fsck.

## Integration

Bundled guest artifacts: Phoc 0.57.0-r5, Settings 50.4-r2, musl 1.2.6-r8,
Cairo 1.18.4 ownership overlay, rebuilt Pixman bridge and session launcher.
The existing patched Pixman library ABI remains compatible.

Initial tracing-disabled smoke passed boot, Phosh readiness, unlock, Settings
presentation, Appearance navigation, window close, and terminal command execution.
Both vCPUs reported zero fallback instructions. The Network panel reports missing
NetworkManager; the guest uses static networking and this pass does not add it.

The final-binary pristine boot also reached Phosh and Settings with zero fallback
instructions on both vCPUs. A full swipe unlocked it; Settings back navigation,
Appearance rendering, window close, terminal `echo FINAL_SMOKE_OK`, and returning
to the unlocked home screen with the host keyboard hidden all worked. No
unsupported-instruction, kernel-panic, runner-failure, or ext4-error
markers appeared in the captured UART/runtime logs.

An early drag during startup returned to the lock screen; a later full swipe
succeeded. This is a remaining startup/gesture-latency limitation, not a claim
that all responsiveness issues have been eliminated. The final run reached the
shell at 2.71 seconds and Phosh readiness at 63.72 seconds. Settings launch
overlapped manual unlocking, so its elapsed time is not a clean launch benchmark.

Local evidence: `/tmp/pinecone-eight-swift-final.log`,
`/tmp/pinecone-eight-ios-verified.log`, `/tmp/pinecone-eight-rootfs.log`,
`/tmp/pinecone-eight-smoke-initial.json`, and
`/tmp/pinecone-eight-smoke-final.json`. The final app is installed in Simulator
`541E22EE-C52B-4478-A041-56FEDC23ACFF`.
The final manual run used optional interaction tracing; the earlier integrated
run verified the essential presentation protocol with tracing disabled.

## Measurement limits

Instruction microbenchmarks and loader probe-count improvements are not Phosh
speedup measurements. Early integration timings overlapped build/benchmark work.
The touch scheduling policy is bounded prioritization, not proof that an arbitrary
frame is causally the final response to an input. Escaped CPU pointers and
unsupported graphics operations deliberately retain correctness fallbacks in
Pixman, not the Swift CPU interpreter.
