#include "offsets.h"
.text
.p2align 2
.globl _ag_abi_probe
// Returns a bitmask: GPR=1, ABI-preserved d8-d15=2, FP=4, stack/frame=8.
_ag_abi_probe:
    .cfi_startproc
    stp x29, x30, [sp, #-256]!
    .cfi_def_cfa_offset 256
    .cfi_offset w29, -256
    .cfi_offset w30, -248
    mov x29, sp
    .cfi_def_cfa w29, 256
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    .cfi_offset w19, -240
    .cfi_offset w20, -232
    .cfi_offset w21, -224
    .cfi_offset w22, -216
    .cfi_offset w23, -208
    .cfi_offset w24, -200
    .cfi_offset w25, -192
    .cfi_offset w26, -184
    .cfi_offset w27, -176
    .cfi_offset w28, -168
    str x0, [sp, #96]
    mov x9, sp
    str x9, [sp, #104]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [sp, #112]
    stp q8, q9, [sp, #128]
    stp q10, q11, [sp, #160]
    stp q12, q13, [sp, #192]
    stp q14, q15, [sp, #224]
    mov x19, #19
    mov x20, #20
    mov x21, #21
    mov x22, #22
    mov x23, #23
    mov x24, #24
    mov x25, #25
    mov x26, #26
    mov x27, #27
    mov x28, #28
    movi v8.16b, #8
    movi v9.16b, #9
    movi v10.16b, #10
    movi v11.16b, #11
    movi v12.16b, #12
    movi v13.16b, #13
    movi v14.16b, #14
    movi v15.16b, #15
    bl _ag_enter
    mov x0, #0
.macro CHECK_GPR reg, expected
    cmp \reg, #\expected
    cset x9, ne
    orr x0, x0, x9
.endm
    CHECK_GPR x19, 19
    CHECK_GPR x20, 20
    CHECK_GPR x21, 21
    CHECK_GPR x22, 22
    CHECK_GPR x23, 23
    CHECK_GPR x24, 24
    CHECK_GPR x25, 25
    CHECK_GPR x26, 26
    CHECK_GPR x27, 27
    CHECK_GPR x28, 28
.macro CHECK_VEC reg, expected
    movi v0.16b, #\expected
    cmeq v0.16b, v0.16b, \reg\().16b
    uminv b0, v0.8b
    umov w9, v0.b[0]
    cmp w9, #255
    cset x9, ne
    orr x0, x0, x9, lsl #1
.endm
    CHECK_VEC v8, 8
    CHECK_VEC v9, 9
    CHECK_VEC v10, 10
    CHECK_VEC v11, 11
    CHECK_VEC v12, 12
    CHECK_VEC v13, 13
    CHECK_VEC v14, 14
    CHECK_VEC v15, 15
    ldp x9, x10, [sp, #112]
    mrs x11, fpcr
    mrs x12, fpsr
    eor x11, x11, x9
    eor x12, x12, x10
    orr x11, x11, x12
    cmp x11, #0
    cset x11, ne
    orr x0, x0, x11, lsl #2
    msr fpcr, x9
    msr fpsr, x10
    ldr x9, [sp, #104]
    mov x10, sp
    cmp x9, x10
    cset x11, ne
    cmp x29, x10
    cset x12, ne
    orr x11, x11, x12
    orr x0, x0, x11, lsl #3
    ldp q8, q9, [sp, #128]
    ldp q10, q11, [sp, #160]
    ldp q12, q13, [sp, #192]
    ldp q14, q15, [sp, #224]
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #256
    .cfi_def_cfa sp, 0
    .cfi_restore w19
    .cfi_restore w20
    .cfi_restore w21
    .cfi_restore w22
    .cfi_restore w23
    .cfi_restore w24
    .cfi_restore w25
    .cfi_restore w26
    .cfi_restore w27
    .cfi_restore w28
    .cfi_restore w29
    .cfi_restore w30
    ret
    .cfi_endproc

// Deliberately clobber volatile state in a normal C-ABI callback. Upper halves
// of v8-v15 are volatile too; only d8-d15 must survive a helper call.
.globl _ag_clobber_volatile
_ag_clobber_volatile:
.irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17
    mov x\n, #0xdead
.endr
.irp n,0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    movi v\n\().16b, #0xed
.endr
.irp n,8,9,10,11,12,13,14,15
    ins v\n\().d[1], x9
.endr
    cmp x9, #0
    ret
