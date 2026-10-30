# Dispatch And Retention Performance Work

Status: implementation, regression checks, Release screening and candidate UI
smoke complete, 2026-10-29. Faster than the previous assembly integration;
still slower than the current established-C control. Assembly is not promoted.

## Scope

- Preserve established C superblock construction when assembly is enabled.
- Avoid duplicate assembly-program preparation/validation within one dispatch.
- Retain prepared programs under an explicit memory budget and protect hot code.
- Publish assembly execution totals at slice boundaries instead of per block.
- Build and test native boundary-service support for sustained assembly execution;
  do not enable it without production ownership and scheduling proofs.

## Measurement Contract

Use the disposable Simulator C20024A2-E866-468D-BDC6-C44E6F01E0A3 only.
Preserve the user's working Simulator app and disk. Suspend its identified vCPU
process only during clean measurements and resume it afterward.

The pre-change Release app is `/tmp/pinecone-phase7-cache-clean.app`, executable
SHA-256 `7388d149e15ccc5b0457a094f1178b00c1d06dc2f4acf4c78fa1ad9349178ef2`.
The guest seed, fingerprint, packages and kernel are unchanged from
`phase7-cache-integration-results.md`. Freeze the candidate source and executable
identity before testing. Both apps explicitly use two parallel vCPUs, assembly
enabled, older threaded C disabled, threaded memory disabled and cache diagnostics
off. Retain identical UART, interaction and performance-report settings.

Screen two alternating before/after pairs, restoring the same seed each time.
Keep builds, tests, process sampling and other VMs out of the timed runs. Each
attempt has a 600-second observer ceiling and 15-second post-readiness window.
Retain all failures. Compare wall-clock guest readiness, app CPU seconds and
sampled RSS. A separate candidate established-C run checks whether assembly is
competitive; historical C results are context, not a matched current control.

Readiness alone does not verify rendering. Check visible lock screen, tap unlock,
Home, legible Settings and return Home. These are functional checks unless an
actual input-to-semantic-completion interval is recorded. Do not substitute
instruction counts, arbitrary frame arrivals or click acknowledgement for UI
latency. Two boot pairs are a screening result, not full promotion evidence.

## Results

Candidate executable SHA-256:
`3bdb7a8249f9f1641ee9892a627a94be9c73887243cedbfc4f1268496f94d77e`.
All five attempts completed with zero Swift fallback on both vCPUs.

| Order | Build / executor | Guest readiness (s) | App CPU seconds at observation | Sampled peak RSS (MiB) |
| --- | --- | ---: | ---: | ---: |
| 1 | Before / assembly | 120.133 | 120.35 | 752.27 |
| 2 | After / assembly | 84.991 | 81.62 | 889.23 |
| 3 | Before / assembly | 123.163 | 114.79 | 736.42 |
| 4 | After / assembly | 84.836 | 79.24 | 784.03 |
| 5 | After / established C | 68.722 | 72.18 | 836.42 |

Before/after assembly means: readiness **121.648 -> 84.913 seconds**, a
**30.2% reduction**; observed app CPU **117.57 -> 80.43 seconds**, a **31.6%
reduction**. This is a repeated improvement for the integrated patch bundle,
not an isolated cache-policy or counter-batching attribution. The candidate
still takes about 23.6% longer than the single current-C control; that control
is not a full matched C cohort. No executor defaults were changed.

Sampled peak RSS is higher in both candidate assembly runs than their baseline
pairs (784-889 versus 736-752 MiB). The current-C control is 836 MiB. These
samples do not establish the cause, a leak, or a memory improvement; a footprint
attribution and the full interaction/promotion gates remain necessary. Do not
promote based solely on the CPU/time improvement. Detailed preparation counters
were compiled out, so there is no new Phosh re-preparation count in this screen.

After candidate run 2, visually verified lock screen, ordinary tap unlock,
Home, legible Settings Wired/VPN/Proxy panel, and return Home. Settings had a
long splash/startup delay; no input-to-render latency distribution was measured
and app responsiveness is not declared solved. Existing elogind/cgroup startup
errors remain in the captured UART log. Their presence alone does not prove
they caused the delay. No guest image changes were made during this work.

Raw identities, per-attempt reports, CPU/RSS samples, logs, screenshots, source
patch/hashes and test logs are retained locally under
`experiments/phase3/results/phase7-dispatch-retention/`. Each build was installed
only on the disposable device; its app/data were removed between builds to
maintain disk headroom. The final candidate remains installed there, stopped.
The user's original process was resumed and verified running; its app/disk and
executor selection were not replaced.

## Implementation And Verification

The production candidate preserves C superblock construction before assembly
selection. Selection now prepares once, after pre-execution checkpoints, carrying
epochs captured before code selection into the assembly entry. The borrowed
program crosses callback-free owner code only; the existing runtime pins it
before any memory helper can invalidate its cache entry. Epoch-token addresses
are hoisted out of the loop. Owner-local execution totals are atomically
published at slice return, not updated with per-block atomic read-modify-write.

Prepared programs belong to decoded entries under a 4 MiB payload budget per
vCPU, with up to 3 MiB protected after repeated lookup. Queue operations are
O(1); admission retires at most 64 programs. The budget excludes fixed metadata,
allocator overhead and retired active pins. Preparation can transiently add one
bounded block program. In synthetic tests, a cyclic 257-program workload prepares
257 times across 771 lookups, and a 9,815-program scan preserves a protected hot
program. These results do not measure Phosh's new preparation count.

Verification: 674 Swift tests; native runtime optimized and UBSan; focused
dispatcher and cache matrices optimized and UBSan; 61 benchmark harness tests.
The timer fixture still requires exact retirement/checkpoint deadlines but now
allows the restored C superblock path to execute some eligible instructions.
The new Swift regression independently verifies superblock dispatch with
assembly enabled and compares architectural state across varying budgets.

The additive `Assembly/service_chain.c` runtime is default-off and has no VM
caller. Its optimized, UBSan, default-off and assembly-disabled checks pass.
The initial helper test failed because the fixture omitted a device-access
callback; the fixture now supplies it and separately tests denied access.
This runtime establishes bounded visits, proof validation, pinning and native
service accounting. It still returns through the assembly veneer per visit;
resident-register multi-block execution and production cache enrollment are
NOT implemented by this patch and are not included in performance claims.

An early Swift build overlapped in-progress agent edits and failed to compile;
it is not regression evidence. A subsequent new test initially passed a physical
address to a virtual-address write helper; that fixture error was fixed before
the successful full suite. Final verification uses the coherent frozen sources.
