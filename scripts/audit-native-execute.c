#include "ARM64VizNative.h"

#include <inttypes.h>
#include <stdio.h>

static uint64_t mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= UINT64_C(0x100000001b3);
    hash ^= hash >> 32;
    return hash;
}

static uint64_t execute_hash(
    uint64_t address,
    uint32_t raw,
    unsigned seed,
    const AVZNativeInstruction *instruction,
    AVZNativeBlockResult *result_out
) {
    uint64_t x[31];
    uint64_t vector_low[32];
    uint64_t vector_high[32];
    for (unsigned index = 0; index < 31; index++) {
        x[index] = UINT64_C(0x1020304050607080) ^
            ((uint64_t)raw << (index & 15u)) ^
            ((uint64_t)(index + 1u) * UINT64_C(0x9e3779b97f4a7c15)) ^ seed;
    }
    for (unsigned index = 0; index < 32; index++) {
        vector_low[index] = UINT64_C(0x0123456789abcdef) ^
            ((uint64_t)raw * (index + 3u)) ^ seed;
        vector_high[index] = UINT64_C(0xfedcba9876543210) ^
            ((uint64_t)raw * (index + 37u)) ^ ((uint64_t)seed << 32);
    }

    uint64_t sp = UINT64_C(0x000000007fff0000) + seed * 0x1000u;
    uint64_t pc = address;
    uint64_t pstate = ((uint64_t)(seed & 15u) << 28);
    uint64_t fpcr = seed << 22;
    uint64_t fpsr = seed;
    uint64_t exclusive_address = 0;
    uint8_t exclusive_size = 0;
    uint8_t exclusive_valid = 0;
    uint8_t halted = 0;

    AVZNativeInstruction decoded = *instruction;
    AVZNativeBlockResult result =
        avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
            &decoded,
            1,
            address,
            1,
            x,
            vector_low,
            vector_high,
            &sp,
            &pc,
            &pstate,
            &fpcr,
            &fpsr,
            &exclusive_address,
            &exclusive_size,
            &exclusive_valid,
            &halted,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL
        );

    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    for (unsigned index = 0; index < 31; index++) {
        hash = mix(hash, x[index]);
    }
    for (unsigned index = 0; index < 32; index++) {
        hash = mix(hash, vector_low[index]);
        hash = mix(hash, vector_high[index]);
    }
    hash = mix(hash, sp);
    hash = mix(hash, pc);
    hash = mix(hash, pstate);
    hash = mix(hash, fpcr);
    hash = mix(hash, fpsr);
    hash = mix(hash, exclusive_address);
    hash = mix(hash, exclusive_size);
    hash = mix(hash, exclusive_valid);
    hash = mix(hash, halted);
    hash = mix(hash, result.steps);
    hash = mix(hash, result.generic_dispatches);
    hash = mix(hash, result.status);
    hash = mix(hash, result.unsupported_instruction);
    *result_out = result;
    return hash;
}

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
            "%016" PRIx64 " %08" PRIx32 " kind=%u",
            address,
            raw,
            decoded.kind
        );
        for (unsigned seed = 0; seed < 4; seed++) {
            AVZNativeBlockResult result;
            uint64_t hash = execute_hash(address, raw, seed, &decoded, &result);
            printf(
                " s%u=%u/%" PRIu64 "/%016" PRIx64,
                seed,
                result.status,
                result.steps,
                hash
            );
        }
        putchar('\n');
    }
    return ferror(stdin) ? 1 : 0;
}
