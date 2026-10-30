# Phase 6: First Measured Hot-Form Expansion

Status: **in progress, not promoted**. This batch expands the isolated assembly
executor. Pinecone still uses the established C executor, two vCPUs, and the
existing guest image. No Swift fallback, graphics, scheduler or memory-policy
change is part of this batch. Phase 5's completed offline gate remains intact.

## Workload Evidence

The installed Release app was restarted on the dedicated Pinecone Graphics
Regression Simulator, retaining its persistent root. Both threaded-prototype
flags were explicitly zero. Hot-PC sampling and detailed diagnostics were on.
Observed shell, Phosh lock screen, tap unlock, Home, Settings and Firefox rendering.
Firefox displayed its existing Example Domain tab; this was not a new network
or browser-input acceptance test. The visible fallback counter remained zero.
After collection, the VM was stopped and relaunched with profiling disabled
and the same established two-vCPU C configuration. Shell, lock screen and tap
unlock to Home were observed again with zero fallback. No app reinstall or disk
replacement was performed.

Raw captures and classification are under
`experiments/phase3/results/phase6-profile/` (ignored local artifacts):

- `pinecone-phase6-phosh-readiness.json`: readiness capture.
- `pinecone-phase6-settings.json`: snapshot after Settings became visible.
- `pinecone-phase6-firefox-attempt.json`: intermediate launch snapshot.
- `pinecone-phase6-firefox-presented.json`: snapshot after Firefox rendered.
- `coverage.json`: reproducible classification using the actual native decoder
  and assembly preparation path, with capture-file and executable hashes.

These are **attribution samples, not a clean timing cohort**. The profiler samples
every 256 eligible block-dispatch entries, retains approximate Space-Saving
heavy hitters, and stores only the first four words of each retained block.
Only 32 entries per CPU are exported. Counters are not retired-instruction
frequencies or cycle costs. The primary histogram resets at Phosh workload
start and the first application-launch marker; the secondary does not reset
with it. The Firefox snapshot includes earlier application work. Compilation
during the later launch also makes launch timings unsuitable for comparison.
Settings' one-shot application marker must not be relabeled as Firefox latency.

Observed prefixes included repeated shifted-add loops, shifted/inverted logical
operations, and logical masks. Across the three retained snapshots, 23 distinct
encodings become eligible in this batch: two shifted adds, five shifted/inverted
logical forms, and 16 logical-immediate words. This is **not** a dynamic coverage
percentage. It motivates a bounded expansion, not a claim that these operations
dominate total application CPU time.

After this expansion, the Firefox-observed snapshots still have 13 load/store
pair first-misses across the two CPUs, plus signed-immediate loads, register
branches, register-offset memory and conditional operations. Those are concrete
next coverage candidates. The small prefix sample does not justify an arbitrary
NEON/FP rewrite.

## Implementation

- Decode-select LSL/LSR/ASR ADD/SUB handlers for both widths, with and without flags.
- Decode-select LSL/LSR/ASR/ROR logical handlers, including BIC/ORN/EON/BICS.
- Predecoded logical-immediate masks with correct SP destination versus XZR
  source and ANDS/TST destination behavior.
- Retain existing unshifted handlers for zero-shift operands.
- Shift preparation branches into the existing ALU/flag/retirement body. No new
  C calls, recursive frames, guest-address host branches or shared-state cache.
- Preserve per-instruction guard checks, exact retirement, service allowances,
  and full CPU-state publication. Memory/FP/atomic semantics are untouched.

Operations remain 48 bytes. The assembly object's `__TEXT` grows from 15,348 to
24,516 bytes (9,168 additional bytes); this is an instruction-cache tradeoff,
not free coverage. The existing emission check still finds exactly the two
terminal memory-helper calls, no indirect calls and no reserved x18 use.

## Correctness

Both optimized and UBSan builds pass:

- 181,766 register/boundary comparisons, including all valid shift amounts,
  both widths, flag/inversion variants and register aliases.
- Exhaustive logical-immediate encoding-space classification/execution checks;
  unallocated words exit without retiring or changing CPU state.
- Exact independent SP-alignment expectation for `and sp, x9, #0xffffffffffffff80`.
  Host Clang assembly confirms encoding `0x9279e13f`.
- Existing scalar-memory, permissions, observers, callbacks, 100,000 concurrent
  RAM publications and all tested TLBI-scope regressions.
- Existing 72,753 chain/lifetime/event cases and 257 memory-chain budget cases.
- 5,200 new hot-form cross-block comparisons covering entry offsets, budgets,
  service deadlines, block limits, and stale-page rejection.
- Disabled-build, ABI preservation, bounded-stack and unwind metadata checks.

Logs and emitted-code/unwind inspections are retained in
`experiments/phase3/results/phase6-validation/`, as well as the working logs
`/tmp/pinecone-phase6-test.log` and `/tmp/pinecone-phase6-ubsan.log`.
UBSan checks C, not assembly memory accesses. No new ASan, TSan, arm64e or
physical-device validation is claimed.

## Isolated Performance

Accepted identical-binary cohorts: `phase6-hot-2` and `phase6-hot-repeat` under
`experiments/phase3/results/`. Together they contain 960 samples: two loops,
four windows, four eligible modes and 15 interleaved rounds per cohort.
Every sample checks final CPU state against C outside timing. Pinecone was
temporarily paused by verified process identity and resumed automatically.
The existing pre/post host-load gate passed; it is not continuous load monitoring.
The optimized binary SHA-256 is
`a56305af662e91817c6df2e39e22900e549292a17c091fbeb8bb2237ea7c8ade`;
all four accepted hot/register/chain reports record that same binary.

Median milliseconds per 1,048,576 instructions, first accepted cohort:

| Synthetic loop | Window | Direct C core | Guarded assembly | Assembly/C |
| --- | ---: | ---: | ---: | ---: |
| Shifted/inverted | 4 | 13.037 | 3.946 | 0.303 |
| Shifted/inverted | 64 | 10.438 | 2.372 | 0.227 |
| Shifted/inverted | 256 | 10.240 | 2.224 | 0.217 |
| Shifted/inverted | 4096 | 10.227 | 2.256 | 0.221 |
| Logical masks | 4 | 11.801 | 3.623 | 0.307 |
| Logical masks | 64 | 9.370 | 2.375 | 0.253 |
| Logical masks | 256 | 9.175 | 2.095 | 0.228 |
| Logical masks | 4096 | 8.962 | 2.060 | 0.230 |

The repeat's ratios range from 0.218 to 0.314. These loops show roughly 69-78%
less wall time than the direct C core, **not a 69-78% Phosh improvement**. They
exclude live translation, devices, cache misses, scheduling and full application
control flow. Mode 3's guard branch behavior can outperform mode 2's null-guard
branches in these fixtures; that does not make acquire loads free.

The first attempted cohort, `phase6-hot-1`, is retained but **rejected**: the
older threaded C prototype exited unsupported on logical immediates. The final
hot suite excludes that ineligible mode explicitly. It never counts partial
execution as successful work and never adds a hidden fallback.

The existing register control (`phase6-register-control`, 600 samples) and
chaining control (`phase6-chain-control`, 480 throughput plus 404 event samples)
also pass their load/completeness gates with the new binary. Event p95 remains
1 microsecond in all four cells; observed maxima are 8-9 microseconds for the
single-program baseline and 20 microseconds for chaining. These maxima include
host scheduling and exceed the earlier accepted chaining maximum of 10
microseconds. Do not claim identical tail latency or a before/after app result
from this single control cohort.

## Remaining Gate

Phase 6 is not complete. The subsequent
[scalar-addressing batch](phase6-addressing-results.md) implements the ordinary
scalar forms. Remaining work includes pair coverage and indirect/conditional
control flow, with precise second-access faults and
bounded events. Improve per-workload profiling windows before ranking broader
vector/FP changes. A cache/lifetime-aware production adapter is still absent.
Only integration followed by matched boot/unlock/Settings/Firefox tests can
establish end-to-end value and justify changing the app default.
