#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <time.h>

#ifndef AVZ_OVERHEAD_NATIVE_SOURCE
#define AVZ_OVERHEAD_NATIVE_SOURCE "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_OVERHEAD_NATIVE_SOURCE

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); \
} } while (0)

enum { WORDS = 1024, BLOCKS = 32, DATA = 0x100000 };
static uint64_t digest = UINT64_C(14695981039346656037), cases;
static uint64_t hardware_cases;
static uint64_t random_state = UINT64_C(0x42dbeef123456789);

static uint64_t random64(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

static void hash(const void *bytes, size_t length)
{
    const unsigned char *p = bytes;
    for (size_t i = 0; i < length; i++) {
        digest ^= p[i];
        digest *= UINT64_C(1099511628211);
    }
}

typedef struct {
    AVZNativeInstruction code[WORDS];
    uint64_t pcs[WORDS];
    uint16_t offsets[BLOCKS + 1];
    uint8_t candidates[WORDS];
    size_t count, blocks;
} Trace;

typedef struct {
    uint64_t value, calls, fail_at, observations;
    AVZNativeCPU *cpu;
} Memory;

static int access_memory(Memory *m, uint64_t address, uint8_t width)
{
    /* Fault and successful callbacks must see the exact architectural PC. */
    m->observations = m->observations * 33 + m->cpu->pc + m->cpu->pstate;
    CHECK(address == DATA && width == 8);
    return m->calls++ != m->fail_at;
}

static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value)
{
    Memory *m = opaque;
    if (!access_memory(m, address, width)) return 0;
    *value = m->value;
    return 1;
}

static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value)
{
    Memory *m = opaque;
    if (!access_memory(m, address, width)) return 0;
    m->value = value;
    return 1;
}

static AVZNativeCPU initial_cpu(void)
{
    AVZNativeCPU cpu = {0};
    for (unsigned r = 0; r < 31; r++) cpu.x[r] = random64();
    for (unsigned r = 0; r < 32; r++) {
        cpu.v[r].low = random64();
        cpu.v[r].high = random64();
    }
    cpu.x[10] = DATA;
    cpu.pc = 0x8000;
    cpu.sp = random64();
    cpu.pstate = (random64() & UINT64_C(0xf0000000)) | 5;
    cpu.exclusive_address = DATA;
    cpu.exclusive_generation = 7;
    cpu.exclusive_size = 8;
    cpu.exclusive_valid = 1;
    return cpu;
}

static AVZNativeBlockResult mapped(Trace *trace, uint64_t budget,
    AVZNativeCPU *cpu, Memory *memory, AVZNativeBlockCache *cache, int linear)
{
    return avz_native_run_threaded_decoded_block_cpu_mapped(
        trace->code, trace->count, trace->pcs[0], budget, cpu,
        read_memory, write_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        memory, NULL, trace->candidates, linear ? NULL : trace->pcs,
        linear ? NULL : trace->offsets, linear ? 0 : trace->blocks,
        cache, avz_native_block_cache_code_mutation_epoch(cache), 0, 0);
}

static void hardware_check(const AVZNativeInstruction *instruction,
    const AVZNativeCPU *initial, const AVZNativeCPU *actual)
{
#if defined(__aarch64__)
    AVZNativeCPU expected = *initial;
    uint64_t lhs = read_base_register(initial, instruction->rn);
    uint64_t rhs = (uint64_t)instruction->immediate;
    uint64_t value, nzcv;
    if (instruction->bits == 64) {
        if (instruction->flags & 1)
            __asm__("subs %0, %2, %3\n\tmrs %1, nzcv"
                : "=&r"(value), "=r"(nzcv) : "r"(lhs), "r"(rhs) : "cc");
        else
            __asm__("adds %0, %2, %3\n\tmrs %1, nzcv"
                : "=&r"(value), "=r"(nzcv) : "r"(lhs), "r"(rhs) : "cc");
    } else {
        if (instruction->flags & 1)
            __asm__("subs %w0, %w2, %w3\n\tmrs %1, nzcv"
                : "=&r"(value), "=r"(nzcv) : "r"(lhs), "r"(rhs) : "cc");
        else
            __asm__("adds %w0, %w2, %w3\n\tmrs %1, nzcv"
                : "=&r"(value), "=r"(nzcv) : "r"(lhs), "r"(rhs) : "cc");
    }
    if (instruction->flags & 2) {
        expected.pstate = (expected.pstate & ~UINT64_C(0xf0000000)) | nzcv;
        write_register(&expected, instruction->rd, value);
    } else {
        write_base_register(&expected, instruction->rd, value);
    }
    expected.pc += 4;
    CHECK(memcmp(actual, &expected, sizeof(expected)) == 0);
    hardware_cases++;
#else
    (void)instruction; (void)initial; (void)actual;
#endif
}

static void compare(Trace *trace, uint64_t budget, uint64_t fail_at,
    AVZNativeCPU initial, AVZNativeBlockCache *cache, int linear)
{
    AVZNativeCPU actual = initial, expected = initial;
    Memory am = {.value = 19, .fail_at = fail_at, .cpu = &actual};
    Memory em = {.value = 19, .fail_at = fail_at, .cpu = &expected};
    AVZNativeBlockResult result = mapped(trace, budget, &actual, &am, cache, linear);
    uint64_t steps = 0;
    while (steps < budget) {
        size_t index = 0;
        while (index < trace->count && trace->pcs[index] != expected.pc) index++;
        if (index == trace->count) break;
        if (!execute_decoded_instruction(&trace->code[index], &expected,
                read_memory, write_memory, NULL, NULL, NULL, NULL, NULL, NULL,
                NULL, 0, &em)) break;
        steps++;
    }
    CHECK(result.steps == steps);
    CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    CHECK(am.value == em.value && am.calls == em.calls && am.observations == em.observations);
    CHECK(result.fast_path_steps == 0 && result.fast_path_hits == 0);
    if (steps == 1 && trace->count == 1)
        hardware_check(&trace->code[0], &initial, &actual);
    hash(&actual, sizeof(actual));
    hash(&result.steps, sizeof(result.steps));
    hash(&result.status, sizeof(result.status));
    hash(&result.mapped_blocks, sizeof(result.mapped_blocks));
    hash(&result.generic_dispatches, sizeof(result.generic_dispatches));
    hash(&result.fast_path_steps, sizeof(result.fast_path_steps));
    hash(&result.fast_path_hits, sizeof(result.fast_path_hits));
    hash(&result.unsupported_instruction, sizeof(result.unsupported_instruction));
    hash(&am.value, sizeof(am.value));
    hash(&am.observations, sizeof(am.observations));
    cases++;
}

static uint32_t immediate(unsigned sf, unsigned flags, unsigned shift,
    unsigned imm, unsigned rn, unsigned rd)
{
    return 0x11000000u | sf << 31 | (flags & 1) << 30 | (flags >> 1) << 29 |
        shift << 22 | imm << 10 | rn << 5 | rd;
}

static void arithmetic_tests(AVZNativeBlockCache *cache)
{
    static const uint64_t edges[] = {0, 1, UINT32_MAX, UINT64_MAX,
        UINT64_C(0x7fffffff), UINT64_C(0x80000000), UINT64_C(0x7fffffffffffffff),
        UINT64_C(0x8000000000000000)};
    Trace trace = {.count = 1, .blocks = 1, .pcs = {0x8000}, .offsets = {0, 1}};
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned flags = 0; flags < 4; flags++)
    for (unsigned shift = 0; shift < 2; shift++)
    for (unsigned rn = 0; rn < 32; rn++)
    for (unsigned rd = 0; rd < 32; rd++)
    for (unsigned e = 0; e < 8; e++) {
        unsigned imm = e & 1 ? 4095 : e;
        CHECK(avz_native_decode_instruction(immediate(sf, flags, shift, imm, rn, rd), &trace.code[0]));
        AVZNativeCPU initial = initial_cpu();
        if (rn == 31) initial.sp = edges[e]; else initial.x[rn] = edges[e];
        compare(&trace, 1, UINT64_MAX, initial, cache, e & 1);
    }
    /* Random immediates, aliases, NZCV values, and execution-budget edges. */
    for (unsigned i = 0; i < 20000; i++) {
        uint32_t raw = immediate(random64() & 1, random64() & 3,
            random64() & 1, random64() & 4095, random64() & 31, random64() & 31);
        CHECK(avz_native_decode_instruction(raw, &trace.code[0]));
        compare(&trace, i % 3, UINT64_MAX, initial_cpu(), cache, i & 1);
    }
}

static const char *const names[] = {"add64", "sub32", "flagged", "mixed", "memory", "simd", "generic"};

static void make_trace(Trace *trace, unsigned workload, unsigned length)
{
    memset(trace, 0, sizeof(*trace));
    trace->count = BLOCKS * length;
    trace->blocks = BLOCKS;
    for (unsigned b = 0; b < BLOCKS; b++) {
        trace->offsets[b] = b * length;
        for (unsigned s = 0; s < length; s++) {
            size_t index = b * length + s;
            uint64_t pc = 0x8000 + b * 0x1000 + s * 4;
            trace->pcs[index] = pc;
            uint32_t raw = 0x91000400; /* add x0, x0, #1 */
            if (workload == 1) raw = 0x51000400; /* sub w0, w0, #1 */
            if (workload == 2) raw = 0xb1000400; /* adds x0, x0, #1 */
            if (workload == 3) {
                const uint32_t mixed[] = {0x91000400, 0x8b010002, 0xca020021,
                    0xd1000421, 0xf100001f, 0x9a810043, 0x910023ff};
                raw = mixed[s % (sizeof(mixed) / sizeof(mixed[0]))];
            }
            if (workload == 4 && s % 3 == 0) raw = 0xf9400140;
            if (workload == 4 && s % 3 == 2) raw = 0xf9000140;
            if (workload == 5) raw = s % 2 ? 0x91000400 : 0x4e010c00; /* dup */
            if (workload == 6) raw = 0x4e218400; /* add v0.16b, v0.16b, v1.16b */
            if (s + 1 == length) raw = 0x14000000u | (uint32_t)((0x8000 + (b + 1) * 0x1000 - pc) / 4);
            CHECK(avz_native_decode_instruction(raw, &trace->code[index]));
        }
    }
    trace->offsets[BLOCKS] = trace->count;
}

static void trace_tests(AVZNativeBlockCache *cache)
{
    Trace trace;
    for (unsigned w = 0; w < sizeof(names) / sizeof(names[0]); w++) {
        make_trace(&trace, w, 8);
        for (unsigned budget = 0; budget <= trace.count + 1; budget++)
            compare(&trace, budget, UINT64_MAX, initial_cpu(), cache, 0);
        if (w == 4) for (unsigned fault = 0; fault < 160; fault++)
            compare(&trace, trace.count + 1, fault, initial_cpu(), cache, 0);
    }
}

static int fetch(void *unused, uint64_t pc, uint64_t *physical, uint32_t *raw)
{
    (void)unused;
    const uint32_t code[] = {0x91000400, 0x8b000021, 0xf100001f, 0x17fffffd};
    if (pc < 0x8000 || pc >= 0x8010 || pc & 3) return 0;
    *physical = pc;
    *raw = code[(pc - 0x8000) / 4];
    return 1;
}

typedef struct { uint64_t count, stop, limit; } Checkpoints;

static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining)
{
    Checkpoints *c = opaque;
    hash(&steps, sizeof(steps)); hash(&blocks, sizeof(blocks));
    hash(&total, sizeof(total)); hash(&pc, sizeof(pc));
    hash(&pstate, sizeof(pstate)); hash(&remaining, sizeof(remaining));
    c->count++;
    return c->count >= c->stop ? 0 : c->limit;
}

static void checkpoint_tests(void)
{
    for (uint64_t limit = 1; limit <= 17; limit++)
    for (uint64_t stop = 1; stop <= 9; stop++) {
        AVZNativeBlockCache *cache = avz_native_block_cache_create();
        AVZNativeExecutionContext *context = avz_native_execution_context_create();
        CHECK(cache && context);
        uint64_t x[31] = {0};
        avz_native_execution_context_load(context, x, NULL, NULL, 0, 0x8000, 5, 0, 0, 0, 0, 0, 0);
        AVZNativeBlockKey key = {.current_el = 1};
        Checkpoints c = {.stop = stop, .limit = limit};
        AVZNativeChainResult result = avz_native_execution_context_run_cached_chain_checkpointed(
            context, cache, &key, limit, 257, 257, 1, checkpoint, &c, fetch, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(result.steps <= 257 && c.count > 0);
        hash(&context->cpu, sizeof(context->cpu));
        hash(&result.steps, sizeof(result.steps));
        hash(&result.blocks, sizeof(result.blocks));
        hash(&result.direct_link_hits, sizeof(result.direct_link_hits));
        hash(&result.direct_link_misses, sizeof(result.direct_link_misses));
        hash(&result.superblock_hits, sizeof(result.superblock_hits));
        hash(&result.superblock_front_hits, sizeof(result.superblock_front_hits));
        hash(&result.superblock_blocks, sizeof(result.superblock_blocks));
        hash(&result.superblock_dispatches, sizeof(result.superblock_dispatches));
        hash(&result.generic_dispatches, sizeof(result.generic_dispatches));
        hash(&result.fast_path_steps, sizeof(result.fast_path_steps));
        hash(&result.fast_path_hits, sizeof(result.fast_path_hits));
        hash(&result.status, sizeof(result.status));
        hash(&result.decode_status, sizeof(result.decode_status));
        hash(&result.unsupported_instruction, sizeof(result.unsupported_instruction));
        hash(&c.count, sizeof(c.count));
        cases++;
        avz_native_execution_context_destroy(context);
        avz_native_block_cache_destroy(cache);
    }
}

static int translate_timer_memory(void *opaque, uint64_t address, uint8_t width,
    uint8_t is_write, uint64_t *physical)
{
    (void)opaque; (void)is_write;
    *physical = address;
    return address >= 0x8000 && address - 0x8000 + width <= 64;
}

static void timer_tests(void)
{
    const uint64_t limits[] = {1, 3, 7, 17};
    const uint64_t deadlines[] = {0, 31, 100000};
    for (unsigned masked = 0; masked < 2; masked++)
    for (unsigned pending = 0; pending < 2; pending++)
    for (unsigned d = 0; d < 3; d++)
    for (unsigned l = 0; l < 4; l++) {
        uint8_t ram[64] = {0};
        for (unsigned offset = 0; offset < 16; offset += 4) {
            uint64_t physical;
            uint32_t raw;
            CHECK(fetch(NULL, 0x8000 + offset, &physical, &raw));
            memcpy(ram + offset, &raw, sizeof(raw));
        }
        AVZNativeBlockCache *cache = avz_native_block_cache_create();
        AVZNativeExecutionContext *context = avz_native_execution_context_create();
        AVZNativeMemoryFastPath *memory = avz_native_memory_fast_path_create(
            ram, 0x8000, sizeof(ram), cache, ram, translate_timer_memory, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(cache && context && memory);
        AVZNativeArchitecturalState state = {.counter_ticks = 10,
            .timer_cycles_per_instruction = 3, .cntp_ctl_el0 = 1,
            .cntp_cval_el0 = deadlines[d], .pending_irq = pending};
        avz_native_memory_fast_path_set_architectural_state(memory, &state);
        uint64_t x[31] = {0};
        avz_native_execution_context_load(context, x, NULL, NULL,
            0, 0x8000, masked ? 0x85 : 5, 0, 0, 0, 0, 0, 0);
        AVZNativeBlockKey key = {.current_el = 1};
        Checkpoints c = {.stop = UINT64_MAX, .limit = limits[l]};
        AVZNativeChainResult result = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
            context, cache, &key, limits[l], 257, 257, 1, checkpoint, &c,
            fetch, NULL, avz_native_fast_memory_read, avz_native_fast_memory_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, memory);
        avz_native_memory_fast_path_get_architectural_state(memory, &state);
        CHECK(state.counter_ticks == 10 + result.steps * 3);
        int irq = !masked && (pending || state.counter_ticks >= deadlines[d]);
        if (result.status != (irq ? AVZ_NATIVE_STATUS_YIELDED : AVZ_NATIVE_STATUS_MAX_STEPS))
            fprintf(stderr, "timer masked=%u pending=%u deadline=%" PRIu64
                " limit=%" PRIu64 " steps=%" PRIu64 " blocks=%" PRIu64
                " status=%u decode=%u raw=%08x pc=%" PRIx64 "\n",
                masked, pending, deadlines[d], limits[l], result.steps,
                result.blocks, result.status, result.decode_status,
                result.unsupported_instruction, context->cpu.pc);
        CHECK(result.status == (irq ? AVZ_NATIVE_STATUS_YIELDED : AVZ_NATIVE_STATUS_MAX_STEPS));
        CHECK(irq || result.steps == 257);
        hash(&context->cpu, sizeof(context->cpu));
        hash(&result.steps, sizeof(result.steps));
        hash(&result.blocks, sizeof(result.blocks));
        hash(&result.status, sizeof(result.status));
        hash(&state.counter_ticks, sizeof(state.counter_ticks));
        hash(&state.pending_irq, sizeof(state.pending_irq));
        hash(&c.count, sizeof(c.count));
        cases++;
        avz_native_memory_fast_path_destroy(memory);
        avz_native_execution_context_destroy(context);
        avz_native_block_cache_destroy(cache);
    }
}

static double seconds(void)
{
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec * 1e-9;
}

static void benchmark(AVZNativeBlockCache *cache, uint64_t target, const char *selected)
{
    Trace trace;
    for (unsigned w = 0; w < sizeof(names) / sizeof(names[0]); w++) {
        if (selected && strcmp(selected, names[w]) != 0) continue;
        make_trace(&trace, w, AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS);
        AVZNativeCPU cpu = initial_cpu();
        Memory memory = {.value = 19, .fail_at = UINT64_MAX, .cpu = &cpu};
        uint64_t iterations = target / trace.count;
        double start = seconds();
        for (uint64_t i = 0; i < iterations; i++) {
            cpu.pc = trace.pcs[0];
            AVZNativeBlockResult result = mapped(&trace, trace.count, &cpu, &memory, cache, 0);
            CHECK(result.steps == trace.count && result.mapped_blocks == BLOCKS);
        }
        double elapsed = seconds() - start;
        printf("workload=%s steps=%" PRIu64 " seconds=%.9f checksum=%" PRIu64 "\n",
            names[w], iterations * trace.count, elapsed,
            cpu.x[0] ^ cpu.x[1] ^ cpu.sp ^ cpu.pstate ^ cpu.v[0].low ^ memory.value);
    }
    if (selected && strcmp(selected, "cached-chain") != 0) return;
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    CHECK(context);
    uint64_t x[31] = {0};
    avz_native_execution_context_load(context, x, NULL, NULL, 0, 0x8000, 5, 0, 0, 0, 0, 0, 0);
    AVZNativeBlockKey key = {.current_el = 1};
    double start = seconds();
    AVZNativeChainResult result = avz_native_execution_context_run_cached_chain(
        context, cache, &key, target, target, fetch, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    double elapsed = seconds() - start;
    CHECK(result.steps == target);
    printf("workload=cached-chain steps=%" PRIu64 " seconds=%.9f checksum=%" PRIu64 "\n",
        result.steps, elapsed, context->cpu.x[0] ^ context->cpu.x[1] ^ context->cpu.pc);
    avz_native_execution_context_destroy(context);
}

int main(int argc, char **argv)
{
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    CHECK(cache);
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "--benchmark") == 0) {
        benchmark(cache, strtoull(argv[2], NULL, 10), argc == 4 ? argv[3] : NULL);
    } else {
        CHECK(argc == 1);
        arithmetic_tests(cache);
        trace_tests(cache);
        checkpoint_tests();
        timer_tests();
        printf("cases=%" PRIu64 " hardware_cases=%" PRIu64 " digest=%016" PRIx64 "\n",
            cases, hardware_cases, digest);
    }
    avz_native_block_cache_destroy(cache);
    return 0;
}
