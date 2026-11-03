# Bounded chain page-proof deduplication

Bounded chaining already stays in assembly across block edges and amortizes
native service across its initial timer/checkpoint allowance. This change
reduces redundant page-generation reads at those edges. It does not enable
assembly or chaining by default or change generic every-visit execution.

During preparation, members with the same owner-local page-token address and
expected value share one local load per edge. The same rule applies separately
to shared atomic page tokens, retaining an acquire load. Every distinct page
certificate and every member serial remains checked. Local/shared/serial roles
are never merged; equal values at different addresses are never merged.
Inconsistent expectations are not deduplicated and cannot pass admission.
Global epoch and per-instruction validation remain unchanged. No assembly ABI,
operation layout, lifetime, publication, timer or IRQ contract changes.

The optimization acts on bounded private proof arrays only. Original member
metadata and full C validation are unchanged. It does not assume that unchanged
global code epochs imply unchanged page generations. This matters because peers
may publish page generations before their global code epoch.

## Measurement

Run `PINECONE_BENCHMARK_SHARED_PAGE=1 sh scripts/run-assembly-chain-proof-benchmark.sh`.
The new isolated benchmark executes an identical self-loop while retaining
1, 2, 4 or 8 graph members. For same-page comparisons it alternates deduplicated
proofs and redundant same-page proof loads in the same executable. Its private
entry wrapper copies the proof array for both modes, restores redundant page
fields for the control, and leaves all serial/global checks intact. Preparation
is outside timing. Each sample runs 256 slices of 4,096 guest instructions;
callback counts, exact retirements, visits, PC, register results and accounted
timer steps are asserted. Timing uses host thread CPU time.

Seven sample medians after the first round on the local Apple Silicon Mac:

| Instructions/block, 8 members sharing page tokens | Redundant ns/instruction | Deduplicated | Time reduction |
| --- | ---: | ---: | ---: |
| 2 | 6.2104 | 5.8197 | 6.3% |
| 4 | 3.9722 | 3.9046 | 1.7% |
| 8 | 2.9099 | 2.7930 | 4.0% |
| 16 | 2.3673 | 2.2836 | 3.5% |

The 1-member control was effectively neutral (-0.3% to +0.6%). Host load and
thermals were uncontrolled; these synthetic results do not establish Android
boot or UI speed. Graphs on separate pages have no redundant page tokens to
remove. `AG_SERVICE_DEDUP_PAGE_PROOFS=0` disables preparation deduplication for
separate-build controls; the benchmark runner accepts this through
`PINECONE_BENCHMARK_DEDUP_PAGE_PROOFS=0`.

## Correctness

The benchmark also rejects inconsistent expected values for aliased local and
shared tokens. It injects local-page, shared-page and individual member-serial
changes after the final C validation, before assembly entry, and requires zero
retirements and proof rejection. This includes later, unexecuted members whose
page certificate is deduplicated. Run both with and without
`PINECONE_BENCHMARK_SHARED_PAGE=1` to cover shared and independent tokens.

Passed bounded-service and production-chain regressions in optimized and UBSan
builds; the new shared-page/independent-page fixture also passed UBSan. Tests and
timing use the custom emulator runtime; no simulator installation was performed.
