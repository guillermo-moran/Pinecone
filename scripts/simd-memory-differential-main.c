#include "ARM64VizNative.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    MEMORY_SIZE = 4096,
    OPERAND_OFFSET = 1024,
    SEED_COUNT = 8
};

static const uint64_t RAM_BASE = UINT64_C(0x100000);

typedef void (*HostSIMDMemoryCase)(
    const AVZNativeVectorRegister *input,
    uint8_t *memory_base,
    AVZNativeVectorRegister *output,
    uint64_t *base_after,
    uint64_t post_index
);

typedef struct {
    uint32_t opcode;
    uint16_t expected_kind;
    HostSIMDMemoryCase execute;
} SIMDMemoryCase;

#include "simd-memory-differential-cases.inc"

typedef struct {
    uint8_t bytes[MEMORY_SIZE];
} CallbackMemory;

static uint64_t rotate_left(uint64_t value, unsigned amount) {
    amount &= 63u;
    if (amount == 0u) {
        return value;
    }
    return (value << amount) | (value >> (64u - amount));
}

static void initialize_vectors(AVZNativeVectorRegister *vectors, unsigned seed) {
    for (unsigned reg = 0; reg < 32; reg++) {
        uint64_t low = UINT64_C(0x0123456789abcdef) ^
            ((uint64_t)(seed + 1u) * UINT64_C(0x1111111111111111));
        uint64_t high = UINT64_C(0xfedcba9876543210) ^
            ((uint64_t)(reg + 3u) * UINT64_C(0x0102040810204081));
        vectors[reg].low = rotate_left(low, reg * 3u + seed * 7u);
        vectors[reg].high = rotate_left(high, reg * 5u + seed * 11u);
    }
}

static void initialize_memory(uint8_t *memory, unsigned seed) {
    for (size_t index = 0; index < MEMORY_SIZE; index++) {
        memory[index] = (uint8_t)(
            index * 37u + seed * 53u + (index >> 3) * 11u
        );
    }
}

static int callback_memory_range(
    uint64_t address,
    uint8_t width,
    size_t *offset
) {
    if (address < RAM_BASE || width == 0) {
        return 0;
    }
    uint64_t relative = address - RAM_BASE;
    if (relative > MEMORY_SIZE || width > MEMORY_SIZE - relative) {
        return 0;
    }
    *offset = (size_t)relative;
    return 1;
}

static int callback_read(
    void *context,
    uint64_t address,
    uint8_t width,
    uint64_t *value
) {
    CallbackMemory *memory = context;
    size_t offset;
    if (memory == NULL || value == NULL ||
        !callback_memory_range(address, width, &offset)) {
        return 0;
    }
    *value = 0;
    memcpy(value, memory->bytes + offset, width);
    return 1;
}

static int callback_write(
    void *context,
    uint64_t address,
    uint8_t width,
    uint64_t value
) {
    CallbackMemory *memory = context;
    size_t offset;
    if (memory == NULL || !callback_memory_range(address, width, &offset)) {
        return 0;
    }
    memcpy(memory->bytes + offset, &value, width);
    return 1;
}

static int identity_translate(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *physical_address
) {
    (void)context;
    (void)is_write;
    size_t offset;
    if (physical_address == NULL ||
        !callback_memory_range(virtual_address, width, &offset)) {
        return 0;
    }
    *physical_address = RAM_BASE + offset;
    return 1;
}

static int run_interpreter(
    const SIMDMemoryCase *test_case,
    const AVZNativeInstruction *decoded,
    const AVZNativeVectorRegister *input,
    const uint8_t *initial_memory,
    uint64_t post_index,
    int use_fast_memory,
    AVZNativeVectorRegister *output,
    uint8_t *memory_output,
    uint64_t *base_after
) {
    uint64_t x[31] = {0};
    uint64_t vector_low[32];
    uint64_t vector_high[32];
    for (unsigned reg = 0; reg < 32; reg++) {
        x[reg < 31 ? reg : 0] ^= (uint64_t)reg * UINT64_C(0x1020304050607081);
        vector_low[reg] = input[reg].low;
        vector_high[reg] = input[reg].high;
    }

    uint64_t sp = RAM_BASE + OPERAND_OFFSET;
    if (decoded->rn != 31u) {
        x[decoded->rn] = RAM_BASE + OPERAND_OFFSET;
    }
    if ((decoded->flags & 16u) != 0u) {
        x[decoded->rm] = post_index;
    }

    uint64_t pc = UINT64_C(0x1000);
    uint64_t pstate = 0;
    uint64_t fpcr = 0;
    uint64_t fpsr = 0;
    uint8_t halted = 0;
    CallbackMemory callback_memory;
    AVZGuestMemory *guest_memory = NULL;
    AVZNativeMemoryFastPath *fast_path = NULL;
    void *memory_context;
    AVZNativeMemoryReadCallback read_memory;
    AVZNativeMemoryWriteCallback write_memory;

    if (use_fast_memory) {
        guest_memory = avz_guest_memory_create(MEMORY_SIZE);
        if (guest_memory == NULL) {
            fprintf(stderr, "failed to allocate differential guest memory\n");
            return 0;
        }
        memcpy(avz_guest_memory_bytes(guest_memory), initial_memory, MEMORY_SIZE);
        fast_path = avz_native_memory_fast_path_create(
            avz_guest_memory_bytes(guest_memory),
            RAM_BASE,
            MEMORY_SIZE,
            NULL,
            guest_memory,
            identity_translate,
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
        if (fast_path == NULL) {
            avz_guest_memory_destroy(guest_memory);
            fprintf(stderr, "failed to create differential fast-memory path\n");
            return 0;
        }
        memory_context = fast_path;
        read_memory = avz_native_fast_memory_read;
        write_memory = avz_native_fast_memory_write;
    } else {
        memcpy(callback_memory.bytes, initial_memory, MEMORY_SIZE);
        memory_context = &callback_memory;
        read_memory = callback_read;
        write_memory = callback_write;
    }

    AVZNativeBlockResult result =
        avz_native_run_threaded_decoded_block_full_registers(
            decoded,
            1,
            pc,
            1,
            x,
            vector_low,
            vector_high,
            &sp,
            &pc,
            &pstate,
            &fpcr,
            &fpsr,
            &halted,
            read_memory,
            write_memory,
            NULL,
            NULL,
            memory_context
        );

    int succeeded = result.steps == 1 &&
        (result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK ||
         result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    if (!succeeded) {
        fprintf(
            stderr,
            "interpreter failed %08" PRIx32 ": steps=%" PRIu64 " status=%u fast=%d\n",
            test_case->opcode,
            result.steps,
            result.status,
            use_fast_memory
        );
    } else {
        for (unsigned reg = 0; reg < 32; reg++) {
            output[reg].low = vector_low[reg];
            output[reg].high = vector_high[reg];
        }
        *base_after = decoded->rn == 31u ? sp : x[decoded->rn];
        if (use_fast_memory) {
            memcpy(memory_output, avz_guest_memory_bytes(guest_memory), MEMORY_SIZE);
        } else {
            memcpy(memory_output, callback_memory.bytes, MEMORY_SIZE);
        }
    }

    avz_native_memory_fast_path_destroy(fast_path);
    avz_guest_memory_destroy(guest_memory);
    return succeeded;
}

static int compare_execution(
    const SIMDMemoryCase *test_case,
    const AVZNativeInstruction *decoded,
    unsigned seed,
    const AVZNativeVectorRegister *host_vectors,
    const uint8_t *host_memory,
    uint64_t host_base,
    const AVZNativeVectorRegister *interpreter_vectors,
    const uint8_t *interpreter_memory,
    uint64_t interpreter_base,
    const char *path
) {
    for (unsigned reg = 0; reg < 32; reg++) {
        if (host_vectors[reg].low == interpreter_vectors[reg].low &&
            host_vectors[reg].high == interpreter_vectors[reg].high) {
            continue;
        }
        fprintf(
            stderr,
            "%s vector mismatch opcode=%08" PRIx32 " kind=%u seed=%u v%u\n"
            "  decode rt=%u rn=%u rm=%u width=%u bits=%u flags=%u lane=%u\n"
            "  host        %016" PRIx64 " %016" PRIx64 "\n"
            "  interpreter %016" PRIx64 " %016" PRIx64 "\n",
            path,
            test_case->opcode,
            decoded->kind,
            seed,
            reg,
            decoded->rt,
            decoded->rn,
            decoded->rm,
            decoded->width,
            decoded->bits,
            decoded->flags,
            decoded->condition,
            host_vectors[reg].high,
            host_vectors[reg].low,
            interpreter_vectors[reg].high,
            interpreter_vectors[reg].low
        );
        return 0;
    }
    if (host_base != interpreter_base) {
        fprintf(
            stderr,
            "%s base mismatch opcode=%08" PRIx32 " kind=%u seed=%u host=%" PRIx64
            " interpreter=%" PRIx64 "\n",
            path,
            test_case->opcode,
            decoded->kind,
            seed,
            host_base,
            interpreter_base
        );
        return 0;
    }
    if (memcmp(host_memory, interpreter_memory, MEMORY_SIZE) != 0) {
        for (size_t index = 0; index < MEMORY_SIZE; index++) {
            if (host_memory[index] != interpreter_memory[index]) {
                fprintf(
                    stderr,
                    "%s memory mismatch opcode=%08" PRIx32 " kind=%u seed=%u offset=%zu"
                    " host=%02x interpreter=%02x\n",
                    path,
                    test_case->opcode,
                    decoded->kind,
                    seed,
                    index,
                    host_memory[index],
                    interpreter_memory[index]
                );
                break;
            }
        }
        return 0;
    }
    return 1;
}

int main(void) {
    const size_t case_count =
        sizeof(simd_memory_cases) / sizeof(simd_memory_cases[0]);
    unsigned execution_count = 0;
    unsigned mismatch_count = 0;

    for (size_t case_index = 0; case_index < case_count; case_index++) {
        const SIMDMemoryCase *test_case = &simd_memory_cases[case_index];
        AVZNativeInstruction decoded;
        if (!avz_native_decode_instruction(test_case->opcode, &decoded) ||
            decoded.kind != test_case->expected_kind) {
            fprintf(stderr, "decoder rejected audited opcode %08" PRIx32 "\n", test_case->opcode);
            return 2;
        }

        for (unsigned seed = 0; seed < SEED_COUNT; seed++) {
            AVZNativeVectorRegister input[32];
            AVZNativeVectorRegister host_vectors[32];
            AVZNativeVectorRegister callback_vectors[32];
            AVZNativeVectorRegister fast_vectors[32];
            uint8_t initial_memory[MEMORY_SIZE];
            uint8_t host_memory[MEMORY_SIZE];
            uint8_t callback_memory[MEMORY_SIZE];
            uint8_t fast_memory[MEMORY_SIZE];
            uint64_t host_base = 0;
            uint64_t callback_base = 0;
            uint64_t fast_base = 0;
            uint64_t post_index = UINT64_C(17) + seed * UINT64_C(13);

            initialize_vectors(input, seed);
            initialize_memory(initial_memory, seed);
            memcpy(host_vectors, input, sizeof(host_vectors));
            memcpy(host_memory, initial_memory, sizeof(host_memory));
            test_case->execute(
                input,
                host_memory + OPERAND_OFFSET,
                host_vectors,
                &host_base,
                post_index
            );
            host_base = RAM_BASE + OPERAND_OFFSET +
                (host_base - (uint64_t)(uintptr_t)(host_memory + OPERAND_OFFSET));

            if (!run_interpreter(
                    test_case,
                    &decoded,
                    input,
                    initial_memory,
                    post_index,
                    0,
                    callback_vectors,
                    callback_memory,
                    &callback_base) ||
                !compare_execution(
                    test_case,
                    &decoded,
                    seed,
                    host_vectors,
                    host_memory,
                    host_base,
                    callback_vectors,
                    callback_memory,
                    callback_base,
                    "callback")) {
                mismatch_count++;
                break;
            }
            execution_count++;

            if (!run_interpreter(
                    test_case,
                    &decoded,
                    input,
                    initial_memory,
                    post_index,
                    1,
                    fast_vectors,
                    fast_memory,
                    &fast_base) ||
                !compare_execution(
                    test_case,
                    &decoded,
                    seed,
                    host_vectors,
                    host_memory,
                    host_base,
                    fast_vectors,
                    fast_memory,
                    fast_base,
                    "fast")) {
                mismatch_count++;
                break;
            }
            execution_count++;
        }
        if (mismatch_count >= 100) {
            fprintf(stderr, "stopping after 100 mismatches\n");
            break;
        }
    }

    printf(
        "compared %u memory executions across %zu unique rendering opcodes; mismatches=%u\n",
        execution_count,
        case_count,
        mismatch_count
    );
    return mismatch_count == 0 ? 0 : 1;
}
