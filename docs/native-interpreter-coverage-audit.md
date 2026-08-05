# Native Interpreter Coverage Audit

This audit treats the C interpreter as the production path. The Swift decoder is
useful as a reference implementation and diagnostic harness, but booting Linux
reliably must not depend on Swift fallback for ordinary instruction execution.

## Current Native Shape

- Native decode starts in `Sources/ARM64VizNative/ARM64VizNative.c` at
  `avz_native_decode_instruction`.
- The public native opcode set currently ends at
  `AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER`.
- Swift basic block decode checks each instruction with
  `avz_native_decode_instruction` before a block is considered native eligible.
- The default fallback policy is `diagnosticsOnly`, which throws a native
  coverage gap for decoded basic blocks that cannot run natively.
- The threaded C dispatcher has direct labels for a small hot subset:
  NOP, HLT, ADR, CBZ/TBZ/B.cond, ADD/SUB immediate, MOV wide, ADD/SUB shifted,
  branches, common GPR load/store, logical register/immediate, and register
  branch. Other native operations go through the generic C switch. That is
  still native C execution, but it is slower than direct threaded dispatch.

## Immediate No-Fallback Holes

These are the highest-priority gaps because the Swift interpreter already has
some behavior for them, but C-native execution does not cover them or does not
cover them in the fast threaded path.

1. System, exception, and barrier instructions

   Swift decodes ERET, SVC, BRK, CLREX, barriers, system instructions, MRS, and
   MSR. The native C decoder currently treats broad HINT/NOP forms and HLT, but
   it does not have a callback model for exception routing, system registers,
   cache/TLB maintenance, or PSTATE updates. A strict no-fallback runtime needs
   native op kinds plus host callbacks for these side effects.

2. Atomic load/store beyond the exclusive monitor

   Native C now covers simple LDAR/STLR, LDXR/STXR, and LDXP/STXP monitor
   behavior, including reservation state crossing the Swift/C bridge. It still
   does not cover compare-and-swap, swap, or LSE read-modify-write operations.
   Linux and libc synchronization paths can still find these.

3. SIMD/FP load-store breadth

   Native C now decodes and executes the current Linux blockers: scalar byte
   forms, S/D/Q unsigned-immediate loads/stores, Q signed-immediate
   loads/stores, and D/Q pair loads/stores. Remaining gaps include literal
   SIMD/FP loads, structure loads/stores, lane loads/stores, and the full
   pre/post-index matrix for every scalar/vector width.

4. FP scalar arithmetic and conversion completeness

   Native C now covers scalar FP add, subtract, multiply, compare, conditional
   select, integer-to-FP, and FP-to-integer conversions needed by the current
   BusyBox/libc paths. It still needs divide, sqrt, abs/neg, min/max,
   multiply-add, rounding-mode correctness, and real FPCR/FPSR state plumbing;
   the bridge currently passes local zero values rather than VM-owned FP state.

5. AdvSIMD breadth

   Native C now covers the specific recent blockers: TBL/TBX, ZIP/UZP/TRN, MOVI
   D immediates, selected MOVI/MVNI, DUP, INS from general, SSHLL S-to-D, and
   vector ADD. That is still sparse. Important missing groups include vector
   logical ops, comparisons, shifts, narrow/widen, EXT, REV, ABS/NEG, SUB,
   pairwise ops, min/max, multiply, UMOV/SMOV for all element sizes, element
   insert/extract variants, LD1/ST1 structure forms, and lane load/store forms.

6. Native threaded dispatch coverage

   Many operations that are decoded natively still hit `op_generic` in the C
   threaded runner. That is functionally better than Swift fallback, but it is
   still a performance hole. Hot scalar ops, load/store-register-offset,
   load-literal, pair load/store, atomics, and the newly added SIMD operations
   should get direct threaded labels.

## Broader Missing Instruction Families

These are not all required for the current Alpine shell, but they are expected
in a robust ARM64 interpreter for Linux, Android-class userlands, and modern
toolchains.

- Scalar integer: CRC32/CRC32C, full data-processing one/two-source variants,
  conditional set/invert/negate aliases verified through their base encodings,
  pointer-auth and branch-target instructions handled according to advertised
  feature bits, and complete PSTATE immediate handling.
- Branch/control: BTI/PAuth feature gating, full exception return behavior, and
  synchronous exception routing without leaving C-native dispatch.
- Memory ordering: DMB, DSB, ISB, CLREX, exclusive monitor state, acquire and
  release ordering, and LSE atomics.
- System/caches: MRS/MSR callbacks, DC ZVA, IC IVAU, TLBI, cache maintenance
  no-ops or effects consistent with exposed CPU features, and code-cache
  invalidation hooks.
- Load/store: SIMD/FP load/store all scalar/vector widths, pair forms for
  S/D/Q, unprivileged access semantics, pre/post-index writeback hazards,
  literal SIMD/FP loads, and structure loads/stores.
- AdvSIMD: integer logical, permute, table, shift, compare, arithmetic,
  multiply, saturating, narrowing, widening, pairwise, and across-vector forms.
- Floating point: scalar S/D arithmetic, divide, sqrt, abs/neg, min/max,
  multiply-add, S/D conversion, integer conversion with FPCR rounding mode, and
  FPSR flag updates.
- Feature discipline: ID registers must only advertise instruction families the
  interpreter actually implements or safely treats as disabled.

## Practical Closure Plan

1. Add a strict native-only test mode that fails if any executed instruction
   uses the Swift decoded path while decoded basic blocks are enabled.
2. Add native callback op kinds for system register reads/writes, system
   instructions, barriers, SVC/BRK, ERET, WFI/WFE, CLREX, and DC ZVA.
3. Port every Swift-supported basic-block instruction to C-native decode and
   execution, then add direct threaded labels for hot ones.
4. Expand atomic load/store families beyond LDXR/STXR/LDXP/STXP into LSE
   compare-and-swap, swap, and read-modify-write forms before relying on broad
   package-manager workloads.
5. Continue SIMD/FP load-store expansion into literal, structure, lane, and full
   addressing-mode coverage.
6. Expand AdvSIMD in families, not one opcode at a time: logical, compare,
   shift, move/extract/insert, permute, arithmetic, then multiply/narrow/widen.
7. Add an opcode fixture suite generated from known encodings and assembly
   snippets. Each fixture should assert native decode, native execution, Swift
   reference parity where available, and no unsupported-exit accounting.
8. Keep optional ARM features disabled in guest-visible registers until the
   corresponding instruction family has native coverage and tests.

## Current Risk Summary

The interpreter is no longer merely a line-by-line Swift fallback, but it is not
yet a complete no-fallback ARM64 runtime. The biggest correctness holes are
system/exception side effects, atomics/exclusives, SIMD/FP memory forms, and
FPCR/FPSR handling. The biggest performance hole is that many native-decoded
instructions still route through the generic C switch instead of direct threaded
dispatch.
