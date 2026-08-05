#include "ARM64VizNative.h"

#include <inttypes.h>
#include <stdio.h>

typedef struct {
    uint64_t hash;
    uint64_t reads;
    uint64_t writes;
    uint64_t access_checks;
    uint64_t fills;
} AuditMemory;

static uint64_t mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= UINT64_C(0x100000001b3);
    hash ^= hash >> 32;
    return hash;
}

static uint64_t width_mask(uint8_t width) {
    return width >= 8 ? UINT64_MAX : (UINT64_C(1) << (width * 8u)) - 1u;
}

static int audit_read(
    void *opaque,
    uint64_t address,
    uint8_t width,
    uint64_t *value
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || value == NULL || width == 0 || width > 8) {
        return 0;
    }
    uint64_t loaded = mix(
        UINT64_C(0x6a09e667f3bcc909),
        address ^ ((uint64_t)width << 56)
    ) & width_mask(width);
    *value = loaded;
    memory->hash = mix(memory->hash, UINT64_C(0x1000000000000000) | width);
    memory->hash = mix(memory->hash, address);
    memory->hash = mix(memory->hash, loaded);
    memory->reads++;
    return 1;
}

static int audit_write(
    void *opaque,
    uint64_t address,
    uint8_t width,
    uint64_t value
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || width == 0 || width > 8) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0x2000000000000000) | width);
    memory->hash = mix(memory->hash, address);
    memory->hash = mix(memory->hash, value & width_mask(width));
    memory->writes++;
    return 1;
}

static int audit_can_access(
    void *opaque,
    uint64_t address,
    uint8_t width,
    uint8_t is_write
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || width == 0 || width > 8) {
        return 0;
    }
    memory->hash = mix(
        memory->hash,
        UINT64_C(0x3000000000000000) |
            ((uint64_t)is_write << 8) | width
    );
    memory->hash = mix(memory->hash, address);
    memory->access_checks++;
    return 1;
}

static int audit_fill(
    void *opaque,
    uint64_t address,
    uint64_t byte_count,
    uint64_t pattern,
    uint8_t pattern_width
) {
    AuditMemory *memory = opaque;
    if (memory == NULL) {
        return 0;
    }
    memory->hash = mix(
        memory->hash,
        UINT64_C(0x4000000000000000) | pattern_width
    );
    memory->hash = mix(memory->hash, address);
    memory->hash = mix(memory->hash, byte_count);
    memory->hash = mix(memory->hash, pattern);
    memory->fills++;
    return 1;
}

static int audit_system_read(
    void *opaque,
    uint32_t instruction,
    uint64_t pc,
    uint64_t pstate,
    uint64_t sp,
    uint64_t *value
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || value == NULL) {
        return 0;
    }
    *value = mix(pc ^ pstate, sp ^ instruction);
    memory->hash = mix(memory->hash, UINT64_C(0x5000000000000000));
    memory->hash = mix(memory->hash, instruction);
    memory->hash = mix(memory->hash, *value);
    return 1;
}

static int audit_system_write(
    void *opaque,
    uint32_t instruction,
    uint64_t pc,
    uint64_t value,
    uint64_t *pstate,
    uint64_t *sp
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || pstate == NULL || sp == NULL) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0x6000000000000000));
    memory->hash = mix(memory->hash, instruction);
    memory->hash = mix(memory->hash, pc);
    memory->hash = mix(memory->hash, value);
    return 1;
}

static int audit_system_instruction(
    void *opaque,
    uint32_t instruction,
    uint64_t operand
) {
    AuditMemory *memory = opaque;
    if (memory == NULL) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0x7000000000000000));
    memory->hash = mix(memory->hash, instruction);
    memory->hash = mix(memory->hash, operand);
    return 1;
}

static int audit_exception_return(
    void *opaque,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || pstate == NULL || sp == NULL || pc == NULL) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0x8000000000000000));
    *pstate ^= UINT64_C(0x3c0);
    *sp += UINT64_C(0x80);
    *pc += UINT64_C(0x1000);
    return 1;
}

static int audit_synchronous_exception(
    void *opaque,
    uint32_t instruction,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AuditMemory *memory = opaque;
    if (memory == NULL || pstate == NULL || sp == NULL || pc == NULL) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0x9000000000000000));
    memory->hash = mix(memory->hash, instruction);
    *pstate |= UINT64_C(0x3c0);
    *sp -= UINT64_C(0x80);
    *pc += UINT64_C(0x800);
    return 1;
}

static int audit_wait(void *opaque, uint32_t instruction, uint64_t *pc) {
    AuditMemory *memory = opaque;
    if (memory == NULL || pc == NULL) {
        return 0;
    }
    memory->hash = mix(memory->hash, UINT64_C(0xa000000000000000));
    memory->hash = mix(memory->hash, instruction);
    *pc += 4;
    return 1;
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
    uint64_t exclusive_address = x[instruction->rn % 31u];
    uint8_t exclusive_size = instruction->width;
    uint8_t exclusive_valid = (uint8_t)(seed & 1u);
    uint8_t halted = 0;
    AuditMemory memory = {
        .hash = UINT64_C(0xcbf29ce484222325),
        .reads = 0,
        .writes = 0,
        .access_checks = 0,
        .fills = 0
    };

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
