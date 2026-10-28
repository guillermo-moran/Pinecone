# Android-Relevant Interpreter Validation

## Scope

These are standalone correctness regressions, not an Android boot test. They do
not enable Swift fallback, generate host executable code, run QEMU/Simulator,
rebuild guest images, change runtime defaults, or modify production sources.
All new files are under `scripts/android-runtime-validation/` plus this document.
No existing tests/build scripts were changed. No integrated Swift/app build was
run; that remains with the parent integration workstream.

Most workloads are **synthetic, not real Bionic/ART conformance**. An optional
runner additionally compiles one hash-pinned upstream Bionic `strlen.S` function
and executes the same instruction bytes natively and through the interpreter.
That is actual upstream function coverage, not Android's ELF loader, libc ABI,
ART runtime, kernel, or complete Bionic test suite.

## Run

From `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
sh scripts/android-runtime-validation/run.sh all
sh scripts/android-runtime-validation/run.sh all --ubsan
sh scripts/android-runtime-validation/run.sh memory
sh scripts/android-runtime-validation/run.sh fp
sh scripts/android-runtime-validation/run.sh atomic
sh scripts/android-runtime-validation/run.sh publication
sh scripts/android-runtime-validation/audit-features.sh
```

The C harness requires an AArch64 host and Clang; unsupported host architectures
exit 77. Compilation uses a temporary directory and links the existing native
interpreter, block cache, and guest-memory implementation. The private threaded
dispatcher adapter follows the existing standalone regression approach. Test
expectations do not use another interpreter as an oracle. All references are
statically assembled; reading those instruction bytes does not create a JIT.

`run.sh` prints three production-source SHA-256 fingerprints and exits 3 if they
change during compilation. This is important while other owners edit those
sources. It does not snapshot the repository. Each message/publication worker
has a bounded polling deadline, interpreter calls have instruction budgets, and
the C main installs a 120-second alarm. Compilation/runtime initialization are
not covered by that alarm.

`all`, `fp`, and `atomic` intentionally return 1 on the currently reproduced
production defects. They are not marked as expected successes or silently
skipped. A fatal harness invariant can stop a group early; diagnostic counters
only count completed cases. Invalid command-line modes return 2.

## Results

Measured 2026-10-26 on ARM64 macOS 26.5.1 (25F80), Apple Clang 17.0.0
(`clang-1700.6.3.2`). Normal build uses `-O2`; UBSan appends `-O1 -g
-fsanitize=undefined -fno-sanitize-recover=all`.

| Group | Cases | Failures |
| --- | ---: | ---: |
| Callback memory/string and fault boundaries | 72,545 | 0 |
| Shared fast-memory string/copy/move | 1,920 | 0 |
| Scalar FADD D | 4,096 | 1,916 |
| Scalar FDIV D | 4,096 | 2,116 |
| Vector FADD 4S | 4,096 | 3,218 |
| CMEQ 16B / UMAXV 16B / UQADD 16B | 12,288 | 0 |
| Exclusive reservations, increment stress, messages | 2,026 | 1 |
| Sequential/concurrent code publication | 1,600 | 0 |
| **Synthetic total** | **102,667** | **7,251** |

`run.sh all`: exit 1, 0.907859 seconds inside the harness.
`run.sh all --ubsan`: exit 1, 1.586649 seconds inside the harness, no UBSan
diagnostics in the final run. Both reported exactly the table above. The
contended counter finished at 4,000; retired increment instructions varied
(26,064 normal; 33,144 UBSan) because failed exclusive stores retry. Message
passing completed 2,000 payload transfers with no observed stale payload.

These are correctness-run durations, not performance comparisons or UI latency.
There was no pre-optimization baseline, guest/UI timing, or runtime-default
change. Concurrency stress is bounded empirical evidence, not a memory-model
proof or exhaustive scheduler exploration.

The three source fingerprints for these final runs were:

```text
ARM64VizNative.c      07550f6036dc3a56c6ce0a392d2fda44eb25b94717420a1de5dff35e304dab7f
ARM64VizBlockCache.c  0ea3b301e39c45265d2357ecc705829f948103e4ef7461de3f77e192fcb1d1e8
ARM64VizGuestMemory.c cf55410783d827ae6c8a57e2d9965b80e80c75842ebdec091a0dfdddeae9356f
```

`audit-features.sh`: exit 0, six read-only/reset checks passed. It compiles only
`CPUState.swift`, `SystemRegisters.swift`, and the new probe, not the package.
It reports `ID_AA64PFR0_EL1=0x11`, `ID_AA64ISAR0_EL1=0`, and
`ID_AA64ISAR1_EL1=0`. FP/ASIMD field value zero advertises base functionality;
the sampled AES/CRC32/LSE/SVE/pointer-authentication fields do not advertise
those extensions. Actual guest `AT_HWCAP` was not measured. Linux documents
the correspondence in its [ARM64 ELF hwcaps reference](https://docs.kernel.org/arch/arm64/elf_hwcaps.html).

`run-bionic-strlen.sh /tmp/arm64viz-validation-bionic-strlen.S`: exit 0,
**5,376 cases passed**, 80 assembled instructions. This is additional to the
synthetic total. Supplying `sequences.S` instead correctly returned 2 with a
source-hash mismatch. `sh -n` passed for all three new shell scripts.

ASan builds compiled, but both `run.sh all --asan` and the focused
`run.sh publication --asan` did not complete promptly and were interrupted.
No ASan success is claimed. The focused outside-sandbox retry also stalled and
was interrupted (exit 130); the cause was not diagnosed. An early UBSan run exposed
out-of-bounds intermediate pointer arithmetic in this new callback harness;
that harness bug was corrected and the final UBSan run above completed.

## Production Findings

### FPCR And FPSR Semantics

Reproduce with `sh scripts/android-runtime-validation/run.sh fp`.
The reference assembly saves/restores the host FPCR/FPSR and explicitly sets
the reference rounding, flush-to-zero, default-NaN, and sticky-flag inputs.
Each instruction's assembled opcode is read directly from the same static
text used by the native oracle. Guest state starts independently.

Minimal cases, with all unspecified inputs zero:

| Opcode / inputs | Native expected | Interpreter observed |
| --- | --- | --- |
| `1e622820` FADD D0,D1,D2; D1=`3ff0000000000000`, D2=`3ca0000000000000`, FPCR=`00400000` | D0=`3ff0000000000001`, FPSR=`10` | D0=`3ff0000000000000`, FPSR=`0` |
| `1e621820` FDIV D0,D1,D2; D1=0, D2=0, FPCR=0 | D0=`7ff8000000000000`, FPSR=`1` | Same result bits, FPSR=`0` |
| `1e622820` FADD; D1=0, D2=`7ff0000000000001`, FPCR=0 | D0=`7ff8000000000001`, FPSR=`1` | Same result bits, FPSR=`0` |

For FADD D, 1,064 cases differed in result bits and 1,372 in FPSR. For FDIV D,
the counts were 1,060 and 1,640; for FADD 4S, 2,745 and 2,352. These categories
overlap. The matrix includes all four rounding modes, all FZ/DN combinations,
positive/negative zero, normal/subnormal inputs, half-ULP additions, overflow,
infinities, quiet/signaling NaNs, and preexisting sticky flags.

The relevant production implementation is the
`AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC` case in
`Sources/ARM64VizNative/ARM64VizNative.c` (around line 6263 at measurement).
It performs C floating-point operations without applying guest FPCR or
accumulating their exceptions into guest FPSR. This is a correctness gap in
advertised base FP/ASIMD functionality, not a justification for changing the
advertised feature mask or enabling fallback. No production fix was attempted.

### CLREX Native Coverage

Reproduce with `sh scripts/android-runtime-validation/run.sh atomic`.
`avz_native_decode_instruction(0xd5033f5f, ...)` returns zero for `CLREX`.
The harness reports a failure and continues other atomic tests without
pretending that CLREX executed or clearing the reservation on its behalf.

`Sources/ARM64VizCore/EmulatorBackend.swift` explicitly returns false for the
CLREX pattern in `executeNativeSingleInstructionIfPossible` (around line 4152),
and the nearby native-only path rejects unsupported single-instruction
execution unless fallback is allowed. Swift does have CLREX handling. This
identifies a native-only coverage gap; integrated VM routing/exception behavior
must be reproduced by the parent rather than inferred from this C harness.
CLREX is a base instruction, not gated by the optional LSE feature bit. No Swift
fallback was enabled to make this test pass.

## Coverage Details

- Callback memory: lengths `0,1,2,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257`;
  32 source/destination alignment combinations; full-buffer canaries; every
  memcmp mismatch position including equality and high-bit bytes; overlap
  deltas -17 through +17; terminators at the end of a 4 KiB page. Copy uses
  128-bit loads/stores plus a byte tail. Expected bytes come from snapshot
  models, also checked against native static assembly.
- Fault boundaries: 33 unterminated byte scans fail exactly at guest byte 4096.
  PC, retired steps, address, and post-index register are checked. This tests
  callback failure/precise retirement, not integrated EL1 exception delivery.
- Fast memory: 12 lengths up to 4095 and 32 alignments; scalar and vector
  operations cross 4 KiB boundaries; overlaps -17, 0, +17. The mandatory slow
  callback for cross-page scalar beats takes guest-memory range locks and
  publishes write generations; no synchronization is bypassed for speed.
- Atomics: byte/half/word/doubleword LDAXR/STLXR, same-value and ABA writes by
  a second vCPU, pair exclusives at both sides of a page boundary for 32/64-bit
  elements, writes to either pair element, monitor clearing after stores,
  4,000 concurrent increments, and 2,000 LDAR/STLR payload handshakes. Tests
  use independent vCPU fast paths sharing one production guest-memory object.
  Host thread creation/join synchronizes endpoints, not individual messages.
- Code publication: 200 replacements at each of three addresses, including
  an instruction/RET pair straddling a page boundary; both caches execute
  every new value and the consumer repeats a warm-cache execution. A further
  1,000 publications run on two host threads with guest release/acquire
  acknowledgment and consumer ISB. Producer sequences include DC CVAU, DSB
  ISH, IC IVAU, DSB ISH. This patches guest RAM only. It does not test unsafe
  concurrent rewriting of a currently executing instruction, dual RW/RX
  aliases, page-table remapping, direct-link/superblock execution, or actual
  ART entrypoint/GC/membarrier protocols.

## Optional Actual Source

The local Android SDK contains API 33/34 framework source/JARs and ARM64
system-image distributions. API 34's Google APIs ARM64 image is revision 6.
No NDK installation or unpacked Bionic/ART source/runtime was found in the
inspected SDK/project locations. This is not a claim that no toolchain exists
elsewhere on the machine. Images were listed only; none were booted, extracted,
modified, or rebuilt.

The optional path needs neither an NDK nor an Android device. Supply the exact
[AOSP Bionic strlen.S](https://android.googlesource.com/platform/bionic/+/6f9a97f864898bb9538898b212bf0a9547b2f943/libc/arch-arm64/generic/bionic/strlen.S)
from commit `6f9a97f864898bb9538898b212bf0a9547b2f943`, Git blob
`6e540fc330389c765d107f7e4a33f4b224c9d353`. For example:

```sh
curl -fL 'https://android.googlesource.com/platform/bionic/+/6f9a97f864898bb9538898b212bf0a9547b2f943/libc/arch-arm64/generic/bionic/strlen.S?format=TEXT' -o /tmp/arm64viz-validation-bionic-strlen.b64
base64 --decode -i /tmp/arm64viz-validation-bionic-strlen.b64 -o /tmp/arm64viz-validation-bionic-strlen.S
sh scripts/android-runtime-validation/run-bionic-strlen.sh /tmp/arm64viz-validation-bionic-strlen.S
```

The base64 syntax above is macOS-specific. The runner itself does not download
anything and refuses any other blob. The original license stays in the supplied
source. Only ENTRY/END linkage macros are replaced by the new adapter header;
instruction source is not rewritten. Cases cover 21 lengths through 1023, 64
tail offsets near a 4 KiB boundary, and four ASCII/non-ASCII patterns. Native
memory is padded; guest callbacks reject accesses outside the containing page.
This is not a native guard-page fault test or a current-Bionic implementation
claim. It checks one historical upstream algorithm with independent native
execution and simple length expectations.

For ART provenance, the [AOSP JIT code-cache implementation at
11a2df36e5645a17400a178c08b91e5a56acb895](https://android.googlesource.com/platform/art/+/11a2df36e5645a17400a178c08b91e5a56acb895/runtime/jit/jit_code_cache.cc)
describes data/instruction cache flushing, code-cache reuse, dual mappings, and
cross-core pipeline synchronization. That motivated publication stress here;
no ART code was executed and its complete publication protocol is not emulated.

Passing these tests does not establish Android boot readiness.
