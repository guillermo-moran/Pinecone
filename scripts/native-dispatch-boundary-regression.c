#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <time.h>

/* The private mapped dispatcher requires valid producer-owned metadata. Compare
 * dispatch with single-step execution and test the decoder/composer contract. */
#ifndef AVZ_BOUNDARY_NATIVE_SOURCE
#define AVZ_BOUNDARY_NATIVE_SOURCE "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_BOUNDARY_NATIVE_SOURCE

#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #test); exit(1); \
} } while (0)

enum { MAX_BLOCKS = 32, MAX_WORDS = MAX_BLOCKS * 64, MEMORY_BASE = 0x100000 };
static unsigned cases;

typedef struct {
    AVZNativeInstruction code[MAX_WORDS];
    uint64_t pcs[MAX_WORDS];
    uint16_t offsets[MAX_BLOCKS + 1];
    uint8_t candidates[MAX_WORDS];
    size_t count, blocks;
} Trace;

typedef struct {
    uint64_t value;
    unsigned calls, fail_at;
} Memory;

static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value)
{
    Memory *memory = opaque;
    if (memory->calls++ == memory->fail_at || address != MEMORY_BASE || width != 8)
        return 0;
    *value = memory->value;
    return 1;
}

static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value)
{
    Memory *memory = opaque;
    if (memory->calls++ == memory->fail_at || address != MEMORY_BASE || width != 8)
        return 0;
    memory->value = value;
    return 1;
}

static void set_instruction(Trace *trace, size_t index, uint32_t raw)
{
    CHECK(avz_native_decode_instruction(raw, &trace->code[index]));
}

static void make_trace(Trace *trace, size_t blocks, size_t length, int memory)
{
    memset(trace, 0, sizeof(*trace));
    CHECK(blocks <= MAX_BLOCKS && length > 0 && length <= 64);
    trace->blocks = blocks;
    trace->count = blocks * length;
    for (size_t block = 0; block < blocks; block++) {
        trace->offsets[block] = (uint16_t)(block * length);
        for (size_t slot = 0; slot < length; slot++) {
            size_t index = block * length + slot;
            uint64_t pc = 0x8000 + block * 0x1000 + slot * 4;
            trace->pcs[index] = pc;
            uint32_t raw = 0x91000400; /* add x0, x0, #1 */
            if (memory && slot % 3 == 0) raw = 0xf9400140; /* ldr x0, [x10] */
            if (memory && slot % 3 == 2) raw = 0xf9000140; /* str x0, [x10] */
            if (slot + 1 == length) {
                uint64_t target = 0x8000 + (block + 1) * 0x1000;
                raw = 0x14000000 | (uint32_t)((target - pc) / 4);
            }
            set_instruction(trace, index, raw);
        }
    }
    trace->offsets[blocks] = (uint16_t)trace->count;
}

static AVZNativeCPU initial_cpu(void)
{
    AVZNativeCPU cpu = {0};
    cpu.pc = 0x8000;
    cpu.pstate = 5;
    cpu.x[10] = MEMORY_BASE;
    return cpu;
}

static AVZNativeBlockResult mapped(const Trace *trace, uint64_t budget,
    AVZNativeCPU *cpu, Memory *memory, AVZNativeBlockCache *cache, uint64_t epoch)
{
    return avz_native_run_threaded_decoded_block_cpu_mapped(
        trace->code, trace->count, trace->pcs[0], budget, cpu,
        read_memory, write_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        memory, NULL, trace->candidates, trace->pcs, trace->offsets, trace->blocks,
        cache, epoch, 0, 0);
}

static AVZNativeBlockResult reference(const Trace *trace, uint64_t budget,
    AVZNativeCPU *cpu, Memory *memory)
{
    AVZNativeBlockResult result = {.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK};
    size_t index = 0, boundary = 0;
    while (result.steps < budget && index < trace->count) {
        if (cpu->pc != trace->pcs[index]) return result;
        if (index == trace->offsets[boundary]) {
            result.mapped_blocks++;
            boundary++;
        }
        const AVZNativeInstruction *instruction = &trace->code[index];
        if (!execute_decoded_instruction(instruction, cpu,
                read_memory, write_memory, NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, 0, memory)) {
            if (instruction->kind != AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE) {
                result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
                result.unsupported_instruction = instruction->raw;
            }
            return result;
        }
        result.steps++;
        index++;
    }
    if (result.steps == budget) result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    return result;
}

static void compare(const Trace *trace, uint64_t budget, unsigned fail_at,
    uint64_t pstate, AVZNativeBlockCache *cache)
{
    AVZNativeCPU actual = initial_cpu(), expected = initial_cpu();
    actual.pstate = expected.pstate = pstate;
    Memory actual_memory = {.value = 17, .fail_at = fail_at};
    Memory expected_memory = actual_memory;
    AVZNativeBlockResult result = mapped(trace, budget, &actual, &actual_memory,
        cache, avz_native_block_cache_code_mutation_epoch(cache));
    AVZNativeBlockResult wanted = reference(trace, budget, &expected, &expected_memory);
    if (result.status != wanted.status) {
        fprintf(stderr, "case=%u count=%zu blocks=%zu budget=%" PRIu64
            " fail_at=%u status=%u/%u steps=%" PRIu64 "/%" PRIu64 "\n",
            cases, trace->count, trace->blocks, budget, fail_at,
            result.status, wanted.status, result.steps, wanted.steps);
    }
    CHECK(result.steps == wanted.steps);
    CHECK(result.status == wanted.status);
    CHECK(result.mapped_blocks == wanted.mapped_blocks);
    CHECK(result.unsupported_instruction == wanted.unsupported_instruction);
    CHECK(result.fast_path_steps == 0 && result.fast_path_hits == 0);
    CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    CHECK(memcmp(&actual_memory, &expected_memory, sizeof(actual_memory)) == 0);
    cases++;
}

static void regressions(AVZNativeBlockCache *cache)
{
    Trace trace;
    const size_t counts[] = {1, 2, 3, 8, 32};
    const size_t lengths[] = {1, 2, 5, 32, 64};
    for (size_t c = 0; c < sizeof(counts) / sizeof(counts[0]); c++) {
        for (size_t l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
            for (int memory = 0; memory <= 1; memory++) {
                make_trace(&trace, counts[c], lengths[l], memory);
                compare(&trace, 0, UINT_MAX, 5, cache);
                compare(&trace, trace.count + 1, UINT_MAX, 5, cache);
                // Every budget for short traces; both sides of every longer boundary.
                for (size_t budget = 1; budget <= trace.count; budget++) {
                    size_t slot = budget % lengths[l];
                    if (trace.count <= 64 || slot <= 1 || slot + 1 == lengths[l])
                        compare(&trace, budget, UINT_MAX, 5, cache);
                }
            }
        }
    }
    make_trace(&trace, 8, 5, 1);
    for (unsigned fail_at = 0; fail_at < 24; fail_at++)
        compare(&trace, trace.count + 1, fail_at, 5, cache);

    // Taken and untaken conditional side exits at each mapped block boundary.
    for (size_t block = 0; block < 8; block++) {
        make_trace(&trace, 8, 5, 0);
        size_t index = trace.offsets[block + 1] - 1;
        uint64_t target = 0x8000 + (block + 1) * 0x1000;
        uint32_t displacement = (uint32_t)((target - trace.pcs[index]) / 4);
        set_instruction(&trace, index, 0x54000000 | (displacement << 5)); /* b.eq next */
        compare(&trace, trace.count + 1, UINT_MAX, 5, cache);
        compare(&trace, trace.count + 1, UINT_MAX, UINT64_C(0x40000005), cache);
    }

    // A wrong entry PC or stale epoch must not execute the first instruction.
    make_trace(&trace, 2, 5, 1);
    for (int stale = 0; stale <= 1; stale++) {
        AVZNativeCPU cpu = initial_cpu();
        Memory memory = {.value = 17, .fail_at = UINT_MAX};
        uint64_t epoch = avz_native_block_cache_code_mutation_epoch(cache);
        if (stale) epoch++; else cpu.pc += 4;
        AVZNativeCPU before = cpu;
        AVZNativeBlockResult result = mapped(&trace, 20, &cpu, &memory, cache, epoch);
        CHECK(result.steps == 0 && result.mapped_blocks == 0);
        CHECK(result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        CHECK(memory.calls == 0 && memory.value == 17);
        CHECK(memcmp(&cpu, &before, sizeof(cpu)) == 0);
        cases++;
    }
}

static void branch_targets(AVZNativeBlockCache *cache)
{
    Trace trace;
    const uint64_t targets[] = {0x8000, 0x8004, 0x9000, 0x9002, 0x9004, 0xa000};
    for (size_t t = 0; t < sizeof(targets) / sizeof(targets[0]); t++) {
        make_trace(&trace, 3, 3, 0);
        // The branch terminates its decoded block, even when its target is inside it.
        set_instruction(&trace, 2, 0xd61f0020); /* br x1 */
        AVZNativeCPU cpu = initial_cpu();
        cpu.x[1] = targets[t];
        Memory memory = {.value = 17, .fail_at = UINT_MAX};
        AVZNativeBlockResult result = mapped(&trace, 100, &cpu, &memory,
            cache, avz_native_block_cache_code_mutation_epoch(cache));
        int follows_map = targets[t] == 0x9000;
        CHECK(result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        CHECK(result.steps == (follows_map ? 9 : 3));
        CHECK(result.mapped_blocks == (follows_map ? 3 : 1));
        CHECK(cpu.pc == (follows_map ? 0xb000 : targets[t]));
        CHECK(cpu.x[0] == (follows_map ? 6 : 2));
        cases++;
    }
}

static int fetch_trace(void *opaque, uint64_t pc, uint64_t *physical, uint32_t *raw)
{
    const Trace *trace = opaque;
    for (size_t i = 0; i < trace->count; i++) {
        if (trace->pcs[i] == pc) {
            *physical = pc;
            *raw = trace->code[i].raw;
            return 1;
        }
    }
    return 0;
}

static void decoded_map_invariants(void)
{
    // Place each PC-changing family before a suffix; decoding must omit that suffix.
    const uint32_t terminators[] = {
        0xb4000040, 0x36000040, 0x54000040, 0x14000002, 0x94000002,
        0xd61f0020, 0xd63f0020, 0xd65f03c0, 0xd69f03e0,
        0xd4000001, 0xd503207f, 0xd503205f, 0xd50b7420, 0xd5033fdf
    };
    Trace trace;
    for (size_t t = 0; t < sizeof(terminators) / sizeof(terminators[0]); t++) {
        make_trace(&trace, 1, 5, 0);
        set_instruction(&trace, 1, terminators[t]);
        AVZNativeBlockCache *cache = avz_native_block_cache_create();
        CHECK(cache != NULL);
        AVZNativeBlockKey key = {.pc = 0x8000, .current_el = 1};
        uint32_t status = 0, unsupported = 0;
        const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
            cache, &key, fetch_trace, &trace, &status, &unsupported);
        CHECK(block != NULL && status == AVZ_NATIVE_BLOCK_DECODE_OK);
        CHECK(avz_native_decoded_block_instruction_count(block) == 2);
        CHECK(avz_native_decoded_block_instructions(block)[1].raw == terminators[t]);
        avz_native_block_cache_destroy(cache);
        cases++;
    }
    // Compose real decoded blocks and check offsets and linear PCs, not a hand-built map.
    make_trace(&trace, 3, 5, 0);
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    CHECK(cache != NULL && context != NULL);
    const AVZNativeDecodedBlock *blocks[3];
    uint64_t serials[3];
    AVZNativeBlockKey key = {.pc = 0x8000, .current_el = 1};
    for (size_t b = 0; b < 3; b++) {
        key.pc = trace.pcs[trace.offsets[b]];
        uint32_t status = 0, unsupported = 0;
        blocks[b] = avz_native_block_cache_get_or_decode(
            cache, &key, fetch_trace, &trace, &status, &unsupported);
        CHECK(blocks[b] != NULL && status == AVZ_NATIVE_BLOCK_DECODE_OK);
        serials[b] = avz_native_decoded_block_serial(cache, blocks[b]);
        if (b) avz_native_decoded_block_record_successor(
            cache, blocks[b - 1], serials[b - 1], blocks[b], serials[b]);
    }
    key.pc = 0x8000;
    const AVZNativeSuperblock *map = avz_native_compose_superblock(
        context, cache, &key, blocks[0], serials[0]);
    CHECK(map != NULL && map->count == 3 && map->instruction_count == 15);
    for (size_t b = 0; b < map->count; b++) {
        CHECK(map->block_offsets[b] < map->block_offsets[b + 1]);
        uint64_t pc = avz_native_decoded_block_pc(blocks[b]);
        for (size_t i = map->block_offsets[b]; i < map->block_offsets[b + 1]; i++)
            CHECK(map->instruction_pcs[i] == pc + 4 * (i - map->block_offsets[b]));
    }
    CHECK(map->block_offsets[0] == 0);
    CHECK(map->block_offsets[map->count] == map->instruction_count);
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(cache);
    cases++;
}

static int plt_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value)
{
    Memory *memory = opaque;
    CHECK((address == 0x8100 || address == 0x9100) && width == 8);
    if (memory->calls++ == memory->fail_at) return 0;
    *value = memory->value;
    return 1;
}

static void helper_jumps(AVZNativeBlockCache *cache)
{
    Trace trace;
    for (size_t helper_block = 0; helper_block <= 1; helper_block++) {
        make_trace(&trace, 3, 4, 0);
        size_t start = trace.offsets[helper_block];
        uint64_t base = trace.pcs[start], next = base + 0x1000;
        set_instruction(&trace, start, 0x90000010); /* adrp x16, current page */
        set_instruction(&trace, start + 1, 0xf9408211); /* ldr x17, [x16, #0x100] */
        set_instruction(&trace, start + 2, 0x91040210); /* add x16, x16, #0x100 */
        set_instruction(&trace, start + 3, 0xd61f0220); /* br x17 */
        trace.candidates[start] = avz_native_classify_semantic_candidate(
            trace.code + start, 4, 0, 1, 1);
        CHECK(trace.candidates[start] == AVZ_NATIVE_SEMANTIC_ELF_PLT_THUNK);
        const uint64_t targets[] = {base, base + 4, next, next + 2, next + 4,
            next + 0x1000, base - 0x1000};
        for (size_t t = 0; t < sizeof(targets) / sizeof(targets[0]); t++) {
          for (unsigned fault = 0; fault <= 1; fault++) {
            AVZNativeCPU cpu = initial_cpu();
            Memory memory = {.value = targets[t], .fail_at = fault ? 0 : UINT_MAX};
            AVZNativeBlockResult result = avz_native_run_threaded_decoded_block_cpu_mapped(
                trace.code, trace.count, trace.pcs[0], 20, &cpu, plt_read, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, &memory, NULL,
                trace.candidates, trace.pcs, trace.offsets, trace.blocks, cache,
                avz_native_block_cache_code_mutation_epoch(cache), 0, 0);
            uint64_t prefix_steps = helper_block * 4;
            uint64_t hits = !fault && targets[t] == base ? (20 - prefix_steps) / 4 : 1;
            uint64_t expected_steps = fault ? prefix_steps + 1 : targets[t] == base ? 20 :
                targets[t] == next ? 12 : prefix_steps + 4;
            uint64_t expected_pc = fault ? base + 4 : targets[t] == next ? 0xb000 : targets[t];
            CHECK(result.steps == expected_steps && cpu.pc == expected_pc);
            CHECK(result.status == (!fault && targets[t] == base
                ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_OUTSIDE_BLOCK));
            CHECK(result.mapped_blocks == (!fault && targets[t] == next ? 3 : helper_block + 1));
            CHECK(result.fast_path_hits == hits);
            CHECK(result.fast_path_steps == (fault ? 1 : hits * 4));
            CHECK(cpu.x[0] == (!fault && targets[t] == next ? 6 : helper_block * 3));
            CHECK(memory.calls == hits);
            cases++;
          }
        }
    }
}

static double seconds(void)
{
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
}

static void benchmark(AVZNativeBlockCache *cache)
{
    Trace trace;
    const size_t lengths[] = {2, 8, 32};
    for (int memory = 0; memory <= 1; memory++) {
        for (size_t l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
            make_trace(&trace, MAX_BLOCKS, lengths[l], memory);
            uint64_t iterations = 30000000 / trace.count;
            uint64_t epoch = avz_native_block_cache_code_mutation_epoch(cache);
            AVZNativeCPU cpu = initial_cpu();
            Memory state = {.value = 17, .fail_at = UINT_MAX};
            double start = seconds();
            for (uint64_t i = 0; i < iterations; i++) {
                cpu.pc = trace.pcs[0];
                AVZNativeBlockResult result = mapped(&trace, trace.count, &cpu,
                    &state, cache, epoch);
                CHECK(result.steps == trace.count && result.mapped_blocks == MAX_BLOCKS);
                CHECK(result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            }
            double elapsed = seconds() - start;
            printf("workload=%s length=%zu steps=%" PRIu64 " seconds=%.6f checksum=%" PRIu64 "\n",
                memory ? "memory" : "alu", lengths[l], iterations * trace.count,
                elapsed, cpu.x[0] + state.value);
        }
    }
}

int main(int argc, char **argv)
{
    CHECK(argc == 1 || (argc == 2 && strcmp(argv[1], "--benchmark") == 0));
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    CHECK(cache != NULL);
    regressions(cache);
    branch_targets(cache);
    decoded_map_invariants();
    helper_jumps(cache);
    printf("mapped boundary regression: %u cases passed\n", cases);
    if (argc == 2) benchmark(cache);
    avz_native_block_cache_destroy(cache);
    return 0;
}
