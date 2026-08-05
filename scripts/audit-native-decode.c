#include "ARM64VizNative.h"

#include <inttypes.h>
#include <stdio.h>

int main(void) {
    uint64_t address;
    uint32_t raw;

    while (scanf("%" SCNx64 " %" SCNx32, &address, &raw) == 2) {
        AVZNativeInstruction decoded;
        if (!avz_native_decode_instruction(raw, &decoded)) {
            printf("%016" PRIx64 " %08" PRIx32 " unsupported\n", address, raw);
            continue;
        }
        printf(
            "%016" PRIx64 " %08" PRIx32
            " kind=%u rd=%u rn=%u rm=%u rt=%u width=%u bits=%u flags=%u\n",
            address,
            raw,
            decoded.kind,
            decoded.rd,
            decoded.rn,
            decoded.rm,
            decoded.rt,
            decoded.width,
            decoded.bits,
            decoded.flags
        );
    }
    return ferror(stdin) ? 1 : 0;
}
