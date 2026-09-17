#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdio.h>
#include <time.h>

/* White-box access keeps reference/direct comparisons independent of Swift. */
#ifndef AVZ_SIMD_NATIVE_SOURCE
#define AVZ_SIMD_NATIVE_SOURCE "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_SIMD_NATIVE_SOURCE

#ifndef EXPECT_GENERIC_DISPATCHES
#define EXPECT_GENERIC_DISPATCHES 0
#endif

enum { RAM_SIZE = 8192, OPERAND = 4093 };
static const uint64_t ram_base = 0x100000, entry = 0x8000;
static uint32_t current_raw;
static unsigned checks;

#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "line %d opcode=%08" PRIx32 ": %s\n", \
            __LINE__, current_raw, #test); exit(1); \
} } while (0)

typedef struct {
    uint8_t bytes[RAM_SIZE];
    unsigned calls, fail_at;
    size_t limit;
    uint64_t address[4];
    uint8_t width[4];
} Memory;

static int access_memory(Memory *memory, uint64_t address, uint8_t width)
{
    unsigned call = memory->calls++;
    CHECK(call < 4);
    memory->address[call] = address;
    memory->width[call] = width;
    return call != memory->fail_at && address >= ram_base &&
        address - ram_base <= memory->limit &&
        width <= memory->limit - (address - ram_base);
}

static int read_memory(void *context, uint64_t address, uint8_t width, uint64_t *value)
{
    Memory *memory = context;
    if (!access_memory(memory, address, width)) return 0;
    *value = 0;
    memcpy(value, memory->bytes + (address - ram_base), width);
    return 1;
}

static int write_memory(void *context, uint64_t address, uint8_t width, uint64_t value)
{
    Memory *memory = context;
    if (!access_memory(memory, address, width)) return 0;
    memcpy(memory->bytes + (address - ram_base), &value, width);
    return 1;
}

static int identity_translate(void *context, uint64_t address, uint8_t width,
                              uint8_t is_write, uint64_t *physical)
{
    (void)context;
    (void)is_write;
    if (address < ram_base || address - ram_base > RAM_SIZE ||
        width > RAM_SIZE - (address - ram_base)) return 0;
    *physical = address;
    return 1;
}

static AVZNativeCPU initial_cpu(void)
{
    AVZNativeCPU cpu = {0};
    for (unsigned r = 0; r < 31; r++) cpu.x[r] = UINT64_C(0x9876543210fedcba) ^ r;
    for (unsigned r = 0; r < 32; r++) {
        cpu.v[r].low = UINT64_C(0x0123456789abcdef) ^ ((uint64_t)r << 40);
        cpu.v[r].high = UINT64_C(0xfedcba9876543210) ^ ((uint64_t)r << 16);
    }
    cpu.pc = entry;
    cpu.sp = cpu.x[3] = ram_base + OPERAND;
    cpu.x[4] = 37;
    cpu.pstate = 0xa0000005;
    cpu.fpcr = 0x400000;
    cpu.fpsr = 0x8000000;
    cpu.exclusive_address = ram_base;
    cpu.exclusive_generation = 123;
    cpu.exclusive_size = 8;
    cpu.exclusive_valid = 1;
    return cpu;
}

static Memory initial_memory(unsigned fail_at)
{
    Memory memory = {0};
    memory.fail_at = fail_at;
    memory.limit = RAM_SIZE;
    for (unsigned i = 0; i < RAM_SIZE; i++) memory.bytes[i] = (uint8_t)(i * 37 + (i >> 3));
    return memory;
}

static AVZNativeBlockResult direct(
    const AVZNativeInstruction *code, size_t count, uint64_t steps,
    AVZNativeCPU *cpu, void *memory, int fast)
{
    return avz_native_run_threaded_decoded_block_cpu_impl(
        code, count, entry, steps, cpu,
        fast ? avz_native_fast_memory_read : read_memory,
        fast ? avz_native_fast_memory_write : write_memory,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, memory, NULL, fast);
}

static AVZNativeInstruction decode(uint32_t raw)
{
    AVZNativeInstruction instruction;
    current_raw = raw;
    CHECK(avz_native_decode_instruction(raw, &instruction));
    return instruction;
}

static void check_result(AVZNativeBlockResult result, int success)
{
    CHECK(result.steps == (uint64_t)success);
    CHECK(result.status == (success ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_UNSUPPORTED));
    CHECK(result.unsupported_instruction == (success ? 0 : current_raw));
    CHECK(result.generic_dispatches == EXPECT_GENERIC_DISPATCHES);
    CHECK(result.fast_path_steps == 0 && result.fast_path_hits == 0);
}

static void test_duplicate(uint32_t raw)
{
    AVZNativeInstruction d = decode(raw);
    AVZNativeCPU actual = initial_cpu(), expected = actual, reference = actual;
    unsigned width = d.bits / 8;
    uint8_t element[8] = {0};
    if (d.kind == AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL) {
        uint64_t value = d.rn == 31 ? 0 : expected.x[d.rn];
        memcpy(element, &value, width);
    } else {
        CHECK(d.kind == AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT);
        memcpy(element, (uint8_t *)&expected.v[d.rn] + d.condition * width, width);
    }
    memset(&expected.v[d.rd], 0, 16);
    unsigned bytes = (d.flags & 2) ? width : (d.flags & 1) ? 16 : 8;
    for (unsigned i = 0; i < bytes; i += width)
        memcpy((uint8_t *)&expected.v[d.rd] + i, element, width);
    expected.pc += 4;
    check_result(direct(&d, 1, 1, &actual, NULL, 0), 1);
    CHECK(execute_decoded_instruction(&d, &reference, NULL, NULL, NULL,
          NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL) == 1);
    CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    CHECK(memcmp(&actual, &reference, sizeof(actual)) == 0);
    checks++;
}

static void test_memory(uint32_t raw)
{
    AVZNativeInstruction d = decode(raw);
    CHECK(d.kind == AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE);
    for (unsigned fail = 0; fail <= d.rd; fail++) {
        AVZNativeCPU actual = initial_cpu(), expected = actual, reference = actual;
        Memory memory = initial_memory(fail), wanted = memory, ref_memory = memory;
        int success = fail == d.rd;
        int load = d.flags & 1;
        for (unsigned i = 0; i < (success ? d.rd : fail); i++) {
            uint8_t *vector = (uint8_t *)&expected.v[(d.rt + i) & 31];
            uint8_t *operand = wanted.bytes + OPERAND + i * d.width;
            if (load && success) {
                if (d.flags & 32) {
                    memset(vector, 0, 16);
                    for (unsigned j = 0; j < ((d.flags & 64) ? 16u : 8u); j += d.width)
                        memcpy(vector + j, operand, d.width);
                } else memcpy(vector + d.condition * d.width, operand, d.width);
            } else if (!load) {
                memcpy(operand, vector + d.condition * d.width, d.width);
                expected.exclusive_address = expected.exclusive_generation = 0;
                expected.exclusive_size = expected.exclusive_valid = 0;
            }
        }
        if (success) {
            expected.pc += 4;
            if (d.flags & 8) {
                uint64_t increment = (d.flags & 16) ? expected.x[d.rm] : d.rd * d.width;
                if (d.rn == 31) expected.sp += increment;
                else expected.x[d.rn] += increment;
            }
        }
        check_result(direct(&d, 1, 1, &actual, &memory, 0), success);
        CHECK(execute_decoded_instruction(&d, &reference, read_memory, write_memory, NULL,
              NULL, NULL, NULL, NULL, NULL, NULL, 0, &ref_memory) == success);
        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
        CHECK(memcmp(&actual, &reference, sizeof(actual)) == 0);
        CHECK(memcmp(memory.bytes, wanted.bytes, RAM_SIZE) == 0);
        CHECK(memcmp(&memory, &ref_memory, sizeof(memory)) == 0);
        CHECK(memory.calls == (success ? d.rd : fail + 1));
        for (unsigned i = 0; i < memory.calls; i++) {
            CHECK(memory.address[i] == ram_base + OPERAND + i * d.width);
            CHECK(memory.width[i] == d.width);
        }
        checks++;
    }
}

static void emit(uint32_t raw)
{
    AVZNativeInstruction d = decode(raw);
    printf("8000 %08" PRIx32 " kind=%u rn=%u rm=%u flags=%u\n",
           raw, d.kind, d.rn, d.rm, d.flags);
}

static void fast_memory_faults(void)
{
    static const uint32_t raw[] = {0x4dffe81f, 0x4dffb01f, 0x4dbfb01f};
    for (unsigned op = 0; op < sizeof(raw) / sizeof(raw[0]); op++) {
        AVZNativeInstruction d = decode(raw[op]);
        CHECK(d.rd == 4);
        for (unsigned fail = 0; fail <= 4; fail++) {
            AVZNativeCPU fast_cpu = initial_cpu(), callback_cpu = fast_cpu;
            fast_cpu.x[0] = callback_cpu.x[0] = ram_base + OPERAND;
            Memory fast_memory = initial_memory(4), callback_memory = initial_memory(fail);
            fast_memory.limit = OPERAND + fail * d.width;
            AVZNativeMemoryFastPath *fast = avz_native_memory_fast_path_create(
                fast_memory.bytes, ram_base, OPERAND + fail * d.width, NULL,
                &fast_memory, identity_translate, read_memory, write_memory,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            CHECK(fast != NULL);
            AVZNativeBlockResult result = direct(&d, 1, 1, &fast_cpu, fast, 1);
            if (result.steps != (uint64_t)(fail == 4))
                fprintf(stderr, "fast boundary fail=%u steps=%" PRIu64 " calls=%u\n",
                        fail, result.steps, fast_memory.calls);
            check_result(result, fail == 4);
            check_result(direct(&d, 1, 1, &callback_cpu, &callback_memory, 0), fail == 4);
            CHECK(memcmp(&fast_cpu, &callback_cpu, sizeof(fast_cpu)) == 0);
            CHECK(memcmp(fast_memory.bytes, callback_memory.bytes, RAM_SIZE) == 0);
            if (fail < 4) {
                CHECK(fast_memory.calls > 0);
                CHECK(fast_memory.address[fast_memory.calls - 1] == ram_base + OPERAND + fail * d.width);
            }
            avz_native_memory_fast_path_destroy(fast);
            checks++;
        }
    }
}

static void memory_matrix(int emit_only)
{
    for (unsigned count = 1; count <= 4; count++)
    for (unsigned size = 0; size < 4; size++)
    for (unsigned q = 0; q < 2; q++)
    for (unsigned mode = 0; mode < 3; mode++)
    for (unsigned sp = 0; sp < (emit_only ? 1u : 2u); sp++) {
        uint32_t common = 0x0d00001f | ((sp ? 31u : 3u) << 5) | (q << 30) |
            (((count - 1) & 1) << 21) | (((count - 1) >> 1) << 13);
        if (mode) common |= (1u << 23) | ((mode == 1 ? 31u : 4u) << 16);
        uint32_t replicate = common | (1u << 22) | (6u << 13) | (size << 10);
        if (emit_only) emit(replicate); else test_memory(replicate);
        unsigned lanes_per_half = 8u >> size;
        for (unsigned lane = 0; lane < lanes_per_half; lane++) {
            unsigned opcode = size == 0 ? 0 : size == 1 ? 2 : 4;
            unsigned s = size == 3 ? 0 : lane >> (2 - size);
            unsigned encoded_size = size == 0 ? lane & 3 : size == 1 ? (lane & 1) << 1 : size == 2 ? 0 : 1;
            for (unsigned load = 0; load < 2; load++) {
                uint32_t raw = common | (load << 22) | (opcode << 13) |
                    (s << 12) | (encoded_size << 10);
                if (emit_only) emit(raw); else test_memory(raw);
            }
        }
    }
}

static void duplicate_matrix(int emit_only)
{
    for (unsigned size = 0; size < 4; size++)
    for (unsigned q = 0; q < 2; q++) {
        if (size == 3 && !q) continue;
        for (unsigned rn = 3; rn <= 31; rn += 28) {
            if (!emit_only) test_duplicate(0x0e000c1f | (q << 30) | (1u << (16 + size)) | (rn << 5));
            for (unsigned lane = 0; lane < (16u >> size); lane++) {
                unsigned imm5 = (1u << size) | (lane << (size + 1));
                uint32_t raw = 0x0e00041f | (q << 30) | (imm5 << 16) | (rn << 5);
                if (emit_only) emit(raw); else test_duplicate(raw);
                raw = 0x5e00041f | (imm5 << 16) | (rn << 5);
                if (q) { if (emit_only) emit(raw); else test_duplicate(raw); }
            }
        }
    }
}

static void reserved_encodings(void)
{
    static const uint32_t raw[] = {
        0x4d00c806, 0x4d40d806, 0x4d41c806, /* invalid replicate */
        0x0d004400, 0x0d008800, 0x0d009400, /* invalid lane size/S */
        0x0e000c00, 0x0e080c00, 0x4e100c00, /* invalid general DUP */
        0x0e000400, 0x4e100400, 0x5e000400, 0x5e100400
    };
    for (unsigned i = 0; i < sizeof(raw) / sizeof(raw[0]); i++) {
        AVZNativeInstruction d;
        current_raw = raw[i];
        CHECK(!avz_native_decode_instruction(raw[i], &d));
        checks++;
    }
}

static void hardware_general_duplicates(void)
{
#if defined(__aarch64__) && defined(__ARM_NEON)
    for (unsigned seed = 0; seed < 16; seed++) {
        uint64_t value = UINT64_C(0x9876543210fedcba) ^ ((uint64_t)seed * UINT64_C(0x0102040810204081));
        AVZNativeVectorRegister host;
#define HOST_DUP(assembly, raw) do { \
        __asm__ volatile(assembly "\n str q0, [%0]" : : "r"(&host), "r"(value) : "v0", "memory"); \
        AVZNativeInstruction d = decode(raw); \
        AVZNativeCPU cpu = initial_cpu(); cpu.x[3] = value; \
        check_result(direct(&d, 1, 1, &cpu, NULL, 0), 1); \
        CHECK(memcmp(&cpu.v[0], &host, sizeof(host)) == 0); checks++; \
    } while (0)
        HOST_DUP("dup v0.8b, %w1", 0x0e010c60);
        HOST_DUP("dup v0.16b, %w1", 0x4e010c60);
        HOST_DUP("dup v0.4h, %w1", 0x0e020c60);
        HOST_DUP("dup v0.8h, %w1", 0x4e020c60);
        HOST_DUP("dup v0.2s, %w1", 0x0e040c60);
        HOST_DUP("dup v0.4s, %w1", 0x4e040c60);
        HOST_DUP("dup v0.2d, %1", 0x4e080c60);
        HOST_DUP("dup v0.2d, xzr", 0x4e080fe0);
#undef HOST_DUP
    }
#else
    puts("SKIP general DUP hardware differential: requires ARM64 NEON host");
#endif
}

static double seconds(void)
{
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec * 1e-9;
}

static void benchmark(void)
{
    static const struct { const char *name; uint32_t raw; } cases[] = {
        {"dup-general", 0x4e010c60}, {"dup-element", 0x4e1f0460},
        {"ld1r", 0x4d40c860}, {"ld4r", 0x4d60e87f},
        {"ld4-lane", 0x4d60b07f}, {"st4-lane", 0x4d20b07f}
    };
    const uint64_t steps = 10000000;
    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        AVZNativeInstruction code[16];
        for (unsigned i = 0; i < 15; i++) code[i] = decode(cases[c].raw);
        code[15] = decode(0x17fffff1); /* b back 15 instructions */
        for (unsigned run = 0; run < 7; run++) {
            AVZNativeCPU cpu = initial_cpu();
            cpu.x[3] = ram_base + 1024;
            Memory memory = initial_memory(4);
            AVZNativeMemoryFastPath *fast = avz_native_memory_fast_path_create(
                memory.bytes, ram_base, RAM_SIZE, NULL, &memory, identity_translate, NULL, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            CHECK(fast != NULL);
            double start = seconds();
            AVZNativeBlockResult result = direct(code, 16, steps, &cpu, fast, 1);
            double elapsed = seconds() - start;
            CHECK(result.steps == steps && result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            CHECK(result.generic_dispatches == EXPECT_GENERIC_DISPATCHES * (steps - steps / 16));
            CHECK(result.fast_path_steps == 0);
            if (run) printf("%s run=%u steps=%" PRIu64 " generic=%" PRIu64 " seconds=%.6f mips=%.3f\n",
                cases[c].name, run, steps, result.generic_dispatches, elapsed, steps / elapsed / 1e6);
            avz_native_memory_fast_path_destroy(fast);
        }
    }
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--benchmark") == 0) benchmark();
    else if (argc == 2 && strcmp(argv[1], "--emit-memory") == 0) memory_matrix(1);
    else if (argc == 2 && strcmp(argv[1], "--emit-vector") == 0) duplicate_matrix(1);
    else if (argc == 1) {
        reserved_encodings();
        duplicate_matrix(0);
        memory_matrix(0);
        fast_memory_faults();
        hardware_general_duplicates();
        printf("PASS native SIMD direct: %u checks (including per-element faults)\n", checks);
    } else { fprintf(stderr, "usage: %s [--benchmark|--emit-memory|--emit-vector]\n", argv[0]); return 2; }
    return 0;
}
