/* Synthetic workloads, NOT imported Bionic/ART code. Static text only: no JIT. */
#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif
.text
.p2align 2
.macro BEGIN name
    .globl SYM(\name)
SYM(\name):
.endm
.macro END name
    .globl SYM(\name\()_end)
SYM(\name\()_end):
.endm

BEGIN av_strlen
    mov x1, x0
1:  ldrb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, x0
    sub x0, x0, #1
    ret
END av_strlen

BEGIN av_copy
    cbz x2, 4f
1:  cmp x2, #16
    b.lo 3f
    ldr q0, [x1], #16
    str q0, [x0], #16
    sub x2, x2, #16
    cbnz x2, 1b
    ret
3:  ldrb w3, [x1], #1
    strb w3, [x0], #1
    subs x2, x2, #1
    b.ne 3b
4:  ret
END av_copy

BEGIN av_move
    cbz x2, 4f
    cmp x0, x1
    b.ls 3f
    add x0, x0, x2
    add x1, x1, x2
1:  ldrb w3, [x1, #-1]!
    strb w3, [x0, #-1]!
    subs x2, x2, #1
    b.ne 1b
    ret
3:  ldrb w3, [x1], #1
    strb w3, [x0], #1
    subs x2, x2, #1
    b.ne 3b
4:  ret
END av_move

BEGIN av_compare
    cbz x2, 3f
1:  ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    subs w5, w3, w4
    b.ne 2f
    subs x2, x2, #1
    b.ne 1b
3:  mov w5, #0
2:  mov w0, w5
    ret
END av_compare

BEGIN av_increment
1:  ldaxr x1, [x0]
    add x1, x1, #1
    stlxr w2, x1, [x0]
    cbnz w2, 1b
    ret
END av_increment

BEGIN av_pair_words
    ldaxp x1, x2, [x0]
    stlxp w3, x1, x2, [x0]
    ret
END av_pair_words

/* All FP reference state is saved/restored, including the host's sticky flags.
 * Only the labeled single instruction is submitted to the interpreter. */
.macro FP_BEGIN name
    BEGIN \name
    ldr q1, [x0]
    ldr q2, [x1]
    movi v0.16b, #255
    mrs x9, fpcr
    mrs x10, fpsr
    msr fpcr, x3
    msr fpsr, x4
    .globl SYM(\name\()_op)
SYM(\name\()_op):
.endm
.macro FP_END name
    str q0, [x2]
    mrs x0, fpsr
    msr fpcr, x9
    msr fpsr, x10
    ret
.endm
FP_BEGIN av_fadd
    fadd d0, d1, d2
FP_END av_fadd
FP_BEGIN av_fdiv
    fdiv d0, d1, d2
FP_END av_fdiv
FP_BEGIN av_vfadd
    fadd v0.4s, v1.4s, v2.4s
FP_END av_vfadd
FP_BEGIN av_cmeq
    cmeq v0.16b, v1.16b, v2.16b
FP_END av_cmeq
FP_BEGIN av_umaxv
    umaxv b0, v1.16b
FP_END av_umaxv
FP_BEGIN av_uqadd
    uqadd v0.16b, v1.16b, v2.16b
FP_END av_uqadd
