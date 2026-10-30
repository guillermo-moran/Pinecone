#include <stdio.h>
#include <time.h>
#ifndef AVZ_RUNTIME_NATIVE_SOURCE
#define AVZ_RUNTIME_NATIVE_SOURCE "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_RUNTIME_NATIVE_SOURCE
#if AVZ_TEST_ASSEMBLY
#include "assembly-test-adapter.h"
#endif

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

typedef struct {
    uint32_t code[32];
    size_t count;
    AVZNativeBlockCache *cache;
    uint64_t limit, callbacks, reads;
    int mutate;
} Fixture;

static int fetch(void *opaque, uint64_t pc, uint64_t *physical, uint32_t *word) {
    Fixture *f = opaque;
    if (pc < 0x8000 || ((pc - 0x8000) & 3) || (pc - 0x8000) / 4 >= f->count) return 0;
    *physical = pc;
    *word = f->code[(pc - 0x8000) / 4];
    return 1;
}

static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    CHECK(address == 0x100000 && width == 8);
    f->reads++;
    *value = 17;
    return 1;
}

static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Fixture *f = opaque;
    (void)blocks; (void)total; (void)pc; (void)pstate; (void)remaining;
    CHECK(steps <= f->limit);
    if (++f->callbacks == 1 && f->mutate) {
        f->code[0] = 0x91000800; /* add x0, x0, #2 */
        avz_native_block_cache_invalidate_physical_range(f->cache, 0x8000, 4);
    }
    return f->limit;
}

static AVZNativeChainResult run(AVZNativeExecutionContext *context, Fixture *f,
    uint64_t steps, int checkpointed) {
    AVZNativeBlockKey key = {.current_el = 1};
    if (checkpointed) return avz_native_execution_context_run_cached_chain_checkpointed(
        context, f->cache, &key, f->limit, steps, steps + 1, 10000, checkpoint, f,
        fetch, f, read_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f);
    return avz_native_execution_context_run_cached_chain(context, f->cache, &key,
        steps, 10000, fetch, f, read_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f);
}

static void compare(uint64_t budget, uint64_t interval, int mixed, int mutation) {
    AVZNativeCPU states[2];
    uint64_t retired[2], reads[2];
    for (int enabled = 0; enabled < 2; enabled++) {
        Fixture f = {.code = {0x91000400, 0xd503201f, 0x17fffffe}, .count = 3,
            .limit = interval, .mutate = mutation};
        if (mixed) {
            /* Pure first block, then memory/generic-native block, then loop. */
            uint32_t words[] = {0x91000400, 0x14000001, 0xf9400142, 0x17fffffd};
            memcpy(f.code, words, sizeof(words)); f.count = 4;
        }
        f.cache = avz_native_block_cache_create();
        AVZNativeExecutionContext *context = avz_native_execution_context_create();
        CHECK(f.cache && context);
        avz_native_execution_context_set_threaded_prototype(context, enabled);
        context->cpu.pc = 0x8000;
        context->cpu.pstate = 5;
        context->cpu.x[10] = 0x100000;
        context->cpu.sp = 0x400000;
        context->cpu.exclusive_valid = 1;
        context->cpu.exclusive_generation = 73;
        /* Generic chain can return at a bounded block; resume with remaining budget. */
        uint64_t total = 0;
        while (total < budget) {
            AVZNativeChainResult result = run(context, &f, budget - total, interval != 0);
            CHECK(result.steps > 0 && result.steps <= budget - total);
            CHECK(result.status != AVZ_NATIVE_STATUS_UNSUPPORTED);
            total += result.steps;
        }
        states[enabled] = context->cpu; retired[enabled] = total; reads[enabled] = f.reads;
        AVZNativeThreadedPrototypeStatistics stats = avz_native_execution_context_threaded_statistics(context);
        CHECK(stats.enabled == (uint64_t)enabled);
        CHECK(enabled ? stats.steps > 0 : stats.steps == 0);
        avz_native_execution_context_destroy(context);
        avz_native_block_cache_destroy(f.cache);
    }
    CHECK(retired[0] == retired[1] && reads[0] == reads[1]);
    CHECK(memcmp(&states[0], &states[1], sizeof(states[0])) == 0);
}

static void invalidation(void) {
    Fixture f = {.code = {0x91000400, 0x14000001}, .count = 2};
    f.cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    CHECK(f.cache && context);
    avz_native_execution_context_set_threaded_prototype(context, 1);
    context->cpu.pstate = 5;
    for (unsigned i = 1; i <= 128; i++) {
        context->cpu.pc = 0x8000; context->cpu.x[0] = 0;
        f.code[0] = 0x91000000 | (i << 10);
        if (i & 1) avz_native_block_cache_clear(f.cache);
        else avz_native_block_cache_invalidate_physical_range(f.cache, 0x8000, 4);
        CHECK(run(context, &f, 2, 0).steps == 2);
        CHECK(context->cpu.x[0] == i && context->cpu.pc == 0x8008);
    }
    uint64_t before = avz_native_execution_context_threaded_statistics(context).steps;
    avz_native_execution_context_set_threaded_prototype(context, 0);
    context->cpu.pc = 0x8000;
    CHECK(run(context, &f, 2, 0).steps == 2);
    CHECK(avz_native_execution_context_threaded_statistics(context).steps == before);
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(f.cache);
}

typedef struct {
    Fixture code;
    uint8_t ram[8192];
    uint64_t writes;
    int mode;
} MemoryFixture;

static int memory_translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    MemoryFixture *f = opaque;
    (void)write;
    if (f->mode || address < 0x100000 || address - 0x100000 > sizeof(f->ram) - width)
        return 0;
    *physical = address;
    return 1;
}

static int memory_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    MemoryFixture *f = opaque;
    CHECK(address == 0x100000 && width == 8);
    f->code.reads++;
    if (f->mode == 3) return 0;
    memcpy(value, f->ram, 8);
    return 1;
}

static int memory_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    MemoryFixture *f = opaque;
    CHECK(address == 0x100000 && width == 8);
    f->writes++;
    if (f->mode == 4) return 0;
    memcpy(f->ram, &value, 8);
    if (f->mode == 2) {
        f->code.code[1] = 0x91000800; /* Callback changes ADD and destroys its program. */
        avz_native_block_cache_clear(f->code.cache);
    }
    return 1;
}

static AVZNativeChainResult memory_run(AVZNativeExecutionContext *context,
    MemoryFixture *f, AVZNativeMemoryFastPath *memory, uint64_t budget) {
    AVZNativeBlockKey key = {.current_el = 1};
    return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        context, f->code.cache, &key, f->code.limit, budget, budget + 1, 10000,
        checkpoint, &f->code, fetch, &f->code,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        avz_native_fast_memory_can_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL, memory);
}

static void memory_compare(uint64_t budget, uint64_t interval, int mode) {
    AVZNativeCPU states[2];
    uint64_t values[2], reads[2], writes[2], retired[2];
    for (unsigned enabled = 0; enabled < 2; enabled++) {
        MemoryFixture f = {.code = {.code = {0xf9400140, 0x91000400, 0xf9000140, 0x17fffffd},
            .count = 4, .limit = interval}, .mode = mode};
        f.code.cache = avz_native_block_cache_create();
        AVZNativeExecutionContext *context = avz_native_execution_context_create();
        AVZNativeMemoryFastPath *memory = avz_native_memory_fast_path_create(
            f.ram, 0x100000, sizeof(f.ram), f.code.cache, &f,
            memory_translate, memory_read, memory_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(context && f.code.cache && memory);
        avz_native_execution_context_set_threaded_prototype(context, enabled);
        avz_native_execution_context_set_threaded_memory(context, enabled);
        context->cpu.pc = 0x8000;
        context->cpu.pstate = 5;
        context->cpu.x[10] = 0x100000;
        context->cpu.exclusive_valid = 1;
        context->cpu.exclusive_size = 8;
        context->cpu.exclusive_address = 0x100000;
        context->cpu.exclusive_generation = 73;
        AVZNativeChainResult result = memory_run(context, &f, memory, budget);
        if (mode == 3 || (mode == 4 && budget >= 3)) {
            CHECK(result.steps == (mode == 3 ? 0 : 2));
            CHECK(result.status == (enabled ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_NATIVE_STATUS_OUTSIDE_BLOCK));
            /* The reference can retry after retiring a prefix; the new path must not. */
            CHECK(mode == 3 ? f.code.reads == 1 :
                f.writes == (enabled || interval <= 2 ? 1 : 2));
        } else {
            CHECK(result.steps == budget);
            CHECK(result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        }
        if (enabled && mode < 3) {
            AVZNativeThreadedPrototypeStatistics stats = avz_native_execution_context_threaded_statistics(context);
            CHECK(stats.steps > 0 && stats.memory_boundaries > 0 && !stats.memory_faults);
        }
        states[enabled] = context->cpu;
        memcpy(&values[enabled], f.ram, 8);
        reads[enabled] = f.code.reads;
        writes[enabled] = f.writes;
        retired[enabled] = result.steps;
        avz_native_memory_fast_path_destroy(memory);
        avz_native_execution_context_destroy(context);
        avz_native_block_cache_destroy(f.code.cache);
    }
    CHECK(memcmp(&states[0], &states[1], sizeof(states[0])) == 0);
    CHECK(values[0] == values[1] && reads[0] == reads[1]);
    if (mode != 4) CHECK(writes[0] == writes[1]);
    CHECK(retired[0] == retired[1]);
}

static void memory_benchmark(unsigned variant) {
    MemoryFixture f = {.code = {.code = {0xf9400140, 0x91000400, 0xf9000140, 0x17fffffd},
        .count = 4, .limit = 4096}};
    f.code.cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    AVZNativeMemoryFastPath *memory = avz_native_memory_fast_path_create(
        f.ram, 0x100000, sizeof(f.ram), f.code.cache, &f,
        memory_translate, memory_read, memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(context && f.code.cache && memory);
    avz_native_execution_context_set_threaded_prototype(context, variant != 0);
    avz_native_execution_context_set_threaded_memory(context, variant == 2);
    context->cpu.pc = 0x8000;
    context->cpu.pstate = 5;
    context->cpu.x[10] = 0x100000;
    struct timespec start, end;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
    AVZNativeChainResult result = memory_run(context, &f, memory, 1000000);
    CHECK(clock_gettime(CLOCK_MONOTONIC, &end) == 0);
    CHECK(result.steps == 1000000 && result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    uint64_t value;
    memcpy(&value, f.ram, sizeof(value));
    CHECK(value == 250000);
    printf("memory-benchmark variant=%u seconds=%.9f checkpoints=%llu\n", variant,
        (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) * 1e-9,
        (unsigned long long)f.code.callbacks);
    avz_native_memory_fast_path_destroy(memory);
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(f.code.cache);
}

static void dispatch_benchmark(unsigned enabled) {
    Fixture f = {.code = {0x8b010000, 0x9a020000, 0x8a030000, 0x17fffffd},
        .count = 4, .limit = 4096};
    f.cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    CHECK(f.cache && context);
    avz_native_execution_context_set_threaded_prototype(context, enabled);
    context->cpu.pc = 0x8000;
    context->cpu.pstate = 5;
    context->cpu.x[0] = 17;
    context->cpu.x[1] = 3;
    context->cpu.x[2] = 2;
    context->cpu.x[3] = UINT64_MAX;
    struct timespec start, end;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
    AVZNativeChainResult result = run(context, &f, 1000000, 1);
    CHECK(clock_gettime(CLOCK_MONOTONIC, &end) == 0);
    CHECK(result.steps == 1000000 && context->cpu.x[0] == 1250017 && context->cpu.pc == 0x8000);
    printf("dispatch-benchmark enabled=%u seconds=%.9f superblocks=%llu prototype_steps=%llu\n",
        enabled, (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) * 1e-9,
        (unsigned long long)result.superblock_dispatches,
        (unsigned long long)avz_native_execution_context_threaded_statistics(context).steps);
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(f.cache);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--dispatch-benchmark") == 0) {
        for (unsigned round = 0; round < 9; round++) {
            dispatch_benchmark(round & 1);
            dispatch_benchmark((round & 1) ^ 1);
        }
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--benchmark") == 0) {
        for (unsigned round = 0; round < 9; round++)
            for (unsigned index = 0; index < 3; index++)
                memory_benchmark((index + round) % 3);
        return 0;
    }
    unsigned cases = 0;
    for (uint64_t budget = 1; budget <= 64; budget++)
    for (uint64_t interval = 0; interval <= 9; interval++)
    for (int mixed = 0; mixed < 2; mixed++) {
        compare(budget, interval, mixed, 0); cases++;
        if (interval && !mixed) { compare(budget, interval, 0, 1); cases++; }
    }
    invalidation();
    for (uint64_t budget = 1; budget <= 32; budget++)
    for (uint64_t interval = 1; interval <= 8; interval++)
    for (int mode = 0; mode < 5; mode++) {
        memory_compare(budget, interval, mode); cases++;
    }
    printf("PASS threaded runtime: %u differential scenarios, 128 cache replacements, opt-out\n", cases);
    return 0;
}
