#include <stdio.h>
#include <string.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static size_t cases;
static void check(uint32_t word, uint64_t bits) {
    AVZNativeInstruction decoded;
    CHECK(avz_native_decode_instruction(word, &decoded));
    AGProgram *p = ag_create(&word, 1, 0x8000);
    CHECK(p && ag_program_capabilities(p) == 1);
    for (unsigned rounding = 0; rounding < 4; rounding++)
    for (unsigned budget = 0; budget < 2; budget++)
    for (unsigned stale = 0; stale < 2; stale++) {
        AVZNativeCPU actual = {.pc = 0x8000, .sp = UINT64_MAX,
            .pstate = 0xa00003c5, .fpcr = (rounding << 22) | (3u << 24),
            .fpsr = 0x0800009f};
        for (unsigned i = 0; i < 31; i++) actual.x[i] = bits ^ (i * UINT64_C(0x100000001));
        for (unsigned i = 0; i < 32; i++) actual.v[i] = (AVZNativeVectorRegister){bits,
            bits ^ UINT64_C(0x123456789abcdef0)};
        AVZNativeCPU expected = actual;
        uint64_t epoch = stale;
        AGGuards guards = {.local = &epoch};
        uint64_t fpcr_before, fpsr_before, fpcr_after, fpsr_after;
        __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(fpcr_before), "=r"(fpsr_before));
        AVZNativeBlockResult result = ag_run(p, budget, &actual, &guards);
        __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(fpcr_after), "=r"(fpsr_after));
        CHECK(fpcr_before == fpcr_after && fpsr_before == fpsr_after);
        if (budget && !stale) CHECK(execute_decoded_instruction(&decoded, &expected,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL));
        CHECK(result.steps == (budget && !stale));
        CHECK(!memcmp(&actual, &expected, sizeof(actual)));
        cases++;
    }
    ag_destroy(p);
}
int main(void) {
    const uint64_t values[] = {0, UINT64_MAX, UINT64_C(0x8000000080000000),
        UINT64_C(0x7ff000007f800000), UINT64_C(0x7ff000017f800001),
        UINT64_C(0x7ffabcde7fc12345), UINT64_C(0x0000000000000001)};
    const uint32_t bases[] = {0x1e270000, 0x1e260000, 0x9e670000, 0x9e660000,
        0x9eaf0000, 0x9eae0000, 0x1e204000, 0x1e604000};
    const unsigned registers[] = {0, 1, 31};
    for (size_t op = 0; op < sizeof(bases) / sizeof(*bases); op++)
    for (size_t source = 0; source < 3; source++)
    for (size_t destination = 0; destination < 3; destination++)
    for (size_t value = 0; value < sizeof(values) / sizeof(*values); value++)
        check(bases[op] | (registers[source] << 5) | registers[destination], values[value]);
    for (unsigned wide = 0; wide < 2; wide++)
    for (unsigned imm = 0; imm < 256; imm++)
    for (size_t destination = 0; destination < 3; destination++)
        check((wide ? 0x1e601000 : 0x1e201000) | (imm << 13) |
            registers[destination], UINT64_MAX);
    printf("assembly FP moves: %zu differential cases passed; host FPCR/FPSR preserved\n", cases);
    return 0;
}
