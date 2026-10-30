#define _POSIX_C_SOURCE 200809L
#include "ARM64VizThreadedPrototype.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "line %d case=%" PRIu64 ": %s\n", __LINE__, cases, #test); \
    exit(1); \
} } while (0)

static uint64_t cases;
static uint64_t random_state = UINT64_C(0xd4f862ac35e9710b);
static const uint64_t edges[] = {
    0, 1, UINT32_MAX, UINT64_C(0x7fffffff), UINT64_C(0x80000000),
    UINT64_C(0x100000000), UINT64_C(0x7fffffffffffffff),
    UINT64_C(0x8000000000000000), UINT64_MAX
};

static uint64_t random64(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

static AVZNativeCPU initial(uint64_t pc, uint64_t value)
{
    AVZNativeCPU cpu;
    memset(&cpu, 0, sizeof(cpu));
    for (unsigned i = 0; i < 31; i++) cpu.x[i] = value;
    for (unsigned i = 0; i < 32; i++) {
        cpu.v[i].low = value ^ i;
        cpu.v[i].high = ~value ^ i;
    }
    cpu.sp = value;
    cpu.pc = pc;
    cpu.pstate = UINT64_C(0xa55a0123456789ab);
    cpu.fpcr = 0x400000;
    cpu.fpsr = 0x1234;
    cpu.exclusive_address = 0x10203040;
    cpu.exclusive_generation = 77;
    cpu.exclusive_size = 8;
    cpu.exclusive_valid = 1;
    return cpu;
}

static void decode(const uint32_t *words, size_t count, AVZNativeInstruction *decoded)
{
    for (size_t i = 0; i < count; i++)
        (void)avz_native_decode_instruction(words[i], &decoded[i]);
}

static AVZNativeBlockResult reference(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, int threaded,
    AVZNativeMemoryReadCallback read, AVZNativeMemoryWriteCallback write, void *context)
{
    if (read != NULL || write != NULL)
        return avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
            code, count, base, budget, cpu->x, NULL, NULL,
            &cpu->sp, &cpu->pc, &cpu->pstate, &cpu->fpcr, &cpu->fpsr,
            &cpu->exclusive_address, &cpu->exclusive_generation,
            &cpu->exclusive_size, &cpu->exclusive_valid, &cpu->halted,
            read, write, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, context);
    if (threaded)
        return avz_native_run_threaded_decoded_block_registers(code, count, base,
            budget, cpu->x, &cpu->sp, &cpu->pc, &cpu->pstate, &cpu->halted,
            read, write, NULL, NULL, context);
    return avz_native_run_decoded_block_registers(code, count, base,
        budget, cpu->x, &cpu->sp, &cpu->pc, &cpu->pstate, &cpu->halted,
        read, write, NULL, NULL, context);
}

static void same_result(AVZNativeBlockResult a, AVZNativeBlockResult b)
{
    CHECK(a.steps == b.steps);
    CHECK(a.status == b.status);
    CHECK(a.unsupported_instruction == b.unsupported_instruction);
}

static void compare(const AVZThreadedPrototype *program,
    const AVZNativeInstruction *code, size_t count, uint64_t base,
    uint64_t budget, AVZNativeCPU start)
{
    AVZNativeCPU actual = start, expected = start;
    AVZNativeBlockResult got = avz_tp_run(program, budget, &actual);
    AVZNativeBlockResult want = reference(code, count, base, budget,
        &expected, 0, NULL, NULL, NULL);
    if (got.steps != want.steps || got.status != want.status ||
        memcmp(&actual, &expected, sizeof(actual))) {
        fprintf(stderr, "base=%" PRIx64 " pc=%" PRIx64 " budget=%" PRIu64
            " raw=%08x status=%u/%u steps=%" PRIu64 "/%" PRIu64
            " pc=%" PRIx64 "/%" PRIx64 " flags=%" PRIx64 "/%" PRIx64 "\n",
            base, start.pc, budget, code[0].raw, got.status, want.status,
            got.steps, want.steps, actual.pc, expected.pc, actual.pstate, expected.pstate);
    }
    same_result(got, want);
    CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    CHECK(got.generic_dispatches == got.steps);
    CHECK(got.fast_path_hits == 0 && got.fast_path_steps == 0 && got.mapped_blocks == 0);
    /* The older threaded API does not inspect an already-halted input. */
    if (!start.halted) {
        expected = start;
        want = reference(code, count, base, budget, &expected, 1, NULL, NULL, NULL);
        same_result(got, want);
        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    }
    cases++;
}

static void single(uint32_t raw)
{
    AVZNativeInstruction code;
    CHECK(avz_native_decode_instruction(raw, &code));
    AVZThreadedPrototype *program = avz_tp_create(&raw, 1, 0x8000);
    CHECK(program);
    for (size_t i = 0; i <= sizeof(edges) / sizeof(edges[0]); i++) {
        uint64_t value = i == sizeof(edges) / sizeof(edges[0]) ? random64() : edges[i];
        compare(program, &code, 1, 0x8000, 1, initial(0x8000, value));
    }
    avz_tp_destroy(program);
}

static void arithmetic(void)
{
    for (unsigned sf = 0; sf < 2; sf++)
        for (unsigned operation = 0; operation < 4; operation++)
            for (unsigned shift = 0; shift < 2; shift++)
                for (unsigned rn = 0; rn < 32; rn++)
                    for (unsigned rd = 0; rd < 32; rd++) {
                        unsigned immediate = (rn + rd) % 3 == 0 ? 0 :
                            (rn + rd) % 3 == 1 ? 1 : 4095;
                        single(0x11000000 | (sf << 31) | ((operation & 1) << 30) |
                            ((operation >> 1) << 29) | (shift << 22) |
                            (immediate << 10) | (rn << 5) | rd);
                    }
    const unsigned opcodes[] = {0, 2, 3};
    const unsigned immediates[] = {0, 65535, 0xa55a};
    for (unsigned sf = 0; sf < 2; sf++)
        for (unsigned op = 0; op < 3; op++)
            for (unsigned hw = 0; hw < (sf ? 4u : 2u); hw++)
                for (unsigned rd = 0; rd < 32; rd++)
                    for (unsigned imm = 0; imm < 3; imm++)
                        single(0x12800000 | (sf << 31) | (opcodes[op] << 29) |
                            (hw << 21) | (immediates[imm] << 5) | rd);
    const int offsets[] = {0, 1, -1, 0xfffff, -0x100000};
    for (unsigned page = 0; page < 2; page++)
        for (unsigned rd = 0; rd < 32; rd++)
            for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
                uint32_t imm = (uint32_t)offsets[i] & 0x1fffff;
                single(0x10000000 | (page << 31) | ((imm & 3) << 29) |
                    ((imm >> 2) << 5) | rd);
            }
    single(0xd503201f);
}

static void register_case(uint32_t raw, int carry)
{
    AVZNativeInstruction code;
    CHECK(avz_native_decode_instruction(raw, &code));
    CHECK(avz_tp_supports_instruction(&code));
    CHECK(avz_tp_supports_instruction_with_memory(&code));
    AVZThreadedPrototype *program = avz_tp_create(&raw, 1, 0x8000);
    CHECK(program);
    static const uint64_t extension_edges[] = {0x7f, 0x80, 0xff, 0x7fff,
        0x8000, 0xffff, 0x10001, UINT64_C(0x8000000080000080)};
    unsigned variants = carry ? 81 : code.kind == AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER ? 18 : 10;
    for (unsigned i = 0; i < variants; i++) {
        AVZNativeCPU cpu = initial(0x8000, UINT64_C(0xabcdef0012345678));
        for (unsigned reg = 0; reg < 31; reg++) cpu.x[reg] = random64();
        uint64_t a = i < 81 && carry ? edges[i / 9] : edges[i % 9];
        uint64_t b = carry ? edges[i % 9] : i >= 10 ? extension_edges[i - 10] :
            i == 9 ? random64() : edges[(i * 5 + 1) % 9];
        if (code.rn != 31) cpu.x[code.rn] = a;
        if (code.rm != 31) cpu.x[code.rm] = b;
        cpu.sp = a;
        for (unsigned flag = 0; flag < (carry ? 16u : 1u); flag++) {
            cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) |
                ((uint64_t)(carry ? flag : i & 15) << 28);
            compare(program, &code, 1, 0x8000, 1, cpu);
        }
    }
    avz_tp_destroy(program);
}

static uint32_t reg_encoding(uint32_t base, unsigned sf, unsigned operation,
    unsigned rn, unsigned rm, unsigned rd)
{
    return base | (sf << 31) | ((operation & 1) << 30) | ((operation >> 1) << 29) |
        (rm << 16) | (rn << 5) | rd;
}

static void register_arithmetic(void)
{
    for (unsigned sf = 0; sf < 2; sf++) {
        for (unsigned shift = 0; shift < (sf ? 64u : 32u); shift++) {
            for (unsigned operation = 0; operation < 4; operation++) {
                for (unsigned kind = 0; kind < 4; kind++) {
                    for (unsigned zr = 0; zr < 4; zr++) {
                        unsigned rn = zr == 1 ? 31 : shift % 31;
                        unsigned rm = zr == 2 ? 31 : (shift + 1) % 31;
                        unsigned rd = zr == 3 ? 31 : (shift + 2) % 31;
                        if (kind < 3)
                            register_case(reg_encoding(0x0b000000, sf, operation, rn, rm, rd) |
                                (kind << 22) | (shift << 10), 0);
                        for (unsigned invert = 0; invert < 2; invert++)
                            register_case(0x0a000000 | (sf << 31) | (operation << 29) |
                                (kind << 22) | (invert << 21) | (rm << 16) |
                                (shift << 10) | (rn << 5) | rd, 0);
                    }
                }
            }
        }
        for (unsigned operation = 0; operation < 4; operation++) {
            for (unsigned zr = 0; zr < 4; zr++) {
                unsigned rn = zr == 1 ? 31 : 0, rm = zr == 2 ? 31 : 1, rd = zr == 3 ? 31 : 2;
                register_case(reg_encoding(0x1a000000, sf, operation, rn, rm, rd), 1);
                for (unsigned extension = 0; extension < 8; extension++) {
                    if (!sf && (extension & 3) == 3) continue;
                    for (unsigned shift = 0; shift <= 4; shift++)
                        register_case(reg_encoding(0x0b200000, sf, operation, rn, rm, rd) |
                            (extension << 13) | (shift << 10), 0);
                }
            }
        }
    }
    /* Aliased destinations/sources, including all-XZR shifted forms. */
    for (unsigned reg = 0; reg < 32; reg++) {
        register_case(reg_encoding(0x0b000000, 1, 3, reg, reg, reg), 0);
        register_case(reg_encoding(0x1a000000, 0, 2, reg, reg, reg), 0);
    }
}

static void register_sequences(void)
{
    uint32_t words[] = {
        0x8b020800, /* add x0, x0, x2, lsl #2 */
        0xcac31c63, /* eor x3, x3, x3, ror #7 */
        0xba030000, /* adcs x0, x0, x3 */
        0xcb22cbe1, /* sub x1, sp, w2, sxtw #2 */
        0x6a41041f, /* ands wzr, w0, w1, lsr #1 */
        0x54ffff61, /* b.ne to entry */
        0x91000400
    };
    AVZNativeInstruction code[7];
    decode(words, 7, code);
    for (unsigned i = 0; i < 7; i++) CHECK(avz_tp_supports_instruction(&code[i]));
    AVZThreadedPrototype *program = avz_tp_create(words, 7, 0x8000);
    CHECK(program);
    for (unsigned seed = 0; seed < 30; seed++) {
        AVZNativeCPU cpu = initial(0x8000, seed < 9 ? edges[seed] : random64());
        cpu.x[2] = seed;
        for (unsigned budget = 0; budget < 40; budget++)
            compare(program, code, 7, 0x8000, budget, cpu);
    }
    avz_tp_destroy(program);
}

static void branch_case(uint32_t raw, uint64_t value, uint64_t flags, uint64_t base)
{
    uint32_t words[] = {raw, 0x91000400};
    AVZNativeInstruction code[2];
    decode(words, 2, code);
    AVZThreadedPrototype *program = avz_tp_create(words, 2, base);
    CHECK(program);
    AVZNativeCPU cpu = initial(base, value);
    cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) | (flags << 28);
    for (unsigned budget = 0; budget <= 7; budget++)
        compare(program, code, 2, base, budget, cpu);
    avz_tp_destroy(program);
}

static void branches(void)
{
    const int offsets[] = {-2, -1, 0, 1, 2};
    for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
        uint32_t imm19 = (uint32_t)offsets[i] & 0x7ffff;
        for (unsigned condition = 0; condition < 16; condition++)
            for (unsigned flags = 0; flags < 16; flags++)
                branch_case(0x54000000 | (imm19 << 5) | condition, 0, flags, 0x8000);
        for (unsigned sf = 0; sf < 2; sf++)
            for (unsigned nonzero = 0; nonzero < 2; nonzero++)
                for (unsigned rt = 0; rt < 32; rt++)
                    for (unsigned edge = 0; edge < 9; edge++)
                        branch_case(0x34000000 | (sf << 31) | (nonzero << 24) |
                            (imm19 << 5) | rt, edges[edge], edge, 0x8000);
        for (unsigned bit = 0; bit < 64; bit++)
            for (unsigned nonzero = 0; nonzero < 2; nonzero++)
                for (unsigned zr = 0; zr < 2; zr++)
                    for (unsigned set = 0; set < 2; set++)
                        branch_case(0x36000000 | ((bit >> 5) << 31) |
                            (nonzero << 24) | ((bit & 31) << 19) |
                            (((uint32_t)offsets[i] & 0x3fff) << 5) | (zr ? 31 : 0),
                            set ? UINT64_C(1) << bit : ~(UINT64_C(1) << bit), 5, 0x8000);
        for (unsigned link = 0; link < 2; link++) {
            uint32_t raw = 0x14000000 | (link << 31) | ((uint32_t)offsets[i] & 0x3ffffff);
            branch_case(raw, 17, 3, 0x8000);
            branch_case(raw, 17, 3, UINT64_MAX - 7);
            branch_case(raw, 17, 3, 0);
        }
    }
}

static void sequences(void)
{
    for (unsigned trial = 0; trial < 300; trial++) {
        uint32_t words[16];
        for (unsigned i = 0; i < 16; i++) {
            uint32_t r = (uint32_t)random64();
            if (i % 5 == 4) {
                uint32_t displacement = (uint32_t)((int)(r % 20) - (int)i - 2) & 0x7ffff;
                words[i] = 0x54000000 | (displacement << 5) | (r & 15);
            } else {
                words[i] = 0x11000000 | (r & 0xe04003ff) | (((r >> 10) & 4095) << 10);
            }
        }
        AVZNativeInstruction code[16];
        decode(words, 16, code);
        AVZThreadedPrototype *program = avz_tp_create(words, 16, 0x8000);
        CHECK(program);
        AVZNativeCPU cpu = initial(0x8000, random64());
        for (unsigned i = 0; i < 31; i++) cpu.x[i] = random64();
        for (unsigned budget = 0; budget <= 33; budget++)
            compare(program, code, 16, 0x8000, budget, cpu);
        avz_tp_destroy(program);
    }
}

static void boundaries(void)
{
    const uint32_t excluded[] = {
        0xf9400140, 0xf9000140, 0xa9400440, 0xc85f7c40,
        0xd5033bbf, 0xd4000001, 0xd4200000, 0xd503207f,
        0xd4400000, 0xd61f0000, 0xd503209f, 0xffffffff,
        0x91800400, 0x52c00000,
        0x0bc00000, 0x0b008000, 0x0b600000, 0x0b201400,
        0x0b206000, 0x0b20e000, 0x0a008000, 0x39800000, 0xf8400400
    };
    for (unsigned i = 0; i < sizeof(excluded) / sizeof(excluded[0]); i++) {
        uint32_t words[] = {0x910043ff, 0xf100041f, excluded[i], 0x91000400};
        AVZNativeInstruction code[4];
        decode(words, 4, code);
        AVZThreadedPrototype *program = avz_tp_create(words, 4, 0x8000);
        CHECK(program);
        for (unsigned budget = 0; budget <= 5; budget++) {
            AVZNativeCPU actual = initial(0x8000, 1), expected = actual;
            AVZNativeBlockResult got = avz_tp_run(program, budget, &actual);
            AVZNativeBlockResult prefix = reference(code, 4, 0x8000,
                budget < 2 ? budget : 2, &expected, 0, NULL, NULL, NULL);
            CHECK(got.steps == prefix.steps);
            CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
            CHECK(got.status == (budget <= 2 ? AVZ_NATIVE_STATUS_MAX_STEPS :
                AVZ_NATIVE_STATUS_UNSUPPORTED));
            CHECK(got.unsupported_instruction == (budget <= 2 ? 0 : excluded[i]));
            cases++;
        }
        avz_tp_destroy(program);
    }
    uint32_t words[] = {0x91000400, 0x17ffffff};
    AVZNativeInstruction code[2];
    decode(words, 2, code);
    AVZThreadedPrototype *program = avz_tp_create(words, 2, 0x8000);
    CHECK(program);
    const uint64_t pcs[] = {0, 0x7ffc, 0x8000, 0x8001, 0x8004, 0x8008, UINT64_MAX};
    for (unsigned i = 0; i < sizeof(pcs) / sizeof(pcs[0]); i++)
        for (unsigned halted = 0; halted < 2; halted++)
            for (unsigned budget = 0; budget <= 5; budget++) {
                AVZNativeCPU cpu = initial(pcs[i], 0);
                cpu.halted = (uint8_t)halted;
                compare(program, code, 2, 0x8000, budget, cpu);
            }
    AVZNativeCPU cpu = initial(0x8000, 0), before = cpu;
    CHECK(avz_tp_run(NULL, 1, &cpu).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(memcmp(&cpu, &before, sizeof(cpu)) == 0);
    CHECK(avz_tp_run(program, 1, NULL).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(!avz_tp_create(NULL, 1, 0x8000));
    CHECK(!avz_tp_create(words, 0, 0x8000));
    CHECK(!avz_tp_create(words, AVZ_TP_MAX_INSTRUCTIONS + 1, 0x8000));
    CHECK(!avz_tp_create(words, 1, 0x8001));
    CHECK(!avz_tp_create(words, 2, UINT64_MAX - 3));
    CHECK(avz_tp_program_bytes(NULL) == 0);
    avz_tp_destroy(NULL);
    /* Owned snapshot: changes to source words do not change this program. */
    words[0] = 0xffffffff;
    compare(program, code, 2, 0x8000, 1000001, before);
    avz_tp_destroy(program);
    uint32_t *large = malloc(AVZ_TP_MAX_INSTRUCTIONS * sizeof(*large));
    CHECK(large);
    for (unsigned i = 0; i < AVZ_TP_MAX_INSTRUCTIONS; i++) large[i] = 0xd503201f;
    program = avz_tp_create(large, AVZ_TP_MAX_INSTRUCTIONS, 0x8000);
    CHECK(program);
    cpu = before;
    AVZNativeBlockResult got = avz_tp_run(program, AVZ_TP_MAX_INSTRUCTIONS + 1, &cpu);
    CHECK(got.steps == AVZ_TP_MAX_INSTRUCTIONS && got.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
    CHECK(cpu.pc == 0x8000 + 4 * AVZ_TP_MAX_INSTRUCTIONS);
    avz_tp_destroy(program);
    free(large);
    cases++;
}

typedef struct {
    uint64_t value, address;
    unsigned calls, fail_at;
    uint8_t width;
} Memory;

static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value)
{
    Memory *memory = opaque;
    memory->address = address;
    memory->width = width;
    if (memory->calls++ == memory->fail_at) return 0;
    *value = memory->value;
    return 1;
}

static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value)
{
    Memory *memory = opaque;
    memory->address = address;
    memory->width = width;
    if (memory->calls++ == memory->fail_at) return 0;
    memory->value = value;
    return 1;
}

static void fault_handoff(void)
{
    const uint32_t accesses[] = {0xf9400140, 0xf9000140};
    for (unsigned access = 0; access < 2; access++) {
        uint32_t words[] = {0x910043ff, 0xf100041f, accesses[access], 0x91000400, 0xffffffff};
        AVZNativeInstruction code[5];
        decode(words, 5, code);
        AVZThreadedPrototype *program = avz_tp_create(words, 5, 0x8000);
        CHECK(program);
        for (unsigned fail = 0; fail < 2; fail++)
            for (unsigned budget = 0; budget <= 7; budget++) {
                AVZNativeCPU actual = initial(0x8000, UINT64_MAX), expected = actual;
                Memory a = {.value = 79, .fail_at = fail}, b = a;
                AVZNativeBlockResult got = avz_tp_run(program, budget, &actual);
                CHECK(a.calls == 0);
                if (got.status == AVZ_NATIVE_STATUS_UNSUPPORTED) {
                    CHECK(actual.pc == 0x8008 && got.steps == 2);
                    AVZNativeBlockResult rest = reference(code, 5, 0x8000,
                        budget - got.steps, &actual, 0, read_memory, write_memory, &a);
                    rest.steps += got.steps;
                    got = rest;
                }
                AVZNativeBlockResult want = reference(code, 5, 0x8000,
                    budget, &expected, 0, read_memory, write_memory, &b);
                same_result(got, want);
                CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
                CHECK(a.value == b.value && a.address == b.address &&
                    a.width == b.width && a.calls == b.calls);
                if (fail == 0 && budget > 2) CHECK(actual.pc == 0x8008 && got.steps == 2);
                cases++;
            }
        avz_tp_destroy(program);
    }
}

enum { TP_RAM_BASE = 0x100000, TP_RAM_SIZE = 16384 };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeMemoryFastPath *path;
    AVZThreadedPrototype *destroy_on_access;
    unsigned reads, writes, faults, destroyed;
    int force_slow, fail;
    uint64_t fault_address;
    uint8_t fault_access, fault_level, fault_status;
    uint64_t write_address, write_value;
    uint8_t write_width;
} NativeMemory;

static int native_range(uint64_t address, uint8_t width)
{
    return address >= TP_RAM_BASE && address - TP_RAM_BASE <= TP_RAM_SIZE &&
        width <= TP_RAM_SIZE - (address - TP_RAM_BASE);
}

static int native_translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical)
{
    NativeMemory *memory = opaque;
    (void)write;
    if (memory->force_slow || !native_range(address, width)) return 0;
    *physical = address;
    return 1;
}

static void destroy_snapshot(NativeMemory *memory)
{
    if (memory->destroy_on_access) {
        avz_tp_destroy(memory->destroy_on_access);
        memory->destroy_on_access = NULL;
        memory->destroyed++;
    }
}

static int native_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value)
{
    NativeMemory *memory = opaque;
    memory->reads++;
    destroy_snapshot(memory);
    if (memory->fail || !native_range(address, width)) return 0;
    size_t offset = (size_t)(address - TP_RAM_BASE);
    avz_guest_memory_lock_range(memory->ram, offset, width);
    *value = 0;
    for (unsigned byte = 0; byte < width; byte++)
        *value |= (uint64_t)avz_guest_memory_bytes(memory->ram)[offset + byte] << (byte * 8);
    avz_guest_memory_unlock_range(memory->ram, offset, width);
    return 1;
}

static int native_write(void *opaque, uint64_t address, uint8_t width, uint64_t value)
{
    NativeMemory *memory = opaque;
    memory->writes++;
    memory->write_address = address;
    memory->write_width = width;
    memory->write_value = value;
    destroy_snapshot(memory);
    if (memory->fail || !native_range(address, width)) return 0;
    size_t offset = (size_t)(address - TP_RAM_BASE);
    avz_guest_memory_lock_range(memory->ram, offset, width);
    for (unsigned byte = 0; byte < width; byte++)
        avz_guest_memory_bytes(memory->ram)[offset + byte] = (uint8_t)(value >> (byte * 8));
    avz_guest_memory_note_write(memory->ram, offset, width);
    avz_guest_memory_unlock_range(memory->ram, offset, width);
    return 1;
}

static void native_fault(void *opaque, uint64_t address, uint8_t access,
    uint8_t level, uint8_t status)
{
    NativeMemory *memory = opaque;
    memory->faults++;
    memory->fault_address = address;
    memory->fault_access = access;
    memory->fault_level = level;
    memory->fault_status = status;
}

static void native_memory_init(NativeMemory *memory)
{
    memset(memory, 0, sizeof(*memory));
    memory->ram = avz_guest_memory_create(TP_RAM_SIZE);
    CHECK(memory->ram);
    for (size_t i = 0; i < TP_RAM_SIZE; i++)
        avz_guest_memory_bytes(memory->ram)[i] = (uint8_t)(i * 73 + 29);
    memory->path = avz_native_memory_fast_path_create(avz_guest_memory_bytes(memory->ram),
        TP_RAM_BASE, TP_RAM_SIZE, NULL, memory, native_translate, native_read, native_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(memory->path && avz_native_memory_fast_path_set_guest_memory(memory->path, memory->ram));
}

static void native_memory_destroy(NativeMemory *memory)
{
    avz_native_memory_fast_path_destroy(memory->path);
    avz_guest_memory_destroy(memory->ram);
}

static void same_memory(const NativeMemory *a, const NativeMemory *b)
{
    CHECK(memcmp(avz_guest_memory_bytes(a->ram), avz_guest_memory_bytes(b->ram), TP_RAM_SIZE) == 0);
    CHECK(a->reads == b->reads && a->writes == b->writes && a->faults == b->faults);
    CHECK(a->write_address == b->write_address && a->write_width == b->write_width &&
        a->write_value == b->write_value);
    CHECK(a->fault_address == b->fault_address && a->fault_access == b->fault_access &&
        a->fault_level == b->fault_level && a->fault_status == b->fault_status);
    for (unsigned page = 0; page < TP_RAM_SIZE; page += 4096)
        CHECK(avz_guest_memory_page_write_generation(a->ram, TP_RAM_BASE + page, TP_RAM_BASE) ==
            avz_guest_memory_page_write_generation(b->ram, TP_RAM_BASE + page, TP_RAM_BASE));
    AVZGuestDirtyRange ar[4], br[4];
    size_t ac = avz_guest_memory_dirty_ranges(a->ram, 0, TP_RAM_SIZE, 0, UINT64_MAX, ar, 4);
    size_t bc = avz_guest_memory_dirty_ranges(b->ram, 0, TP_RAM_SIZE, 0, UINT64_MAX, br, 4);
    CHECK(ac == bc && ac <= 4);
    for (size_t i = 0; i < ac; i++) CHECK(ar[i].offset == br[i].offset && ar[i].length == br[i].length);
}

static void memory_case(NativeMemory *a, NativeMemory *b, uint32_t raw, uint64_t base_value)
{
    uint32_t words[] = {0x910004a5, 0xb10004c6, raw, 0xd503201f, raw};
    AVZNativeInstruction code[5];
    decode(words, 5, code);
    CHECK(!avz_tp_supports_instruction(&code[2]));
    CHECK(avz_tp_supports_instruction_with_memory(&code[2]));
    AVZThreadedPrototype *program = avz_tp_create(words, 5, 0x8000);
    CHECK(program);
    for (unsigned budget = 0; budget <= 5; budget++) {
        AVZNativeCPU actual = initial(0x8000, UINT64_C(0xfedcba9876543210)), expected;
        if (code[2].rn == 31) actual.sp = base_value; else actual.x[code[2].rn] = base_value;
        expected = actual;
        AVZNativeCPU no_memory = actual;
        AVZNativeBlockResult no_context = avz_tp_run_with_memory(program, budget, &no_memory, NULL);
        /* These differential cases exercise complete-helper boundaries. Hot
         * continuation is covered by threaded-memory-continuation-regression. */
        avz_native_memory_fast_path_invalidate_translation(a->path);
        AVZNativeBlockResult got = avz_tp_run_with_memory(program, budget, &actual, a->path);
        AVZNativeBlockResult want = reference(code, 5, 0x8000, budget < 3 ? budget : 3,
            &expected, 1, avz_native_fast_memory_read, avz_native_fast_memory_write, b->path);
        CHECK(got.steps == want.steps);
        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
        uint32_t status = budget >= 3 && want.steps < 3 ? AVZ_TP_STATUS_MEMORY_FAULT :
            budget >= 3 ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS;
        CHECK(got.status == status && got.unsupported_instruction == 0);
        CHECK(got.generic_dispatches == got.steps);
        CHECK(no_context.steps == (budget < 2 ? budget : 2));
        CHECK(no_context.status == (budget <= 2 ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_UNSUPPORTED));
        CHECK(no_context.unsupported_instruction == (budget <= 2 ? 0 : raw));
        same_memory(a, b);
        if (got.status == AVZ_TP_STATUS_REVALIDATE) {
            CHECK(actual.pc == 0x800c);
            got = avz_tp_run_with_memory(program, 1, &actual, a->path);
            want = reference(code, 5, 0x8000, 1, &expected, 0,
                avz_native_fast_memory_read, avz_native_fast_memory_write, b->path);
            same_result(got, want);
            CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
            same_memory(a, b);
        }
        cases++;
    }
    avz_tp_destroy(program);
}

static void store_callback_cases(void)
{
    NativeMemory a, b;
    native_memory_init(&a);
    native_memory_init(&b);
    a.force_slow = b.force_slow = 1;
    const uint64_t values[] = {0, 0x1234, UINT64_C(0xfedcba9876543210), UINT64_MAX};
    const uint64_t masks[] = {UINT8_MAX, UINT16_MAX, UINT32_MAX, UINT64_MAX};
    for (unsigned size = 0; size < 4; size++)
        for (unsigned zero = 0; zero < 2; zero++) {
            uint32_t words[] = {0x39000000 | (size << 30) | (10u << 5) |
                (zero ? 31u : 0u), 0xd503201f};
            AVZNativeInstruction code[2];
            decode(words, 2, code);
            AVZThreadedPrototype *program = avz_tp_create(words, 2, 0x8000);
            CHECK(program);
            for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); i++)
                for (unsigned fail = 0; fail < 2; fail++)
                    for (unsigned budget = 0; budget <= 2; budget++) {
                        a.fail = b.fail = (int)fail;
                        a.write_address = b.write_address = UINT64_MAX;
                        a.write_width = b.write_width = 0;
                        a.write_value = b.write_value = UINT64_MAX;
                        unsigned writes_before = a.writes;
                        AVZNativeCPU actual = initial(0x8000, values[i]), expected;
                        actual.x[10] = TP_RAM_BASE + 24;
                        expected = actual;
                        AVZNativeBlockResult got = avz_tp_run_with_memory(
                            program, budget, &actual, a.path);
                        AVZNativeBlockResult want = reference(code, 2, 0x8000,
                            budget ? 1 : 0, &expected, 1,
                            avz_native_fast_memory_read, avz_native_fast_memory_write, b.path);
                        CHECK(got.steps == want.steps);
                        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
                        CHECK(got.status == (!budget ? AVZ_NATIVE_STATUS_MAX_STEPS :
                            fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
                        CHECK(got.unsupported_instruction == 0);
                        CHECK(a.writes - writes_before == (budget != 0));
                        if (budget) {
                            CHECK(a.write_address == TP_RAM_BASE + 24);
                            CHECK(a.write_width == (1u << size));
                            CHECK(a.write_value == (zero ? 0 : values[i] & masks[size]));
                        } else {
                            CHECK(a.write_address == UINT64_MAX && a.write_width == 0 &&
                                a.write_value == UINT64_MAX);
                        }
                        same_memory(&a, &b);
                        cases++;
                    }
            avz_tp_destroy(program);
        }
    native_memory_destroy(&a);
    native_memory_destroy(&b);
}

static void native_memory_cases(void)
{
    NativeMemory a, b;
    native_memory_init(&a);
    native_memory_init(&b);
    const uint64_t addresses[] = {TP_RAM_BASE, TP_RAM_BASE + 1, TP_RAM_BASE + 3,
        TP_RAM_BASE + 7, TP_RAM_BASE + 4092, TP_RAM_BASE + 4095, TP_RAM_BASE + 4096,
        TP_RAM_BASE + TP_RAM_SIZE - 8, TP_RAM_BASE + TP_RAM_SIZE - 1, UINT64_MAX};
    for (unsigned observed = 0; observed < 2; observed++) {
        if (observed) {
            CHECK(avz_guest_memory_register_host_range(a.ram, 0, TP_RAM_SIZE));
            CHECK(avz_guest_memory_register_host_range(b.ram, 0, TP_RAM_SIZE));
        }
        for (unsigned size = 0; size < 4; size++)
            for (unsigned load = 0; load < 2; load++)
                for (unsigned regs = 0; regs < 3; regs++)
                    for (unsigned address = 0; address < sizeof(addresses) / sizeof(addresses[0]); address++) {
                        unsigned rn = regs == 1 ? 31 : 10, rt = regs == 1 ? 31 : regs == 2 ? 10 : 0;
                        unsigned immediate = address % 3 == 0 ? 4095 : address % 3;
                        uint32_t raw = 0x39000000 | (size << 30) | (load << 22) |
                            (immediate << 10) | (rn << 5) | rt;
                        memory_case(&a, &b, raw, addresses[address] - ((uint64_t)immediate << size));
                    }
    }
    native_memory_destroy(&a);
    native_memory_destroy(&b);
    /* Native translation faults must not fall through to a slow callback. */
    native_memory_init(&a);
    native_memory_init(&b);
    memset(avz_guest_memory_bytes(a.ram) + 8192, 0, 4096);
    memset(avz_guest_memory_bytes(b.ram) + 8192, 0, 4096);
    AVZNativeStage1TranslationState state = {
        .sctlr_el1 = 1, .tcr_el1 = 16, .ttbr0_el1 = TP_RAM_BASE + 8192, .current_el = 1
    };
    avz_native_memory_fast_path_set_stage1_translation(a.path, &state, native_fault);
    avz_native_memory_fast_path_set_stage1_translation(b.path, &state, native_fault);
    memory_case(&a, &b, 0xf9400140, 0x2000);
    memory_case(&a, &b, 0xf9000140, 0x2000);
    CHECK(a.faults > 0 && a.reads == 0 && a.writes == 0);
    native_memory_destroy(&a);
    native_memory_destroy(&b);
    /* Valid EL1 read-only block: loads succeed; stores report permission faults. */
    native_memory_init(&a);
    native_memory_init(&b);
    memset(avz_guest_memory_bytes(a.ram) + 8192, 0, 8192);
    memset(avz_guest_memory_bytes(b.ram) + 8192, 0, 8192);
    uint64_t table = (TP_RAM_BASE + 12288) | UINT64_C(3);
    uint64_t read_only_block = UINT64_C(1) | (UINT64_C(1) << 10) | (UINT64_C(2) << 6);
    memcpy(avz_guest_memory_bytes(a.ram) + 8192, &table, sizeof(table));
    memcpy(avz_guest_memory_bytes(b.ram) + 8192, &table, sizeof(table));
    memcpy(avz_guest_memory_bytes(a.ram) + 12288, &read_only_block, sizeof(read_only_block));
    memcpy(avz_guest_memory_bytes(b.ram) + 12288, &read_only_block, sizeof(read_only_block));
    avz_native_memory_fast_path_set_stage1_translation(a.path, &state, native_fault);
    avz_native_memory_fast_path_set_stage1_translation(b.path, &state, native_fault);
    memory_case(&a, &b, 0xf9400140, TP_RAM_BASE + 256);
    CHECK(a.faults == 0 && a.reads == 0);
    memory_case(&a, &b, 0xf9000140, TP_RAM_BASE + 256);
    CHECK(a.faults > 0 && a.writes == 0 && a.fault_access == AVZ_NATIVE_MEMORY_ACCESS_WRITE);
    native_memory_destroy(&a);
    native_memory_destroy(&b);
    /* Slow callbacks may destroy the snapshot on either success or failure. */
    for (unsigned load = 0; load < 2; load++)
        for (unsigned fail = 0; fail < 2; fail++) {
            native_memory_init(&a);
            native_memory_init(&b);
            a.force_slow = b.force_slow = 1;
            a.fail = b.fail = (int)fail;
            uint32_t words[] = {load ? 0xf9400140 : 0xf9000140, 0x91000400};
            AVZNativeInstruction code[2];
            decode(words, 2, code);
            AVZThreadedPrototype *program = avz_tp_create(words, 2, 0x8000);
            CHECK(program);
            a.destroy_on_access = program;
            AVZNativeCPU actual = initial(0x8000, 123), expected = actual;
            actual.x[10] = expected.x[10] = TP_RAM_BASE;
            AVZNativeBlockResult got = avz_tp_run_with_memory(program, 2, &actual, a.path);
            AVZNativeBlockResult want = reference(code, 2, 0x8000, 1, &expected, 0,
                avz_native_fast_memory_read, avz_native_fast_memory_write, b.path);
            CHECK(a.destroyed == 1 && a.destroy_on_access == NULL);
            CHECK(got.steps == want.steps && memcmp(&actual, &expected, sizeof(actual)) == 0);
            CHECK(got.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
            same_memory(&a, &b);
            native_memory_destroy(&a);
            native_memory_destroy(&b);
            cases++;
        }
}

static double seconds(void)
{
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
}

static uint64_t checksum(const AVZNativeCPU *cpu)
{
    uint64_t hash = cpu->pc ^ cpu->sp ^ cpu->pstate;
    for (unsigned i = 0; i < 31; i++) hash = (hash ^ cpu->x[i]) * UINT64_C(1099511628211);
    return hash;
}

static size_t workload_code(unsigned workload, uint32_t *words, const char **name)
{
    static const char *names[] = {"alu-31-branch", "alu-conditional-branch",
        "shifted-logical-carry", "extended32-carry"};
    CHECK(workload < 4);
    *name = names[workload];
    if (workload == 0) {
        for (unsigned i = 0; i < 31; i++) words[i] = 0x91000400;
        words[31] = 0x17ffffe1;
        return 32;
    }
    if (workload == 1) {
        words[0] = 0x91000400;
        words[1] = 0xf1000421;
        words[2] = 0x54ffffc1;
        return 3;
    }
    words[0] = workload == 2 ? 0x8b020800 : 0x8b22cbe0;
    words[1] = workload == 2 ? 0xcac01c63 : 0x7a000063;
    words[2] = workload == 2 ? 0xba030000 : 0x4ac32c00;
    words[3] = 0xf1000421;
    words[4] = 0x54ffff81;
    return 5;
}

static void workload_correctness(void)
{
    for (unsigned workload = 0; workload < 4; workload++) {
        uint32_t words[32];
        const char *name;
        size_t count = workload_code(workload, words, &name);
        (void)name;
        AVZNativeInstruction code[32];
        decode(words, count, code);
        for (size_t i = 0; i < count; i++) CHECK(avz_tp_supports_instruction(&code[i]));
        AVZThreadedPrototype *program = avz_tp_create(words, count, 0x8000);
        CHECK(program);
        AVZNativeCPU cpu = initial(0x8000, 0);
        cpu.x[1] = UINT64_MAX;
        cpu.x[2] = 37;
        cpu.x[3] = UINT64_C(0x8000000000000001);
        for (unsigned budget = 0; budget < 65; budget++)
            compare(program, code, count, 0x8000, budget, cpu);
        compare(program, code, count, 0x8000, 10001, cpu);
        avz_tp_destroy(program);
    }
}

static double bench_once(const AVZThreadedPrototype *program,
    const AVZNativeInstruction *code, size_t count, unsigned mode, uint64_t steps,
    AVZNativeCPU *cpu, AVZNativeBlockResult *result)
{
    *cpu = initial(0x8000, 0);
    cpu->x[1] = UINT64_MAX;
    cpu->x[2] = 37;
    cpu->x[3] = UINT64_C(0x8000000000000001);
    double start = seconds();
    *result = mode == 2 ? avz_tp_run(program, steps, cpu) :
        reference(code, count, 0x8000, steps, cpu, mode == 1, NULL, NULL, NULL);
    double elapsed = seconds() - start;
    CHECK(result->steps == steps && result->status == AVZ_NATIVE_STATUS_MAX_STEPS);
    return elapsed;
}

static int order_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void benchmark(void)
{
    const char *names[] = {"reference-switch", "existing-threaded", "musttail-prototype"};
    enum { ROUNDS = 6 };
    for (unsigned workload = 0; workload < 4; workload++) {
        const char *name;
        uint32_t words[32];
        size_t count = workload_code(workload, words, &name);
        AVZNativeInstruction code[32];
        decode(words, count, code);
        AVZThreadedPrototype *program = avz_tp_create(words, count, 0x8000);
        CHECK(program);
        const unsigned preparations = 10000;
        double start = seconds();
        for (unsigned i = 0; i < preparations; i++) {
            AVZThreadedPrototype *temporary = avz_tp_create(words, count, 0x8000);
            CHECK(temporary);
            avz_tp_destroy(temporary);
        }
        printf("prepare workload=%s instructions=%zu bytes=%zu iterations=%u ns_per_program=%.1f\n",
            name, count, avz_tp_program_bytes(program), preparations,
            (seconds() - start) * 1e9 / preparations);
        AVZNativeCPU cpu[3];
        AVZNativeBlockResult result[3];
        for (unsigned mode = 0; mode < 3; mode++)
            (void)bench_once(program, code, count, mode, 1000000, &cpu[mode], &result[mode]);
        double samples[3][ROUNDS];
        for (unsigned round = 0; round < ROUNDS; round++) {
            for (unsigned slot = 0; slot < 3; slot++) {
                unsigned mode = round & 1 ? 2 - slot : slot;
                double elapsed = bench_once(program, code, count, mode, 30000000,
                    &cpu[mode], &result[mode]);
                samples[mode][round] = elapsed;
                printf("sample workload=%s round=%u mode=%s steps=%" PRIu64
                    " seconds=%.6f mips=%.3f fast_steps=%" PRIu64 " checksum=%016" PRIx64 "\n",
                    name, round + 1, names[mode], result[mode].steps, elapsed,
                    result[mode].steps / elapsed / 1e6, result[mode].fast_path_steps,
                    checksum(&cpu[mode]));
            }
            CHECK(memcmp(&cpu[0], &cpu[1], sizeof(cpu[0])) == 0);
            CHECK(memcmp(&cpu[0], &cpu[2], sizeof(cpu[0])) == 0);
        }
        double medians[3];
        for (unsigned mode = 0; mode < 3; mode++) {
            qsort(samples[mode], ROUNDS, sizeof(double), order_double);
            medians[mode] = (samples[mode][2] + samples[mode][3]) / 2;
            printf("summary workload=%s mode=%s median_seconds=%.6f min_seconds=%.6f max_seconds=%.6f\n",
                name, names[mode], medians[mode], samples[mode][0], samples[mode][ROUNDS - 1]);
        }
        printf("ratio workload=%s switch_over_prototype=%.3f existing_over_prototype=%.3f\n",
            name, medians[0] / medians[2], medians[1] / medians[2]);
        avz_tp_destroy(program);
    }
}

int main(int argc, char **argv)
{
    CHECK(argc == 1 || (argc == 2 &&
        (!strcmp(argv[1], "--benchmark") || !strcmp(argv[1], "--disabled"))));
    if (argc == 2 && !strcmp(argv[1], "--disabled")) {
        CHECK(!avz_tp_available());
        uint32_t word = 0x91000400;
        CHECK(!avz_tp_create(&word, 1, 0x8000));
        AVZNativeCPU cpu = initial(0x8000, 1), before = cpu;
        AVZNativeBlockResult got = avz_tp_run(NULL, 1, &cpu);
        CHECK(got.status == AVZ_TP_STATUS_DISABLED && got.steps == 0);
        CHECK(memcmp(&cpu, &before, sizeof(cpu)) == 0);
        CHECK(avz_tp_run_with_memory(NULL, 1, &cpu, NULL).status == AVZ_TP_STATUS_DISABLED);
        CHECK(!avz_tp_supports_instruction(NULL));
        CHECK(!avz_tp_supports_instruction_with_memory(NULL));
        CHECK(avz_tp_program_bytes(NULL) == 0);
        avz_tp_destroy(NULL);
        puts("disabled prototype: no execution, no allocation, CPU unchanged");
        return 0;
    }
    CHECK(avz_tp_available());
    arithmetic();
    register_arithmetic();
    register_sequences();
    branches();
    sequences();
    boundaries();
    fault_handoff();
    store_callback_cases();
    native_memory_cases();
    workload_correctness();
    printf("threaded prototype differential: %" PRIu64 " cases passed\n", cases);
    if (argc == 2) benchmark();
    return 0;
}
