#define main audit_native_memory_single_main
#include "audit-native-memory-execute.c"
#undef main

#define AUDIT_BLOCK_INSTRUCTIONS 16u

static uint64_t execute_block_hash(
    uint64_t address,
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    unsigned seed,
    AVZNativeBlockResult *result_out
) {
    uint64_t x[31];
    uint64_t vector_low[32];
    uint64_t vector_high[32];
    for (unsigned index = 0; index < 31; index++) {
        x[index] = UINT64_C(0x1020304050607080) ^
            ((uint64_t)instructions[0].raw << (index & 15u)) ^
            ((uint64_t)(index + 1u) * UINT64_C(0x9e3779b97f4a7c15)) ^ seed;
    }
    for (unsigned index = 0; index < 32; index++) {
        vector_low[index] = UINT64_C(0x0123456789abcdef) ^
            ((uint64_t)instructions[0].raw * (index + 3u)) ^ seed;
        vector_high[index] = UINT64_C(0xfedcba9876543210) ^
            ((uint64_t)instructions[0].raw * (index + 37u)) ^
            ((uint64_t)seed << 32);
    }

    uint64_t sp = UINT64_C(0x000000007fff0000) + seed * 0x1000u;
    uint64_t pc = address;
    uint64_t pstate = ((uint64_t)(seed & 15u) << 28);
    uint64_t fpcr = seed << 22;
    uint64_t fpsr = seed;
    uint64_t exclusive_address = x[instructions[0].rn % 31u];
    uint8_t exclusive_size = instructions[0].width;
    uint8_t exclusive_valid = (uint8_t)(seed & 1u);
    uint8_t halted = 0;
    AuditMemory memory = {
        .hash = UINT64_C(0xcbf29ce484222325),
        .reads = 0,
        .writes = 0,
        .access_checks = 0,
        .fills = 0
    };

    AVZNativeBlockResult result =
        avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
            instructions,
            instruction_count,
            address,
            64,
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
            audit_read,
            audit_write,
            audit_can_access,
            audit_fill,
            audit_system_read,
            audit_system_write,
            audit_system_instruction,
            audit_exception_return,
            audit_synchronous_exception,
            audit_wait,
            &memory
        );

    uint64_t hash = memory.hash;
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
    hash = mix(hash, memory.reads);
    hash = mix(hash, memory.writes);
    hash = mix(hash, memory.access_checks);
    hash = mix(hash, memory.fills);
    hash = mix(hash, result.steps);
    hash = mix(hash, result.generic_dispatches);
    hash = mix(hash, result.status);
    hash = mix(hash, result.unsupported_instruction);
    *result_out = result;
    return hash;
}

int main(void) {
    AVZNativeInstruction instructions[AUDIT_BLOCK_INSTRUCTIONS];
    uint64_t first_address = 0;
    uint32_t first_raw = 0;
    size_t count = 0;
    int supported = 1;
    uint64_t address;
    uint32_t raw;

    while (scanf("%" SCNx64 " %" SCNx32, &address, &raw) == 2) {
        if (count == 0) {
            first_address = address;
            first_raw = raw;
            supported = 1;
        }
        if (!avz_native_decode_instruction(raw, &instructions[count])) {
            supported = 0;
        }
        count++;
        if (count != AUDIT_BLOCK_INSTRUCTIONS) {
            continue;
        }

        printf("%016" PRIx64 " %08" PRIx32, first_address, first_raw);
        if (!supported) {
            puts(" unsupported");
        } else {
            for (unsigned seed = 0; seed < 4; seed++) {
                AVZNativeBlockResult result;
                uint64_t hash = execute_block_hash(
                    first_address,
                    instructions,
                    count,
                    seed,
                    &result
                );
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
        count = 0;
    }
    return ferror(stdin) ? 1 : 0;
}
