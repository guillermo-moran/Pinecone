# Instruction translation reuse promotion

Instruction mapping validation and instruction fetch share a fully associative
16-entry hot TLB. Previously they searched from slot zero on every access,
including repeated certification of a page held in slot fifteen. The earlier
Firefox cache audit found mapping certification, rather than demand fetch, in
about 96% of instruction-translation samples. That audit is attribution from
an Alpine workload, not a measurement of the current Android guest.

The accepted candidate promotes a reused nonzero hot slot to slot zero after
it is encountered again. It swaps complete entries and retains all sixteen
cached mappings. A single pass through sixteen different pages does not
trigger repeated swaps. The central set-associative TLB and page-table walker
are unchanged. Hot-cache insertion still advances its round-robin slot, but
promotion can change which mapping that slot subsequently replaces.

Every lookup still synchronizes shared translation publications and checks the
same validity, generation, contiguous range, virtual page and context tag.
ASID changes and local/shared TLBI still invalidate hot proofs through the
existing generation mechanism. Promotion caches no instruction bytes and adds
no permission shortcut. Physical memory, MMIO, data accesses, observations,
code invalidation, and fault handling use their existing paths. The one-byte
owner-private reuse hint is appended to the private memory context; no existing
assembly-visible field offset changes.

A first candidate that probed a variable MRU slot before scanning was rejected:
it improved repeated slot-fifteen accesses but regressed repeated slot-zero
accesses by 60–76%. The dependent hint lookup cost more than the saved work.
The retained candidate keeps the common fixed-slot-zero access direct.

## Measurement

`sh scripts/run-instruction-tlb-mru-regressions.sh --benchmark` builds the same
source twice with Apple clang 17.0.0, `-O3`, and
`AVZ_INSTRUCTION_TLB_MRU=0`/`1`. Both binaries first run correctness checks.
It alternates process order across seven cohorts. Each pattern performs two
million translations, statistics disabled, with the same guest RAM, working
set, callback/native translation setup, and checksum. The runner deletes its
temporary executables on completion. The first cohort is excluded below.

Native stage-one translation, median nanoseconds per certification:

| Access pattern | Control | Promotion | Time reduction |
| --- | ---: | ---: | ---: |
| Repeated page initially in slot zero | 5.805 | 5.885 | -1.4% |
| Repeated page initially in slot fifteen | 13.901 | 6.240 | 55.1% |
| 64-access bursts across sixteen pages | 9.540 | 6.517 | 31.7% |
| One access per page, sixteen-page cycle | 9.268 | 9.390 | -1.3% |
| One access per page, sixty-four-page cycle | 16.117 | 15.970 | 0.9% |

Callback-backed translation showed 43.0% and 21.4% less time for slot-fifteen
reuse and sixteen-page bursts, with the two cyclic patterns within 1%.
These are isolated translation microbenchmarks on a shared development Mac;
they do not establish an Android boot-time or whole-emulator speedup.

## Validation

- The isolated runner checks both control and candidate, including actual
  promotion, full-cache fallback, all local/shared TLBI scope kinds, callback
  replacement, ASID changes, remapping, execute-never faults, and fresh code
  bytes after a previously promoted mapping. The `--ubsan` mode checks both.
- `sh scripts/native-memory-fastpath-run.sh --check` and `--ubsan` each pass
  38,535 cases and 38 threaded scenarios, covering data memory, MMIO callbacks,
  observation, exclusives, shared invalidation and concurrent access.
- The parent integration run checks assembly offsets and native execution
  contracts after this private-layout extension.

No simulator settings, guest images, or running emulator processes are changed
by these scripts. A compile-time control disables promotion for comparisons;
normal builds retain the measured candidate.
