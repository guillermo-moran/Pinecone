#if defined(__APPLE__) && defined(__aarch64__) && !defined(__arm64e__)
#include "offsets.h"
.text
.p2align 2

// Private ABI: x19 CPU, x20 operation, x21 budget, x22 retired, x23 control.
// x24 is the memory view. Hot handlers never call C or grow the stack.
// The terminal memory helper follows the normal ABI (including vector rules).
.macro GUARD pointer, epoch, shared=0
    ldr x9, [x23, #\pointer]
    cbz x9, 1f
.if \shared
    ldar x10, [x9]
.else
    ldr x10, [x9]
.endif
    ldr x11, [x23, #\epoch]
    cmp x10, x11
    b.ne Lrevalidate
1:
.endm
.macro VALIDATE
    GUARD G_LOCAL, G_EPOCH0
    GUARD G_SHARED0, G_EPOCH1, 1
    GUARD G_SHARED1, G_EPOCH2, 1
    GUARD G_SHARED2, G_EPOCH3, 1
    cbz x24, Lvalidated\@
    ldr x9, [x24, #M_SHARED]
    cbz x9, Lvalidated\@
    add x10, x9, #R_TRANSLATION
    ldar x10, [x10]
    ldr x11, [x24, #M_TRANSLATION]
    cmp x10, x11
    b.ne Lrevalidate
    add x9, x9, #R_CODE
    ldar x10, [x9]
    ldr x11, [x24, #M_CODE]
    cmp x10, x11
    b.ne Lrevalidate
Lvalidated\@:
.endm
.macro DISPATCH
    ldr x9, [x20, #O_HANDLER]
    br x9
.endm
.macro RETIRE
    add x22, x22, #1
    sub x21, x21, #1
    VALIDATE
    cbz x21, Lbudget
    DISPATCH
.endm
.macro NEXT
    ldr x9, [x20, #O_PC]
    str x9, [x19, #C_PC]
    add x20, x20, #O_SIZE
    RETIRE
.endm
.macro READ source, target
    ldrsh x9, [x20, #\source]
    cmn x9, #1
    b.eq 1f
    ldr \target, [x19, x9]
    b 2f
1:  mov \target, #0
2:
.endm
.macro WRITE
    ldrsh x9, [x20, #O_DST]
    cmn x9, #1
    b.eq 1f
    str x10, [x19, x9]
1:
.endm
.macro FLAGS
    // Capture before the destination's XZR check changes host NZCV.
    mrs x12, nzcv
    ubfx x12, x12, #28, #4
    ldr x13, [x19, #C_FLAGS]
    bfi x13, x12, #28, #4
    str x13, [x19, #C_FLAGS]
.endm
.macro HANDLER name
    .p2align 2
    .globl _ag_\name
    .private_extern _ag_\name
    .alt_entry _ag_\name
_ag_\name:
.endm

// Keep the hot region's 64-byte alignment independent of C wrapper growth.
.p2align 6
.globl _ag_enter
.private_extern _ag_enter
_ag_enter:
    .cfi_startproc
    stp x29, x30, [sp, #-64]!
    .cfi_def_cfa_offset 64
    .cfi_offset w29, -64
    .cfi_offset w30, -56
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    .cfi_offset w19, -48
    .cfi_offset w20, -40
    .cfi_offset w21, -32
    .cfi_offset w22, -24
    .cfi_offset w23, -16
    .cfi_offset w24, -8
    mov x29, sp
    .cfi_def_cfa w29, 64
    mov x23, x0
Lvisit_load:
    add x24, x23, #G_MEMORY
    ldr x9, [x24, #M_PATH]
    cmp x9, #0
    csel x24, x24, xzr, ne
    ldr x19, [x23, #G_CPU]
    ldr x20, [x23, #G_OP]
    ldr x21, [x23, #G_BUDGET]
    mov x22, #0
    VALIDATE
    DISPATCH

Lbudget:
    mov w9, #S_MAX
#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
    b Lbudget_service
#else
    b Lreturn
#endif
Lrevalidate:
    mov w9, #S_REVALIDATE
Lreturn:
    str w9, [x23, #G_STATUS]
    str x22, [x23, #G_STEPS]
    str x22, [x23, #G_DISPATCHES]
Lrestore:
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    .cfi_remember_state
    ldp x29, x30, [sp], #64
    .cfi_def_cfa sp, 0
    .cfi_restore w19
    .cfi_restore w20
    .cfi_restore w21
    .cfi_restore w22
    .cfi_restore w23
    .cfi_restore w24
    .cfi_restore w29
    .cfi_restore w30
    ret
    .cfi_restore_state

// All gadgets are within this CFI range and share the entry's one frame.
HANDLER outside
    mov w9, #S_OUT
    b Lreturn
// A pinned chain owns every target. No C lookup or new frame on a direct edge.
// Every edge (including an intra-block loop) passes through this service gate.
HANDLER boundary
    ldr x12, [x23, #G_CHAIN]
    ldr x9, [x12, #CH_POLLS]
    add x9, x9, #1
    str x9, [x12, #CH_POLLS]
    ldr x9, [x12, #CH_EVENTS]
    cbz x9, Lchain_allowance
    ldar x9, [x9]
    cbnz x9, Lchain_yield
Lchain_allowance:
    ldr x9, [x12, #CH_REMAINING]
    cbz x9, Lchain_yield
    sub x9, x9, #1
    str x9, [x12, #CH_REMAINING]
    ldr x9, [x12, #CH_ENTRIES]
    add x9, x9, #1
    str x9, [x12, #CH_ENTRIES]
    ldr x20, [x20, #O_TAKEN]
    DISPATCH
Lchain_yield:
    mov w9, #S_YIELD
    b Lreturn
HANDLER unsupported
    ldr w9, [x20, #O_RAW]
    str w9, [x23, #G_RAW]
    mov w9, #S_UNSUPPORTED
    b Lreturn
HANDLER nop
    NEXT
HANDLER move
    ldr x10, [x20, #O_IMM]
    WRITE
    NEXT
HANDLER movk
    READ O_SRC, x10
    ldr x11, [x20, #O_AUX]
    and x10, x10, x11
    ldr x11, [x20, #O_IMM]
    orr x10, x10, x11
    WRITE
    NEXT

.macro ARITH name, instruction, width, register=0, flags=0, carry=0
HANDLER \name
    READ O_SRC, x10
.if \register
    READ O_AUX, x11
.else
    ldr x11, [x20, #O_IMM]
.endif
Lready_\name:
.if \carry
    ldr x12, [x19, #C_FLAGS]
    msr nzcv, x12
.endif
.if \width == 32
    \instruction w10, w10, w11
.else
    \instruction x10, x10, x11
.endif
.if \flags
    FLAGS
.endif
    WRITE
    NEXT
.endm
.macro FAMILY prefix, width, register
    ARITH \prefix\width\()_add, add, \width, \register
    ARITH \prefix\width\()_sub, sub, \width, \register
    ARITH \prefix\width\()_adds, adds, \width, \register, 1
    ARITH \prefix\width\()_subs, subs, \width, \register, 1
.endm
FAMILY imm, 32, 0
FAMILY imm, 64, 0
FAMILY reg, 32, 1
FAMILY reg, 64, 1
.macro CARRY width
    ARITH carry\width\()_add, adc, \width, 1, 0, 1
    ARITH carry\width\()_sub, sbc, \width, 1, 0, 1
    ARITH carry\width\()_adds, adcs, \width, 1, 1, 1
    ARITH carry\width\()_subs, sbcs, \width, 1, 1, 1
.endm
CARRY 32
CARRY 64
.macro LOGIC width
    ARITH and\width, and, \width, 1
    ARITH orr\width, orr, \width, 1
    ARITH eor\width, eor, \width, 1
    ARITH ands\width, ands, \width, 1, 1
.endm
LOGIC 32
LOGIC 64

.macro MORE_LOGIC width
    ARITH invand\width, bic, \width, 1
    ARITH invorr\width, orn, \width, 1
    ARITH inveor\width, eon, \width, 1
    ARITH invands\width, bics, \width, 1, 1
    ARITH immand\width, and, \width
    ARITH immorr\width, orr, \width
    ARITH immeor\width, eor, \width
    ARITH immands\width, ands, \width, 0, 1
.endm
MORE_LOGIC 32
MORE_LOGIC 64

// Shift preparation shares the ordinary ALU/retirement body. The decoded
// handler selects the shift; there is no per-instruction shift-type switch.
.macro SHIFTED name, target, shift, width
HANDLER \name
    READ O_SRC, x10
    READ O_AUX, x11
    ldr x12, [x20, #O_IMM]
.if \width == 32
    \shift w11, w11, w12
.else
    \shift x11, x11, x12
.endif
    b Lready_\target
.endm
.macro SHIFT_ARITH shift, width
    SHIFTED \shift\width\()_add, reg\width\()_add, \shift, \width
    SHIFTED \shift\width\()_sub, reg\width\()_sub, \shift, \width
    SHIFTED \shift\width\()_adds, reg\width\()_adds, \shift, \width
    SHIFTED \shift\width\()_subs, reg\width\()_subs, \shift, \width
.endm
.macro SHIFT_LOGIC shift, width, prefix
    SHIFTED \shift\prefix\()and\width, \prefix\()and\width, \shift, \width
    SHIFTED \shift\prefix\()orr\width, \prefix\()orr\width, \shift, \width
    SHIFTED \shift\prefix\()eor\width, \prefix\()eor\width, \shift, \width
    SHIFTED \shift\prefix\()ands\width, \prefix\()ands\width, \shift, \width
.endm
.macro SHIFTS width
    SHIFT_ARITH lsl, \width
    SHIFT_ARITH lsr, \width
    SHIFT_ARITH asr, \width
    SHIFT_LOGIC lsl, \width
    SHIFT_LOGIC lsr, \width
    SHIFT_LOGIC asr, \width
    SHIFT_LOGIC ror, \width
    SHIFT_LOGIC lsl, \width, inv
    SHIFT_LOGIC lsr, \width, inv
    SHIFT_LOGIC asr, \width, inv
    SHIFT_LOGIC ror, \width, inv
.endm
SHIFTS 32
SHIFTS 64

.macro SELECT name, instruction, width
HANDLER \name
    READ O_SRC, x10
    READ O_AUX, x11
    ldr x12, [x19, #C_FLAGS]
    ubfx x12, x12, #28, #4
    ldr x9, [x20, #O_IMM]
    lsr x9, x9, x12
    tst x9, #1
.if \width == 32
    \instruction w10, w10, w11, ne
.else
    \instruction x10, x10, x11, ne
.endif
    WRITE
    NEXT
.endm
.macro CONDITIONAL_COMPARE name, instruction, width, immediate
HANDLER \name
    ldr x12, [x19, #C_FLAGS]
    ubfx x12, x12, #28, #4
    ldr x9, [x20, #O_AUX]
    lsr x9, x9, #16
    lsr x9, x9, x12
    tbz w9, #0, Lfalse_\name
    READ O_SRC, x10
.if \immediate
    ldr x11, [x20, #O_IMM]
.else
    READ O_AUX, x11
.endif
.if \width == 32
    \instruction wzr, w10, w11
.else
    \instruction xzr, x10, x11
.endif
    FLAGS
    b Ldone_\name
Lfalse_\name:
    ldr x12, [x20, #O_AUX]
    ubfx x12, x12, #32, #4
    ldr x13, [x19, #C_FLAGS]
    bfi x13, x12, #28, #4
    str x13, [x19, #C_FLAGS]
Ldone_\name:
    NEXT
.endm
.macro CONDITIONAL width
    SELECT csel\width, csel, \width
    SELECT csinc\width, csinc, \width
    SELECT csinv\width, csinv, \width
    SELECT csneg\width, csneg, \width
    CONDITIONAL_COMPARE ccmpreg\width, subs, \width, 0
    CONDITIONAL_COMPARE ccmnreg\width, adds, \width, 0
    CONDITIONAL_COMPARE ccmpimm\width, subs, \width, 1
    CONDITIONAL_COMPARE ccmnimm\width, adds, \width, 1
.endm
.macro TAKEN
    ldr x9, [x20, #O_IMM]
    str x9, [x19, #C_PC]
    ldr x20, [x20, #O_TAKEN]
    RETIRE
.endm
HANDLER branch
    TAKEN
HANDLER link
    ldr x9, [x20, #O_PC]
    str x9, [x19, #C_LR]
    TAKEN
HANDLER bcond
    ldr x10, [x19, #C_FLAGS]
    ubfx x10, x10, #28, #4
    ldr x9, [x20, #O_AUX]
    lsr x9, x9, x10
    tbz w9, #0, Lbcond_fall
    TAKEN
Lbcond_fall: NEXT
HANDLER zero
    READ O_SRC, x10
    ldr x11, [x20, #O_AUX]
    tst x10, x11
    b.ne Lzero_fall
    TAKEN
Lzero_fall: NEXT
HANDLER nonzero
    READ O_SRC, x10
    ldr x11, [x20, #O_AUX]
    tst x10, x11
    b.eq Lnonzero_fall
    TAKEN
Lnonzero_fall: NEXT

HANDLER indirect_link
    // Capture BLR's source before updating LR, including BLR x30.
    READ O_SRC, x10
    ldr x9, [x20, #O_PC]
    str x9, [x19, #C_LR]
    b Lindirect_target
HANDLER indirect
    READ O_SRC, x10
Lindirect_target:
    str x10, [x19, #C_PC]
    add x22, x22, #1
    sub x21, x21, #1
    VALIDATE
    cbz x21, Lbudget
    ldr x10, [x19, #C_PC]
    tst x10, #3
    b.ne _ag_outside
    // Search only the owner's pinned, sorted ranges. Guest PCs never become
    // executable host pointers; chain entries are service gates.
    ldr x11, [x23, #G_TARGETS]
    cbz x11, _ag_outside
    ldr x13, [x23, #G_TARGET_COUNT]
    mov x12, #0
Lindirect_search:
    cmp x12, x13
    b.hs _ag_outside
    sub x14, x13, x12
    add x14, x12, x14, lsr #1
    mov x15, #TR_SIZE
    madd x15, x14, x15, x11
    ldr x9, [x15, #TR_BASE]
    subs x16, x10, x9
    b.lo Lindirect_left
    lsr x16, x16, #2
    ldr x9, [x15, #TR_COUNT]
    cmp x16, x9
    b.hs Lindirect_right
    ldr x20, [x15, #TR_ENTRIES]
    mov x9, #O_SIZE
    madd x20, x16, x9, x20
    DISPATCH
Lindirect_left:
    mov x13, x14
    b Lindirect_search
Lindirect_right:
    add x12, x14, #1
    b Lindirect_search

// Phase 4: ordinary scalar RAM only. This mirrors the C hot proof, with
// conservative exits for statistics, detached RAM and executable stores.
// x0 host address, x1 width/end, x2 page offset, x3 virtual page,
// x4 context, x5 TLB entry, x6 shared memory, x7 physical RAM page index.
// x10 effective VA survives until the terminal helper; x11 is scratch.
.macro MEMORY name, width, load, signed=0, result32=0, writeback=0, pair=0, bounded=0
.if \bounded
    .section __DATA,__const
    .quad _ag_\name, _ag_bounded_\name
.if !\writeback && !\pair
    .quad _ag_reg\name, _ag_regbounded_\name
.endif
    .text
.endif
// Register-offset entry shares the same proof and access body as immediates.
.if !\writeback && !\pair
.if \bounded
HANDLER regbounded_\name
.else
HANDLER reg\name
.endif
    READ O_SRC, x10
    READ O_MEM_OPERAND, x11
    ldr x12, [x20, #O_AUX]
    ubfx x13, x12, #A_EXTEND, #3
    tbnz w13, #0, Lextended\@
    tbz w13, #2, Luxtw\@
    sxtw x11, w11
    b Lextended\@
Luxtw\@:
    mov w11, w11
Lextended\@:
    ubfx x12, x12, #A_SCALE, #3
    lsl x11, x11, x12
    add x10, x10, x11
    b Laddress_\name\bounded
.endif
.if \bounded
HANDLER bounded_\name
.else
HANDLER \name
.endif
    READ O_SRC, x10
    ldr x11, [x20, #O_IMM]
    add x10, x10, x11
Laddress_\name\bounded:
    cbz x24, _ag_unsupported
    ldr x9, [x24, #M_PATH]
    cbz x9, _ag_unsupported
    ldrb w9, [x24, #M_ELIGIBLE]
    cbz w9, Lmemory_slow\bounded
    ldr x6, [x24, #M_SHARED]
    ldr x9, [x6, #R_TRANSLATION]
    ldr x11, [x24, #M_OBSERVED]
    cmp x9, x11
    b.ne Lmemory_slow\bounded
    and x2, x10, #(PAGE_SIZE - 1)
    add x1, x2, #(\width * (1 + \pair))
    cmp x1, #PAGE_SIZE
    b.hi Lmemory_slow\bounded
    lsr x3, x10, #PAGE_SHIFT
    ldp x4, x9, [x24, #M_LOW]
    cmp x10, #0
    csel x4, x4, x9, ge
    eor x9, x3, x4, lsr #PAGE_SHIFT
    and x9, x9, #HOT_MASK
.if \load
    ldr x5, [x24, #M_READ]
.else
    ldr x5, [x24, #M_WRITE]
.endif
    mov x11, #T_SIZE
    madd x5, x9, x11, x5
    ldrb w9, [x5, #T_VALID]
    cbz w9, Lmemory_slow\bounded
    ldr x9, [x5, #T_GENERATION]
    ldr x11, [x24, #M_GENERATION]
    cmp x9, x11
    b.ne Lmemory_slow\bounded
    ldrh w9, [x5, #T_SPAN]
    cmp x9, x1
    b.lo Lmemory_slow\bounded
    ldr x9, [x5, #T_VIRTUAL]
    cmp x9, x3
    b.ne Lmemory_slow\bounded
    ldr x9, [x5, #T_CONTEXT]
    cmp x9, x4
    b.ne Lmemory_slow\bounded
    ldr x0, [x5, #T_HOST]
    cbz x0, Lmemory_slow\bounded
    ldr x9, [x5, #T_PHYSICAL]
    ldr x11, [x24, #M_BASE]
    subs x9, x9, x11
    b.lo Lmemory_slow\bounded
    ldr x11, [x24, #M_SIZE]
    subs x11, x11, x9
    b.lo Lmemory_slow\bounded
    subs x11, x11, x2
    b.lo Lmemory_slow\bounded
    cmp x11, #(\width * (1 + \pair))
    b.lo Lmemory_slow\bounded
    add x7, x9, x2
    lsr x7, x7, #PAGE_SHIFT
    ldr x9, [x6, #R_PAGES]
    cmp x7, x9
    b.hs Lmemory_slow\bounded
    ldr x9, [x6, #R_FLAGS]
    cbz x9, Lmemory_slow\bounded
    add x9, x9, x7
    ldarb w9, [x9]
.if \load
    tst w9, #HOST_OBSERVER
    b.ne Lmemory_slow\bounded
.else
    cbnz w9, Lmemory_slow\bounded
    // Reject executable/unenrolled bookkeeping before writing any byte.
    ldr x9, [x6, #R_EPOCHS]
    cbz x9, Lmemory_slow\bounded
    ldr x9, [x6, #R_BITS]
    cbz x9, Lmemory_slow\bounded
    lsr x11, x7, #3
    ldrb w9, [x9, x11]
    and x11, x7, #7
    lsr w9, w9, w11
    tbnz w9, #0, Lmemory_slow\bounded
.endif
    add x0, x0, x2
.if \width > 1
    tst x0, #(\width - 1)
    b.ne Lmemory_slow\bounded
.endif
.if \load
.if \width == 1
    ldrb w10, [x0]
.elseif \width == 2
    ldrh w10, [x0]
.elseif \width == 4
    ldr w10, [x0]
.else
    ldr x10, [x0]
.endif
.if \pair
    // Separate element accesses preserve the existing non-atomic pair model.
.if \width == 4
    ldr w14, [x0, #4]
.else
    ldr x14, [x0, #8]
.endif
.endif
.if \signed
.if \width == 1
    sxtb x10, w10
.elseif \width == 2
    sxth x10, w10
.else
    sxtw x10, w10
.if \pair
    sxtw x14, w14
.endif
.endif
.if \result32
    mov w10, w10
.endif
.endif
    WRITE
.if \pair
    ldrsh x9, [x20, #O_MEM_SECOND]
    cmn x9, #1
    b.eq Lpair_loaded\@
    str x14, [x19, x9]
Lpair_loaded\@:
.endif
.else
    READ O_DST, x10
.if \pair
    READ O_MEM_SECOND, x14
.endif
.if \width == 1
    strb w10, [x0]
.elseif \width == 2
    strh w10, [x0]
.elseif \width == 4
    str w10, [x0]
.else
    str x10, [x0]
.endif
.if \pair
.if \width == 4
    str w14, [x0, #4]
.else
    str x14, [x0, #8]
.endif
.endif
    // Match C's post-store code check, including concurrent code enrollment.
    ldr x9, [x6, #R_BITS]
    lsr x11, x7, #3
    ldrb w9, [x9, x11]
    and x11, x7, #7
    lsr w9, w9, w11
    tbnz w9, #0, Lcode_commit\bounded
    // Same release dirty epoch publication and owner-local cache as C.
    ldr x10, [x6, #R_EPOCH]
    ldr x9, [x24, #M_DIRTY]
    and x11, x7, #DIRTY_MASK
    mov x12, #D_SIZE
    madd x9, x11, x12, x9
    ldrb w11, [x9, #D_VALID]
    cbz w11, Ldirty\@
    ldr x11, [x9, #D_PAGE]
    cmp x11, x7
    b.ne Ldirty\@
    ldr x11, [x9, #D_EPOCH]
    cmp x11, x10
    b.eq Ldirty_done\@
Ldirty\@:
    ldr x11, [x6, #R_EPOCHS]
    add x11, x11, x7, lsl #3
    stlr x10, [x11]
    str x7, [x9, #D_PAGE]
    str x10, [x9, #D_EPOCH]
    mov w11, #1
    strb w11, [x9, #D_VALID]
Ldirty_done\@:
    str xzr, [x19, #C_EX_ADDRESS]
    str xzr, [x19, #C_EX_GENERATION]
    strb wzr, [x19, #C_EX_SIZE]
    strb wzr, [x19, #C_EX_VALID]
.endif
.if \writeback
    // Decode-selected writeback: ordinary loads/stores pay no flag test.
    // Overlapping Rt/Rn is rejected, so the original base is still live.
    ldr x11, [x20, #O_AUX]
    ldrsh x9, [x20, #O_SRC]
    ldr x10, [x19, x9]
    sbfx x11, x11, #A_OPERAND, #16
    add x10, x10, x11
    str x10, [x19, x9]
.endif
    NEXT
.endm
.macro MEMORY_FAMILIES bounded=0
MEMORY load8, 1, 1, 0, 0, 0, 0, \bounded
MEMORY load16, 2, 1, 0, 0, 0, 0, \bounded
MEMORY load32, 4, 1, 0, 0, 0, 0, \bounded
MEMORY load64, 8, 1, 0, 0, 0, 0, \bounded
MEMORY store8, 1, 0, 0, 0, 0, 0, \bounded
MEMORY store16, 2, 0, 0, 0, 0, 0, \bounded
MEMORY store32, 4, 0, 0, 0, 0, 0, \bounded
MEMORY store64, 8, 0, 0, 0, 0, 0, \bounded
MEMORY loads8x, 1, 1, 1, 0, 0, 0, \bounded
MEMORY loads8w, 1, 1, 1, 1, 0, 0, \bounded
MEMORY loads16x, 2, 1, 1, 0, 0, 0, \bounded
MEMORY loads16w, 2, 1, 1, 1, 0, 0, \bounded
MEMORY loads32x, 4, 1, 1, 0, 0, 0, \bounded
MEMORY wbload8, 1, 1, 0, 0, 1, 0, \bounded
MEMORY wbload16, 2, 1, 0, 0, 1, 0, \bounded
MEMORY wbload32, 4, 1, 0, 0, 1, 0, \bounded
MEMORY wbload64, 8, 1, 0, 0, 1, 0, \bounded
MEMORY wbstore8, 1, 0, 0, 0, 1, 0, \bounded
MEMORY wbstore16, 2, 0, 0, 0, 1, 0, \bounded
MEMORY wbstore32, 4, 0, 0, 0, 1, 0, \bounded
MEMORY wbstore64, 8, 0, 0, 0, 1, 0, \bounded
MEMORY wbloads8x, 1, 1, 1, 0, 1, 0, \bounded
MEMORY wbloads8w, 1, 1, 1, 1, 1, 0, \bounded
MEMORY wbloads16x, 2, 1, 1, 0, 1, 0, \bounded
MEMORY wbloads16w, 2, 1, 1, 1, 1, 0, \bounded
MEMORY wbloads32x, 4, 1, 1, 0, 1, 0, \bounded
MEMORY pairload32, 4, 1, 0, 0, 0, 1, \bounded
MEMORY pairload64, 8, 1, 0, 0, 0, 1, \bounded
MEMORY pairloads32x, 4, 1, 1, 0, 0, 1, \bounded
MEMORY pairstore32, 4, 0, 0, 0, 0, 1, \bounded
MEMORY pairstore64, 8, 0, 0, 0, 0, 1, \bounded
MEMORY wbpairload32, 4, 1, 0, 0, 1, 1, \bounded
MEMORY wbpairload64, 8, 1, 0, 0, 1, 1, \bounded
MEMORY wbpairloads32x, 4, 1, 1, 0, 1, 1, \bounded
MEMORY wbpairstore32, 4, 0, 0, 0, 1, 1, \bounded
MEMORY wbpairstore64, 8, 0, 0, 0, 1, 1, \bounded
.endm
MEMORY_FAMILIES 0

Lmemory_slow0:
    mov x0, x23
    mov x1, x20
    bl _ag_memory_slow
    cmp w0, #S_MEMORY_FAULT
    b.eq Lmemory_fault
    add x22, x22, #1
    b Lrevalidate
Lmemory_fault:
    mov w9, #S_MEMORY_FAULT
    b Lreturn
Lcode_commit0:
    ldr x9, [x5, #T_PHYSICAL]
    add x2, x9, x2
    mov x0, x23
    mov x1, x20
    bl _ag_memory_commit
    add x22, x22, #1
    b Lrevalidate
// Append new families so existing handlers retain their relative offsets.
CONDITIONAL 32
CONDITIONAL 64

#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
// Keep the ordinary entry/frame and existing gadget offsets unchanged.
Lbudget_service:
    ldr x10, [x23, #G_CHAIN]
    cbz x10, Lreturn
    ldr x10, [x10, #CH_SERVICE]
    cbz x10, Lreturn
    b _ag_service_boundary
.cfi_endproc

// A separate non-alt-entry unwind range is required by Darwin's linker:
// the gadgets' alternate symbols otherwise produce a compact-unwind gap.
.p2align 2
.globl _ag_service_boundary
.private_extern _ag_service_boundary
_ag_service_boundary:
    .cfi_startproc
    .cfi_def_cfa w29, 64
    .cfi_offset w29, -64
    .cfi_offset w30, -56
    .cfi_offset w19, -48
    .cfi_offset w20, -40
    .cfi_offset w21, -32
    .cfi_offset w22, -24
    .cfi_offset w23, -16
    .cfi_offset w24, -8
    mov w9, #S_MAX
    // Full direct/fallthrough visits retain their linked gate in x20;
    // partial visits and indirect edges are resolved by the bounded C policy.
    str x20, [x23, #G_OP]
    str w9, [x23, #G_STATUS]
    str x22, [x23, #G_STEPS]
    str x22, [x23, #G_DISPATCHES]
    mov x0, x23
    // All live executor state is callee-saved or materialized in AGRun/CPU.
    // SP remains 16-byte aligned. No guest state relies on host NZCV/SIMD.
    ldr x9, [x23, #G_CHAIN]
    ldr x9, [x9, #CH_SERVICE]
    blr x9
    cbnz w0, Lvisit_load
    b Lrestore
#endif
.cfi_endproc
#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
// Bounded extensions are appended, leaving every ordinary handler unchanged.
.macro BOUNDED_FRAME
    .cfi_startproc
    .cfi_def_cfa w29, 64
    .cfi_offset w29, -64
    .cfi_offset w30, -56
    .cfi_offset w19, -48
    .cfi_offset w20, -40
    .cfi_offset w21, -32
    .cfi_offset w22, -24
    .cfi_offset w23, -16
    .cfi_offset w24, -8
.endm
.section __DATA,__const
.p2align 3
.globl _ag_bounded_memory_map
.private_extern _ag_bounded_memory_map
_ag_bounded_memory_map:
.text
.p2align 2
.globl _ag_bounded_boundary
.private_extern _ag_bounded_boundary
_ag_bounded_boundary:
    BOUNDED_FRAME
    ldr x12, [x23, #G_CHAIN]
    ldr x9, [x12, #CH_EVENTS]
    cbz x9, Lbounded_proofs
    ldar x9, [x9]
    cbnz x9, Lbounded_event
Lbounded_proofs:
    VALIDATE
    ldr x13, [x12, #BC_PROOFS]
    ldr x14, [x12, #BC_COUNT]
Lbounded_proof:
    ldp x15, x17, [x13, #BP_SERIAL]
    ldr x16, [x15]
    cmp x16, x17
    b.ne Lrevalidate
    ldp x15, x17, [x13, #BP_LOCAL]
    cbz x15, Lbounded_shared
    ldr x16, [x15]
    cmp x16, x17
    b.ne Lrevalidate
Lbounded_shared:
    ldp x15, x17, [x13, #BP_SHARED]
    cbz x15, Lbounded_next_proof
    ldar x16, [x15]
    cmp x16, x17
    b.ne Lrevalidate
Lbounded_next_proof:
    add x13, x13, #BP_SIZE
    subs x14, x14, #1
    b.ne Lbounded_proof
    ldr x9, [x12, #CH_REMAINING]
    cbz x9, Lchain_yield
    sub x9, x9, #1
    str x9, [x12, #CH_REMAINING]
    ldr x9, [x12, #CH_ENTRIES]
    add x9, x9, #1
    str x9, [x12, #CH_ENTRIES]
    ldr x9, [x12, #BC_LAST]
    str x9, [x12, #BC_PREVIOUS]
    ldr x9, [x20, #O_IMM]
    str x9, [x12, #BC_LAST]
    str x22, [x12, #BC_START]
    ldr x20, [x20, #O_TAKEN]
    DISPATCH
Lbounded_event:
    mov w9, #BC_EVENT
    str w9, [x12, #BC_STOP]
    b Lchain_yield

MEMORY_FAMILIES 1
Lcode_commit1:
    // Bytes already changed. Finish publication and writeback unconditionally;
    // service can only run after this terminal operation has fully retired.
    ldr x9, [x23, #G_CHAIN]
    mov w11, #1
    str w11, [x9, #BC_TERMINAL]
    b Lcode_commit0
    .cfi_endproc
.section __DATA,__const
.globl _ag_bounded_memory_map_end
.private_extern _ag_bounded_memory_map_end
_ag_bounded_memory_map_end:
.text

// Use a non-alt-entry unwind range for the sole new resident C call.
.p2align 2
.globl _ag_bounded_memory_slow
.private_extern _ag_bounded_memory_slow
_ag_bounded_memory_slow:
    BOUNDED_FRAME
Lmemory_slow1:
    str x20, [x23, #G_OP]
    str x22, [x23, #G_STEPS]
    str x22, [x23, #G_DISPATCHES]
    mov w9, #S_MAX
    str w9, [x23, #G_STATUS]
    mov x0, x23
    bl _ag_bounded_before_helper
    cbnz w0, Lmemory_slow0
    ldr w9, [x23, #G_STATUS]
    b Lreturn
    .cfi_endproc
#endif
#endif
.globl _ag_code_end
.private_extern _ag_code_end
_ag_code_end:
