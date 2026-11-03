/* Bit-preserving FP transfers only: no host floating-point state is used. */
#ifndef AG_FP_MOVES_H
#define AG_FP_MOVES_H
_Static_assert(offsetof(AVZNativeCPU, v) + sizeof(((AVZNativeCPU *)0)->v) <= INT16_MAX,
    "vector register offsets must fit the assembly signed READ operand");
extern void ag_fp_read32(void), ag_fp_read64(void);
extern void ag_fp_write32(void), ag_fp_write64(void), ag_fp_immediate(void);

static uint16_t ag_vector_offset(unsigned reg, unsigned high) {
    return (uint16_t)(offsetof(AVZNativeCPU, v) +
        reg * sizeof(AVZNativeVectorRegister) + high * sizeof(uint64_t));
}
static void ag_prepare_fp_move(AGOperation *op, const AVZNativeInstruction *d) {
    switch (d->kind) {
    case AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE:
        switch (d->flags) {
        case 0: case 2: case 4:
            op->source = reg_offset(d->rn, 0);
            op->destination = ag_vector_offset(d->rd, d->flags == 4);
            op->handler = d->flags == 0 ? ag_fp_write32 :
                d->flags == 2 ? ag_fp_write64 : ag_fp_read64;
            break;
        case 1: case 3: case 5:
            op->source = ag_vector_offset(d->rn, d->flags == 5);
            op->destination = reg_offset(d->rd, 0);
            op->handler = d->flags == 1 ? ag_fp_read32 : ag_fp_read64;
            break;
        }
        break;
    case AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE:
        if (d->flags > 1) break;
        op->source = ag_vector_offset(d->rn, 0);
        op->destination = ag_vector_offset(d->rd, 0);
        op->handler = d->flags ? ag_fp_write64 : ag_fp_write32;
        break;
    case AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE: {
        if (d->flags > 1 || (uint64_t)d->immediate > 255) break;
        uint64_t imm = (uint64_t)d->immediate;
        uint64_t repeated = (imm >> 6) & 1;
        uint64_t exponent = ((repeated ^ 1) << (d->flags ? 10 : 7)) |
            (repeated ? (d->flags ? 0x3fc : 0x7c) : 0) | ((imm >> 4) & 3);
        op->immediate = ((imm >> 7) << (d->flags ? 63 : 31)) |
            (exponent << (d->flags ? 52 : 23)) | ((imm & 15) << (d->flags ? 48 : 19));
        op->destination = ag_vector_offset(d->rd, 0);
        op->handler = ag_fp_immediate;
        break;
    }
    default: break;
    }
}
#endif
