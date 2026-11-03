# Assembly FP register transfers

The opt-in assembly executor now handles the bit-preserving FP transfers:

- FMOV between W and S, X and D, and X and the upper 64-bit vector lane, in
  both directions.
- FMOV between scalar S registers or scalar D registers.
- FMOV immediate to S or D, including all 256 immediate encodings per width.

`Assembly/fp_moves.h` prepares CPU register offsets and expanded immediates;
`Assembly/fp_moves.inc` supplies assembly handlers included by the existing
executor. No operation layout or generated offsets change. The handlers use
integer loads/stores, so signaling NaNs are copied without arithmetic, FP
exceptions are not raised, and neither host nor guest FPCR/FPSR changes.
Writes to S/D clear the remaining destination vector bits; writes to a high
lane preserve its low lane. General register 31 remains XZR rather than SP.
The source is captured before destination writes, including aliased operands.

Every handler uses the existing retirement macro, retaining instruction
budgets, code/mapping guards, PC publication, and service boundaries. No FP
arithmetic, conversion, comparison, or general SIMD arithmetic is added here.
Those require a separate guest FP environment contract before hardware FP
instructions can safely replace C helpers.

Validation: `sh scripts/run-assembly-fp-moves-regressions.sh` and the same
command with `--ubsan` exercise 32,640 differential cases against the native C
executor. Coverage includes S/D/general/high-lane variants, aliased operands,
XZR and V31, upper-lane clearing/preservation, zero/NaN/Inf/subnormal bit
patterns, all guest rounding modes, existing guest exception flags, budget
zero/one, stale code guards, and unchanged host FPCR/FPSR. The assembly path
remains opt-in; these correctness checks do not establish an Android boot
speedup or install a simulator build.
