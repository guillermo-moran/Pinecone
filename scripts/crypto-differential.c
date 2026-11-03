#include "ARM64VizCrypto.h"
#include <stdio.h>

static uint64_t seed = 0x72133748;

static uint32_t next_word(void) {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return (uint32_t)seed;
}

int main(void) {
#if !defined(__aarch64__) || !defined(__ARM_FEATURE_SHA2)
    fprintf(stderr, "This differential test requires host ARM64 SHA2 instructions.\n");
    return 77;
#else
    unsigned tests = 0;
    for (unsigned mode = 0; mode < 4; mode++) {
        for (unsigned alias = 0; alias < 5; alias++) {
            for (unsigned k = 0; k < 10000; k++) {
                uint32_t hardware[3][4], portable[3][4];
                for (unsigned i = 0; i < 3; i++)
                    for (unsigned j = 0; j < 4; j++)
                        hardware[i][j] = next_word();
                memcpy(portable, hardware, sizeof(hardware));
                unsigned n = alias == 1 || alias == 3 ? 0 : 1;
                unsigned m = alias == 2 || alias == 3 ? 0 : alias == 4 ? 1 : 2;
                avz_sha256(hardware[0], hardware[n], hardware[m], mode);
                avz_sha256_portable(portable[0], portable[n], portable[m], mode);
                if (memcmp(hardware, portable, sizeof(hardware))) {
                    fprintf(stderr, "FAIL mode %u alias %u case %u\n", mode, alias, k);
                    return 1;
                }
                tests++;
            }
        }
    }
    printf("PASS %u host SHA256 / portable differential cases\n", tests);
    return 0;
#endif
}
