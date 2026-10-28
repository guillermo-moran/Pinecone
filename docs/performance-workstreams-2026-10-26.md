# Four Native Performance Workstreams

Status: four workstreams integrated and reviewed; final performance acceptance
failed. The source is retained for review, not approved as a performance rollout.

This work follows `interpreter-simulator-performance-2026-10-26.md`. The goal is
lower guest execution cost and faster actual application/interaction response,
not a higher standalone arithmetic benchmark score.

## Ownership

| Owner | Assignment | Production write scope |
| --- | --- | --- |
| Ramanujan | Paired LDP/STP memory translation/access | `ARM64VizGuestMemory.c`, `ARM64VizGuestMemoryInternal.h` |
| Tesla | Redundant validation in cached chains/superblocks | `ARM64VizNative.c` |
| Bohr | Broader proven musttail instruction coverage | `ARM64VizThreadedPrototype.c`, its header |
| Godel | Bounded auxiliary-program cache and churn diagnostics | `ARM64VizBlockCache.c` |
| Parent | Review, shared APIs, integration, serial measurements, Simulator smoke | Shared public header, Swift integration as needed, integrated regression/measurement tooling |

Agents own uniquely named standalone tests/reports. They must propose cross-owner
API changes before using them. In particular, parent wires any new prototype
memory-context API only after the validation owner's Native.c work is reviewed.
No worker controls the Simulator, rebuilds guest images, changes vCPU/RAM policy,
enables Swift fallback, or modifies guardrails.

## Frozen Baseline

Current dirty-tree native sources and Release app were copied before dispatch:

`/tmp/pinecone-four-performance-baseline.l5K1sW`

The app copy uses APFS cloning. This is not git HEAD and does not discard any
previous work. SHA-256 identities:

| File | SHA-256 |
| --- | --- |
| Native.c | `d4409d07012afe1563c3137c2a29d0d57df7d48bd3be5a575914134258a2617c` |
| GuestMemory.c | `cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f` |
| BlockCache.c | `c8d181bad0da1bb89f39ab77d9f8cb988d9c97fad65222210d3acc995b8e7122` |
| ThreadedPrototype.c | `cfe4fcd11bef6c7b67d54edd3c3d30b3b936a29d4c883315cd382c6a91623a74` |
| Pinecone executable | `9344a25f0fe36eaa0fb69f90d8860e847c64afad181a1adaa76629bc23d2533a` |

## Review Gates

1. Review only each owner's delta from this frozen baseline; preserve unrelated
   dirty work. Require a concrete invariant argument for every removed check.
2. Run differential correctness and UBSan. Cover page crossings/permissions,
   exact fault and retirement state, SP/XZR/flags, code writes, remaps/TLBI,
   cross-vCPU visibility, callbacks, cache lifetimes, timers and interrupts as
   applicable. A stalled or unavailable sanitizer is not a pass.
3. Run serial frozen-baseline/candidate benchmarks. Concurrent-agent timings
   cannot justify acceptance. Keep negative controls and regressions in reports.
4. Rebuild the integrated core and run existing regressions, including actual
   cached-chain execution, rather than testing only isolated helper functions.
5. Parent installs only on Pinecone Graphics Regression Simulator. Verify shell,
   rendered Phosh, full-height unlock, Settings launch/content and zero Swift
   fallback. Do not conflate accessibility smoke with ordinary swipe latency.
6. Compare the preserved app against the candidate with identical restored guest
   disk state and fixed settings. Keep raw results, failures, ranges and host
   interference notes. No UI-speedup claim based solely on instruction count.

## Progress

- [x] Preserve exact pre-dispatch sources and app.
- [x] Dispatch four non-overlapping workstreams.
- [x] Review implementation and API proposals.
- [x] Review completed diffs and correctness evidence.
- [x] Serial microbenchmarks; withhold optional scalar-memory execution from defaults.
- [x] Integrated tests and Simulator boot checks (653 Swift tests; final native UBSan pass).
- [ ] Final candidate unlock/application acceptance: launcher was not observed after the final gestures; Settings unverified.
- [x] Publish implementation, rejected candidates, and measured results.
- [ ] Demonstrate an end-to-end performance improvement; final same-disk candidate runs were slower than the fresh control.

Integration findings and acceptance results are maintained in
`interpreter-four-agent-integration-2026-10-26.md`. In particular, not every
candidate is a performance win: the one-access threaded-memory experiment remains
disabled and cache replacement has measurable noncollision overhead.

Dispatch identifiers for coordination:

- Ramanujan: `01a17adf-ecf9-76e2-9c54-c037f270bae0`
- Tesla: `01a17b33-8282-7a91-95c3-e2f200a759e1`
- Bohr: `01a17adf-eb1a-7733-bbe8-34875d03c7f5`
- Godel: `01a17b33-8389-78e1-9e62-1769fa6c32ed`
