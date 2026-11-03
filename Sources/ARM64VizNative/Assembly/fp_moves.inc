// Included by gadget_arm64.S after its handler/retirement macros. All data
// moves use integer registers: NaN payloads and host FPCR/FPSR remain intact.
HANDLER fp_read32
    READ O_SRC, x10
    mov w10, w10
    WRITE
    NEXT
HANDLER fp_read64
    READ O_SRC, x10
    WRITE
    NEXT
HANDLER fp_write32
    READ O_SRC, x10
    mov w10, w10
    b Lfp_write
HANDLER fp_write64
    READ O_SRC, x10
    b Lfp_write
HANDLER fp_immediate
    ldr x10, [x20, #O_IMM]
Lfp_write:
    ldrh w9, [x20, #O_DST]
    add x9, x19, x9
    stp x10, xzr, [x9]
    NEXT
