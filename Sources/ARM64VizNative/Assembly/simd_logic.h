/* Integer SIMD only: these operations do not change FPCR/FPSR. */
#ifndef AG_SIMD_LOGIC_H
#define AG_SIMD_LOGIC_H
#define AG_DECLARE_SIMD(name) extern void ag_simd_##name##64(void), ag_simd_##name##128(void)
AG_DECLARE_SIMD(orr); AG_DECLARE_SIMD(eor); AG_DECLARE_SIMD(bsl);
AG_DECLARE_SIMD(bit); AG_DECLARE_SIMD(bif); AG_DECLARE_SIMD(and);
AG_DECLARE_SIMD(bic); AG_DECLARE_SIMD(orn); AG_DECLARE_SIMD(not);
#undef AG_DECLARE_SIMD
static void ag_prepare_simd_logic(AGOperation *op, const AVZNativeInstruction *d) {
    static const AGHandler handlers[][2] = {
        {ag_simd_orr64, ag_simd_orr128}, {ag_simd_eor64, ag_simd_eor128},
        {ag_simd_bsl64, ag_simd_bsl128}, {ag_simd_bit64, ag_simd_bit128},
        {ag_simd_bif64, ag_simd_bif128}, {ag_simd_and64, ag_simd_and128},
        {ag_simd_bic64, ag_simd_bic128}, {ag_simd_orn64, ag_simd_orn128},
        {ag_simd_not64, ag_simd_not128}
    };
    unsigned operation = d->kind == AVZ_NATIVE_OP_SIMD_BITWISE_NOT ? 8 : d->flags >> 1;
    if ((d->kind == AVZ_NATIVE_OP_SIMD_ORR_VECTOR && operation > 7) ||
        (d->kind == AVZ_NATIVE_OP_SIMD_BITWISE_NOT && d->flags > 1)) return;
    op->source = ag_vector_offset(d->rn, 0);
    op->destination = ag_vector_offset(d->rd, 0);
    op->auxiliary = ag_vector_offset(d->rm, 0);
    op->handler = handlers[operation][d->flags & 1];
}
#endif
