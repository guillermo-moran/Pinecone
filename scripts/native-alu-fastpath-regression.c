#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdio.h>
#include <time.h>

/* Compile the identical harness against either the working or frozen source. */
#ifndef AVZ_NATIVE_REFERENCE_PATH
#define AVZ_NATIVE_REFERENCE_PATH "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_NATIVE_REFERENCE_PATH

#ifdef AVZ_DISABLE_COMPUTED_GOTO
#error This regression requires the mapped handler path, not its generic fallback
#endif

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))
#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "line=%d raw=%08" PRIx32 " case=%" PRIu64 ": %s\n", \
            __LINE__, current_raw, checks, #test); exit(1); \
} } while (0)

enum { SHIFTED, EXTENDED, CARRY, TRACE_WORDS = 64 };
static const uint64_t entry = 0x8000;
static uint32_t current_raw;
static uint64_t checks;

typedef struct {
    AVZNativeInstruction code[TRACE_WORDS];
    uint64_t pcs[TRACE_WORDS];
    uint8_t candidates[TRACE_WORDS];
    uint16_t offsets[2];
    size_t count;
} ALUTrace;

static uint32_t encode(unsigned family, unsigned bits, unsigned subtract,
    unsigned flags, unsigned option, unsigned shift,
    unsigned rd, unsigned rn, unsigned rm)
{
    uint32_t raw = family == SHIFTED ? 0x0b000000u :
        family == EXTENDED ? 0x0b200000u : 0x1a000000u;
    raw |= ((uint32_t)(bits == 64) << 31) | (subtract << 30) |
        (flags << 29) | (rm << 16) | (rn << 5) | rd;
    if (family != CARRY)
        raw |= (option << (family == SHIFTED ? 22 : 13)) | (shift << 10);
    return raw;
}

static void make_trace(ALUTrace *trace, uint32_t raw, size_t count, unsigned family)
{
    static const unsigned kinds[] = {AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER,
        AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER, AVZ_NATIVE_OP_ADD_SUB_CARRY};
    current_raw = raw;
    CHECK(count > 0 && count <= TRACE_WORDS);
    memset(trace, 0, sizeof(*trace));
    trace->count = count;
    trace->offsets[1] = (uint16_t)count;
    for (size_t i = 0; i < count; i++) {
        CHECK(avz_native_decode_instruction(raw, &trace->code[i]));
        CHECK(trace->code[i].kind == kinds[family]);
        trace->pcs[i] = entry + 4 * i;
        trace->candidates[i] = AVZ_NATIVE_SEMANTIC_NONE;
    }
}

static AVZNativeBlockResult mapped(const ALUTrace *trace, AVZNativeCPU *cpu,
    AVZNativeBlockCache *cache, uint64_t budget)
{
    return avz_native_run_threaded_decoded_block_cpu_mapped(
        trace->code, trace->count, entry, budget, cpu,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, trace->candidates, trace->pcs, trace->offsets, 1, cache,
        avz_native_block_cache_code_mutation_epoch(cache),
        avz_native_block_cache_shared_code_mutation_epoch(cache), 0);
}

static void generic(const ALUTrace *trace, AVZNativeCPU *cpu, size_t count)
{
    for (size_t i = 0; i < count; i++)
        CHECK(execute_decoded_instruction(&trace->code[i], cpu,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL) == 1);
}

static AVZNativeCPU initial_cpu(void)
{
    AVZNativeCPU cpu;
    memset(&cpu, 0, sizeof(cpu));
    for (unsigned r = 0; r < 31; r++)
        cpu.x[r] = UINT64_C(0xfedcba9876543210) ^ (r * UINT64_C(0x0102040810204081));
    for (unsigned r = 0; r < 32; r++) {
        cpu.v[r].low = UINT64_C(0x123456789abcdef0) ^ r;
        cpu.v[r].high = UINT64_C(0xfedcba9876543210) ^ r;
    }
    cpu.pc = entry;
    cpu.sp = UINT64_C(0xfedcba9876543280);
    cpu.pstate = UINT64_C(0x12345678000003c5);
    cpu.fpcr = 0x400000;
    cpu.fpsr = 0x8000000;
    cpu.exclusive_address = 0x123400;
    cpu.exclusive_generation = 123;
    cpu.exclusive_size = 8;
    cpu.exclusive_valid = 1;
    return cpu;
}

static void check_state(const AVZNativeCPU *actual, const AVZNativeCPU *expected)
{
    if (memcmp(actual, expected, sizeof(*actual)) != 0) {
        fprintf(stderr, "pc=%016" PRIx64 "/%016" PRIx64
            " sp=%016" PRIx64 "/%016" PRIx64
            " pstate=%016" PRIx64 "/%016" PRIx64 "\n",
            actual->pc, expected->pc, actual->sp, expected->sp,
            actual->pstate, expected->pstate);
        for (unsigned r = 0; r < 31; r++)
            if (actual->x[r] != expected->x[r])
                fprintf(stderr, "x%u=%016" PRIx64 "/%016" PRIx64 "\n",
                    r, actual->x[r], expected->x[r]);
        CHECK(0 && "complete CPU state differs");
    }
}

static void check_result(AVZNativeBlockResult result, uint64_t steps)
{
    CHECK(result.steps == steps);
    CHECK(result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(result.mapped_blocks == (steps != 0));
    CHECK(result.generic_dispatches == 0);
    CHECK(result.fast_path_steps == 0 && result.fast_path_hits == 0);
    CHECK(result.unsupported_instruction == 0);
}

static void compare(const ALUTrace *trace, const AVZNativeCPU *before,
    AVZNativeBlockCache *cache, size_t budget)
{
    AVZNativeCPU actual = *before, expected = *before;
    check_result(mapped(trace, &actual, cache, budget), budget);
    generic(trace, &expected, budget);
    check_state(&actual, &expected);
    CHECK((actual.pstate & ~UINT64_C(0xf0000000)) ==
          (before->pstate & ~UINT64_C(0xf0000000)));
    if (!(trace->code[0].flags & 2)) CHECK(actual.pstate == before->pstate);
    if (budget && trace->code[0].kind == AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER) {
        /* The raw executor supports shifted ALU, but not extended/carry ALU. */
        AVZNativeCPU raw_cpu = *before;
        uint32_t words[TRACE_WORDS];
        for (size_t i = 0; i < trace->count; i++) words[i] = trace->code[i].raw;
        AVZNativeBlockResult result = avz_native_run_block(
            words, trace->count, entry, budget, &raw_cpu);
        CHECK(result.steps == budget && result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(result.unsupported_instruction == 0);
        check_state(&actual, &raw_cpu);
    }
    checks++;
}

static void operand_matrix(ALUTrace *trace, AVZNativeBlockCache *cache)
{
    static const uint64_t edges[] = {
        0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff,
        0x7fffffff, 0x80000000, 0xffffffff,
        UINT64_C(0x100000000), UINT64_C(0x7fffffffffffffff),
        UINT64_C(0x8000000000000000), UINT64_MAX,
        UINT64_C(0xdeadbeef80000080), UINT64_C(0xaaaaaaaa55555555)
    };
    const AVZNativeInstruction *d = &trace->code[0];
    for (size_t l = 0; l < COUNT(edges); l++)
    for (size_t r = 0; r < COUNT(edges); r++)
    for (unsigned carry = 0; carry < 2; carry++) {
        AVZNativeCPU cpu = initial_cpu();
        if (d->rn != 31) cpu.x[d->rn] = edges[l];
        /* Keep a nonzero SP sentinel even when rn=31 means XZR. */
        if (d->rn == 31 && d->kind == AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER)
            cpu.sp = edges[l];
        if (d->rm != 31) cpu.x[d->rm] = edges[r];
        unsigned nzcv = ((unsigned)(l * 3 + r * 5) & 13u) | (carry << 1);
        cpu.pstate |= (uint64_t)nzcv << 28;
        compare(trace, &cpu, cache, 1);
    }
}

static void regressions(AVZNativeBlockCache *cache)
{
    /* rd/rn/rm: independent operands, each SP/XZR position, and aliases. */
    static const unsigned regs[][3] = {
        {0, 1, 2}, {31, 1, 2}, {0, 31, 2}, {0, 1, 31},
        {31, 31, 2}, {31, 1, 31}, {0, 31, 31}, {31, 31, 31},
        {1, 1, 2}, {2, 1, 2}, {0, 1, 1}, {1, 1, 1}
    };
    ALUTrace trace;
    for (unsigned family = SHIFTED; family <= CARRY; family++)
    for (unsigned bits = 32; bits <= 64; bits += 32)
    for (unsigned sub = 0; sub < 2; sub++)
    for (unsigned flags = 0; flags < 2; flags++)
    for (size_t reg = 0; reg < COUNT(regs); reg++) {
        const unsigned shifts[] = {0, 1, 7, bits / 2, bits - 1};
        unsigned options = family == SHIFTED ? 3 : family == EXTENDED ? 8 : 1;
        for (unsigned option = 0; option < options; option++)
        for (unsigned s = 0; s < (family == CARRY ? 1u : 5u); s++) {
            unsigned shift = family == SHIFTED ? shifts[s] : s;
            uint32_t raw = encode(family, bits, sub, flags, option, shift,
                regs[reg][0], regs[reg][1], regs[reg][2]);
            make_trace(&trace, raw, 1, family);
            operand_matrix(&trace, cache);
        }
    }

    /* Repeated dependent ALU exercises budget exits and updated carry inputs. */
    for (unsigned family = SHIFTED; family <= CARRY; family++)
    for (unsigned bits = 32; bits <= 64; bits += 32)
    for (unsigned sub = 0; sub < 2; sub++)
    for (unsigned flags = 0; flags < 2; flags++) {
        make_trace(&trace, encode(family, bits, sub, flags,
            family == EXTENDED ? 6 : 0, 0, 1, 1, 2), TRACE_WORDS, family);
        for (unsigned nzcv = 0; nzcv < 16; nzcv++) {
            AVZNativeCPU cpu = initial_cpu();
            cpu.x[1] = UINT64_MAX;
            cpu.x[2] = 1;
            cpu.pstate |= (uint64_t)nzcv << 28;
            const size_t budgets[] = {0, 1, 2, TRACE_WORDS - 1, TRACE_WORDS};
            for (size_t b = 0; b < COUNT(budgets); b++)
                compare(&trace, &cpu, cache, budgets[b]);
        }
    }
    printf("PASS native ALU mapped/generic regression: %" PRIu64 " cases\n", checks);
}

static double seconds(clockid_t clock)
{
    struct timespec now;
    CHECK(clock_gettime(clock, &now) == 0);
    return now.tv_sec + now.tv_nsec * 1e-9;
}

static void benchmark(AVZNativeBlockCache *cache)
{
    static const char *names[] = {"shifted", "extended", "carry"};
    const unsigned repeats = 20000;
    ALUTrace trace;
    for (unsigned family = SHIFTED; family <= CARRY; family++)
    for (unsigned bits = 32; bits <= 64; bits += 32)
    for (unsigned sub = 0; sub < 2; sub++)
    for (unsigned flags = 0; flags < 2; flags++)
    for (unsigned carry = 0; carry < (family == CARRY ? 2u : 1u); carry++) {
        make_trace(&trace, encode(family, bits, sub, flags,
            family == EXTENDED ? 6 : 0, family == CARRY ? 0 : 1,
            1, 1, 2), TRACE_WORDS, family);
        AVZNativeCPU start = initial_cpu();
        start.pstate |= (uint64_t)carry << 29;
        compare(&trace, &start, cache, TRACE_WORDS);
        AVZNativeCPU warm = start;
        for (unsigned i = 0; i < 100; i++) {
            warm.pc = entry;
            check_result(mapped(&trace, &warm, cache, TRACE_WORDS), TRACE_WORDS);
        }
        AVZNativeCPU cpu = start;
        uint64_t steps = 0, generic_dispatches = 0, semantic_steps = 0, blocks = 0;
        uint32_t status = 0, unsupported = 0;
        double begin = seconds(CLOCK_MONOTONIC);
        double thread_begin = seconds(CLOCK_THREAD_CPUTIME_ID);
        for (unsigned i = 0; i < repeats; i++) {
            cpu.pc = entry;
            AVZNativeBlockResult result = mapped(&trace, &cpu, cache, TRACE_WORDS);
            steps += result.steps;
            generic_dispatches += result.generic_dispatches;
            semantic_steps += result.fast_path_steps;
            blocks += result.mapped_blocks;
            status |= result.status;
            unsupported |= result.unsupported_instruction;
        }
        double thread_elapsed = seconds(CLOCK_THREAD_CPUTIME_ID) - thread_begin;
        double elapsed = seconds(CLOCK_MONOTONIC) - begin;
        CHECK(steps == (uint64_t)repeats * TRACE_WORDS && blocks == repeats);
        CHECK(generic_dispatches == 0 && semantic_steps == 0 && unsupported == 0);
        CHECK(status == AVZ_NATIVE_STATUS_MAX_STEPS && elapsed > 0 && thread_elapsed > 0);
        AVZNativeCPU expected = start;
        for (unsigned i = 0; i < repeats; i++) {
            expected.pc = entry;
            generic(&trace, &expected, TRACE_WORDS);
        }
        check_state(&cpu, &expected);
        if (!flags) CHECK(cpu.pstate == start.pstate);
        printf("family=%s bits=%u sub=%u flags=%u carry=%u steps=%" PRIu64
            " ns_per_step=%.3f thread_cpu_ns_per_step=%.3f"
            " x1=%016" PRIx64 " pstate=%016" PRIx64 "\n",
            names[family], bits, sub, flags, carry, steps,
            elapsed * 1e9 / steps, thread_elapsed * 1e9 / steps, cpu.x[1], cpu.pstate);
    }
}

int main(int argc, char **argv)
{
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--benchmark") != 0)) {
        fprintf(stderr, "usage: %s [--benchmark]\n", argv[0]);
        return 2;
    }
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    CHECK(cache != NULL);
    if (argc == 2) benchmark(cache); else regressions(cache);
    avz_native_block_cache_destroy(cache);
    return 0;
}
