# Phase 7 ASan Startup Investigation

Date: 2026-10-29. Host: Darwin arm64, macOS 26.5.1 (25F80).

## Result

**PASS for the tested native cache and production correctness suites using the
already-installed Homebrew LLVM 22.1.8 compiler and its matching ASan runtime.**
The default Xcode 17 runtime remains **BLOCKED before main** on this host.
This does not erase the earlier timeout failures or establish compatibility
for Xcode ASan, Swift, Simulator, devices, or every native test suite.

No downloads, runtime suppression, sanitizer disabling, native runtime/test
edits, benchmarks, Simulator actions, or device actions were performed. Only
`scripts/run-phase7-cache-chain-tests.sh` and this document were changed in the
repository. The parent-owned production runner was executed without editing it.

## Evidence And Diagnosis

The retained samples are:

- `experiments/phase3/results/phase7-production-chaining/phase7-production-asan-startup.sample.txt`
- `experiments/phase3/results/phase7-production-chaining/phase7-offsets-asan-startup.sample.txt`

Both show the same main-thread initialization cycle:

```text
libSystem_initializer -> __malloc_init -> wrap_malloc_default_zone
  -> AsanInitInternal -> InitializeShadowMemory -> MemoryRangeIsAvailable
  -> MemoryMappingLayout::Next -> get_dyld_hdr
  -> dyld_shared_cache_iterate_text_swift -> _Block_copy -> malloc
  -> __sanitizer_mz_malloc -> AsanInitFromRtl -> StaticSpinMutex::LockSlow
```

Inference: ASan shadow-memory discovery triggers a dyld allocation that reenters
ASan initialization and waits on the already-held initialization lock. Neither
sample reaches application `main`. A fresh standalone probe with no project
code reproduces the Xcode hang. This isolates a host runtime/startup
compatibility problem; it does not prove a particular upstream fix or that the
application has no memory errors.

## Installed Toolchain Comparison

The probe prints `ASAN_PROBE_MAIN` on entry. Its optional fault allocates eight
bytes and writes through a volatile pointer at index eight. All probe builds
use `-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all
-fno-omit-frame-pointer`; no sanitizer suppression options were set.

| Compiler | Clean probe | Deliberate invalid write |
| --- | --- | --- |
| Xcode Apple Clang 17.0.0, clang-1700.6.3.2 | No main marker; killed after 5 seconds | Not run after startup timeout |
| CLT Apple Clang 15.0.0, clang-1500.3.9.4 | Aborts before main | Same startup abort, not an error-detection pass |
| Homebrew Clang 22.1.8 | Main marker, exit 0 | Main marker, ASan heap-buffer-overflow, SIGABRT |

CLT 15 reports `sanitizer_malloc_mac.inc:189`, failing
`!asan_init_is_running`. Its first compile could not find `stdio.h`; retrying
with the valid SDK allowed compilation but did not resolve startup.

Homebrew's installed configuration
`/opt/homebrew/Cellar/llvm/22.1.8/etc/clang/arm64-apple-darwin25.cfg` contains
`-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`, which is absent.
Its first compile also failed to find `stdio.h`. Passing an explicit
`-isysroot` pointing at the installed Xcode macOS 26.2 SDK resolves compilation:

```text
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk
```

`otool -L` confirms the LLVM probe links its own runtime, not the Xcode runtime:

```text
/opt/homebrew/opt/llvm/lib/clang/22/lib/darwin/libclang_rt.asan_osx_dynamic.dylib
SHA-256: 939a094a9760d0e46506ce3c273c21183b06771629ace48d006baec87d49108b
```

The initial LLVM fault report had external-symbolizer warnings but still
reported the overflow and aborted. Repeating with
`ASAN_SYMBOLIZER_PATH=/opt/homebrew/opt/llvm/bin/llvm-symbolizer` produced a
source-level report at `probe.c:10:14` without those warnings. This selects an
installed reporting tool, not a suppression or changed error policy.

## Native Validation

| Check | Result | Build plus run wall time |
| --- | --- | ---: |
| Cache suite, LLVM 22 ASan+UBSan | Exit 0; ownership/admission and both compile/link guards PASS | 11.84 s |
| Production suite, LLVM 22 ASan | Exit 0; all nine cases PASS | 6.43 s |
| Cache suite, default Xcode optimized | Exit 0; all checks PASS | 3.35 s |
| Cache suite, LLVM 22 UBSan | Exit 0; all checks PASS | 4.97 s |
| Offsets generator, LLVM 22 ASan+UBSan | Exit 0; output byte-matches `Assembly/offsets.h` | 0.15 s build, 0.32 s run |
| Cache runner with nonexistent SDK | Exit 2 before compilation, clear SDK error | 0.01 s |
| Cache runner shell syntax | `sh -n` exit 0 | Not measured |

Production cases: budgets, invalidation, helpers, selection,
semantic-superblock, legacy, two-owners, timers, entry-translation. The run
printed `START production chain main` and its final production-contract PASS.
These are correctness diagnostics, not performance measurements. ASan
instruments the compiled C; handwritten assembly accesses are not thereby
instrumented. No blanket memory-safety claim is made.

## Reproduction And Ownership

The cache runner now accepts `CC` as a single compiler executable and `SDKROOT`
as an SDK directory, prints compiler identity/SDK, and passes the same explicit
SDK to all compiler invocations. Without overrides it retains `clang` and uses
`xcrun --sdk macosx --show-sdk-path`. ASan still enables address and undefined
sanitizers with non-recovering errors; frame pointers are now retained.
There is no automatic fallback that could turn a failing sanitizer run green.

From the repository root:

```sh
CC=/opt/homebrew/opt/llvm/bin/clang \
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
ASAN_SYMBOLIZER_PATH=/opt/homebrew/opt/llvm/bin/llvm-symbolizer \
sh scripts/run-phase7-cache-chain-tests.sh --asan
```

For production, **recommend that the parent add the same `CC`/explicit
`-isysroot` selection to every compiler invocation**, including offsets and
assembly, and record compiler/runtime identity. `CC` alone currently has no
effect because that runner invokes literal `clang`. Keep its sanitizer flags,
tests, and failure reporting intact. Prefer a bounded supervisor for the whole
runner as well as its existing 60-second executable deadline.

For this investigation only, a temporary executable named `clang` was placed
first in the production subprocess's `PATH`; it contained:

```sh
#!/bin/sh
set -eu
exec /opt/homebrew/opt/llvm/bin/clang -isysroot "${SDKROOT:?SDKROOT required}" "$@"
```

`SDKROOT` was the Xcode SDK above. The command was
`sh scripts/run-phase7-production-chain-tests.sh --asan`, with no case filter
and no benchmark argument. No `DYLD_*` injection or replacement dylib was used.
Production runner SHA-256 at validation:
`cc5f06c5b44b6f81c36da66698b93de937b2d378574c48755e1d31263a61fe02`.

Parent integration follow-up: the production runner now accepts `CC` and an
explicit SDK directly. `CC=/opt/homebrew/opt/llvm/bin/clang` with
`ASAN_SYMBOLIZER_PATH=/opt/homebrew/opt/llvm/bin/llvm-symbolizer` passed the full
production ASan suite without the temporary wrapper. Final cache ASan+UBSan
also includes the translator-replacement and bulk-validation regressions.
Logs are retained under `experiments/phase3/results/phase7-boundary-cost/`.

## Deadlines, Logs, And Cleanup

Python subprocess supervisors used `start_new_session=True` and
`communicate(timeout=...)`: 15 seconds for probe compilation, 5 seconds for
probe execution, and 45 seconds for each native runner including compilation.
The fresh Xcode probe was killed with SIGKILL after five seconds and reaped
with `communicate()` (Python return code -9, shell equivalent 137). The old
exit-142 failures in the original results remain unchanged. Every other child
exited within its deadline; CLT and deliberate-fault SIGABRT exits are failures
or expected negative controls, not clean sanitizer passes. Native runners
also retained their existing 60-second executable alarms.

Temporary probe source/binaries, compiler wrapper, and complete diagnostic
logs are retained under `/tmp/phase7-asan-investigation.p7mf7O/`. These are
ephemeral artifacts, not durable repository evidence; the result table and
critical diagnostics are recorded here. Existing experiment logs were not
overwritten. No per-run cache/production work directory was retained by the
runners.

Final process inspection checked all 19 recorded diagnostic process/group IDs,
their direct children, and matching temporary executable paths: **no processes
remained**. Every direct child was waited/reaped; no timed-out process was left
running. No unrelated processes were signaled.
