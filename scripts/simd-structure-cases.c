#include "ARM64VizNative.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

static void emit(uint32_t raw)
{
    AVZNativeInstruction decoded;
    if (!avz_native_decode_instruction(raw, &decoded)) {
        fprintf(stderr, "cannot decode %08" PRIx32 "\n", raw);
        exit(EXIT_FAILURE);
    }
    printf("8000 %08" PRIx32 " kind=%u rd=%u rn=%u rm=%u rt=%u width=%u bits=%u flags=%u\n",
           raw, decoded.kind, decoded.rd, decoded.rn, decoded.rm,
           decoded.rt, decoded.width, decoded.bits, decoded.flags);
}

int main(int argc, char **argv)
{
    (void)argv;
    if (argc > 1) {
        for (unsigned size = 0; size < 4; size++)
        for (unsigned q = 0; q < 2; q++) {
            if (size == 3 && q == 0) continue;
            for (unsigned lane = 0; lane < (16u >> size); lane++) {
                unsigned imm5 = (1u << size) | (lane << (size + 1));
                emit(UINT32_C(0x0e000400) | (q << 30) | (imm5 << 16) |
                     (31u << 5) | 31u);
            }
        }
        return 0;
    }
    for (unsigned count = 1; count <= 4; count++)
    for (unsigned size = 0; size < 4; size++)
    for (unsigned q = 0; q < 2; q++)
    for (unsigned mode = 0; mode < 3; mode++) {
        uint32_t common = UINT32_C(0x0d000000) | 31u | (3u << 5) |
            (q << 30) | (((count - 1) & 1u) << 21) |
            (((count - 1) >> 1) << 13);
        if (mode != 0)
            common |= (1u << 23) | ((mode == 1 ? 31u : 4u) << 16);
        emit(common | (1u << 22) | (6u << 13) | (size << 10));
        unsigned opcode = size == 0 ? 0 : size == 1 ? 2 : 4;
        unsigned encoded_size = size == 0 ? 3 : size == 1 ? 2 : size == 2 ? 0 : 1;
        unsigned s = size == 3 ? 0 : 1;
        for (unsigned load = 0; load < 2; load++)
            emit(common | (load << 22) | (opcode << 13) |
                 (s << 12) | (encoded_size << 10));
    }
    return 0;
}
