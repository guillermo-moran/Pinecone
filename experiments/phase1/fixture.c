/* Offline immutable, single-owner attribution fixture. Never linked into app. */
#define main historical_regression_main
#include "../../scripts/threaded-runtime-regression.c"
#undef main
#include "ledger.h"
#ifdef P1_LEDGER
Phase1Ledger phase1_ledger;
#endif

static uint64_t max_checkpoint_steps, checkpoint_total;
static int phase1_translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    P1_COUNT(translation_callbacks);
    return memory_translate(opaque, address, width, write, physical);
}
static uint64_t measured_checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    CHECK(steps <= 4096);
    CHECK(total == checkpoint_total + steps);
    checkpoint_total = total;
    if (steps > max_checkpoint_steps) max_checkpoint_steps = steps;
    return checkpoint(opaque, steps, blocks, total, pc, pstate, remaining);
}

static AVZNativeChainResult execute(AVZNativeExecutionContext *c, MemoryFixture *f,
    AVZNativeMemoryFastPath *m, uint64_t budget) {
    P1_COUNT(chain_entries);
    AVZNativeBlockKey key = {.current_el = 1};
    checkpoint_total = 0;
    if (m) return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        c, f->code.cache, &key, 4096, budget, budget + 1, 10000,
        measured_checkpoint, &f->code, fetch, &f->code,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        avz_native_fast_memory_can_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL, m);
    return avz_native_execution_context_run_cached_chain_checkpointed(c, f->code.cache,
        &key, 4096, budget, budget + 1, 10000, measured_checkpoint, &f->code,
        fetch, &f->code, read_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, &f->code);
}

static AVZNativeCPU initial_cpu(int memory) {
    AVZNativeCPU cpu = {0};
    for (unsigned i = 0; i < 31; ++i) cpu.x[i] = 0x1000 + i;
    for (unsigned i = 0; i < 32; ++i) {
        cpu.v[i].low = 0x100000 + i;
        cpu.v[i].high = 0x200000 + i;
    }
    cpu.pc = 0x8000; cpu.pstate = 5; cpu.sp = 0x400000;
    cpu.fpcr = 0x400000; cpu.fpsr = 0x10;
    cpu.x[0] = memory ? 0 : 17; cpu.x[1] = 3; cpu.x[2] = 2;
    cpu.x[3] = UINT64_MAX; cpu.x[10] = 0x100000;
    return cpu;
}

static void assert_result(AVZNativeCPU *actual, AVZNativeCPU initial,
    MemoryFixture *f, AVZNativeChainResult r, uint64_t budget, int memory) {
    uint8_t expected_ram[8192] = {0};
    uint64_t value = 0;
    for (uint64_t i = 0; i < budget; ++i) {
        switch (i % 4) {
        case 0: initial.x[0] = memory ? value : initial.x[0] + initial.x[1]; break;
        case 1: initial.x[0] += memory ? 1 : initial.x[2]; break;
        case 2: if (memory) value = initial.x[0]; else initial.x[0] &= initial.x[3]; break;
        default: break;
        }
    }
    initial.pc = 0x8000 + 4 * (budget % 4);
    memcpy(expected_ram, &value, sizeof(value));
    CHECK(r.steps == budget && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(r.unsupported_instruction == 0);
    CHECK(checkpoint_total == budget);
    CHECK(memcmp(actual, &initial, sizeof(initial)) == 0);
    CHECK(memcmp(f->ram, expected_ram, sizeof(expected_ram)) == 0);
    CHECK(f->code.reads == 0 && f->writes == 0);
}

static uint64_t ns(clockid_t clock) {
    struct timespec t; CHECK(clock_gettime(clock, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static uint64_t fingerprint(const void *p, size_t n) {
    const uint8_t *bytes = p; uint64_t h = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < n; ++i) h = (h ^ bytes[i]) * UINT64_C(1099511628211);
    return h;
}

int main(int argc, char **argv) {
    CHECK(argc == 7);
    int memory_work = strcmp(argv[1], "memory") == 0;
    CHECK(memory_work || strcmp(argv[1], "arithmetic") == 0);
    unsigned mode = (unsigned)strtoul(argv[2], NULL, 10);
    int warm = atoi(argv[3]), stats = atoi(argv[4]), timed = atoi(argv[6]);
    uint64_t budget = strtoull(argv[5], NULL, 10);
    CHECK(mode <= 2 && budget > 0 && budget <= 10000000);
    CHECK((warm == 0 || warm == 1) && (stats == 0 || stats == 1));
#ifdef P1_LEDGER
    CHECK(!timed);
#endif
    uint64_t allocation_start = timed ? ns(CLOCK_MONOTONIC) : 0;
    MemoryFixture f = {.code = {.count = 4, .limit = 4096}};
    const uint32_t arithmetic[] = {0x8b010000,0x9a020000,0x8a030000,0x17fffffd};
    const uint32_t memory_words[] = {0xf9400140,0x91000400,0xf9000140,0x17fffffd};
    memcpy(f.code.code, memory_work ? memory_words : arithmetic, 16);
    CHECK(((uintptr_t)f.ram & 7) == 0);
    f.code.cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *c = avz_native_execution_context_create();
    CHECK(c && f.code.cache);
    AVZNativeMemoryFastPath *m = NULL;
    if (memory_work) {
        m = avz_native_memory_fast_path_create(f.ram, 0x100000, sizeof(f.ram),
            f.code.cache, &f, phase1_translate, memory_read, memory_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(m && m->guest_memory == NULL);
        avz_native_memory_fast_path_set_detailed_statistics_enabled(m, stats);
    }
    avz_native_execution_context_set_threaded_prototype(c, mode != 0);
    avz_native_execution_context_set_threaded_memory(c, mode == 2);
    AVZNativeCPU initial = initial_cpu(memory_work); c->cpu = initial;
    uint64_t allocation_ns = timed ? ns(CLOCK_MONOTONIC) - allocation_start : 0;
    uint64_t warm_ns = 0;
    if (warm) {
        uint64_t t = timed ? ns(CLOCK_MONOTONIC) : 0;
        AVZNativeChainResult w = execute(c, &f, m, 8192);
        if (timed) warm_ns = ns(CLOCK_MONOTONIC) - t;
        assert_result(&c->cpu, initial, &f, w, 8192, memory_work);
        if (m) CHECK(avz_native_fast_memory_write(m, 0x100000, 8, 0));
        c->cpu = initial;
    }
    f.code.callbacks = 0; max_checkpoint_steps = 0;
#ifdef P1_LEDGER
    memset(&phase1_ledger, 0, sizeof(phase1_ledger));
#endif
    AVZNativeThreadedPrototypeStatistics before = avz_native_execution_context_threaded_statistics(c);
    AVZNativeBlockCacheStatistics cb = avz_native_block_cache_statistics(f.code.cache);
    AVZNativeMemoryFastPathStatistics mb = {0};
    if (m) mb = avz_native_memory_fast_path_statistics(m);
    uint64_t epoch = avz_native_block_cache_code_mutation_epoch(f.code.cache);
    uint64_t t = timed ? ns(CLOCK_MONOTONIC) : 0;
    uint64_t ct = timed ? ns(CLOCK_THREAD_CPUTIME_ID) : 0;
    AVZNativeChainResult r = execute(c, &f, m, budget);
    uint64_t cpu_ns = timed ? ns(CLOCK_THREAD_CPUTIME_ID) - ct : 0;
    uint64_t wall_ns = timed ? ns(CLOCK_MONOTONIC) - t : 0;
    assert_result(&c->cpu, initial, &f, r, budget, memory_work);
    CHECK(memcmp(f.code.code, memory_work ? memory_words : arithmetic, 16) == 0);
    CHECK(avz_native_block_cache_code_mutation_epoch(f.code.cache) == epoch);
    AVZNativeThreadedPrototypeStatistics after = avz_native_execution_context_threaded_statistics(c);
    AVZNativeBlockCacheStatistics ca = avz_native_block_cache_statistics(f.code.cache);
    AVZNativeMemoryFastPathStatistics ma = {0};
    if (m) ma = avz_native_memory_fast_path_statistics(m);
    printf("{\"workload\":\"%s\",\"mode\":%u,\"warm\":%d,\"detailed_stats\":%d,"
        "\"timed\":%d,\"steps\":%llu,\"status\":%u,\"wall_ns\":%llu,\"cpu_ns\":%llu,"
        "\"allocation_ns\":%llu,\"warmup_8192_ns\":%llu,\"full_cpu_asserted\":true,"
        "\"full_ram_asserted\":true,\"ram_fnv64\":\"%016llx\",\"cpu_hex\":\"",
        argv[1], mode, warm, stats, timed, (unsigned long long)r.steps, r.status,
        (unsigned long long)wall_ns, (unsigned long long)cpu_ns,
        (unsigned long long)allocation_ns, (unsigned long long)warm_ns,
        (unsigned long long)fingerprint(f.ram, sizeof(f.ram)));
    for (size_t i = 0; i < sizeof(c->cpu); ++i) printf("%02x", ((uint8_t *)&c->cpu)[i]);
    printf("\",\"checkpoints\":%llu,\"max_checkpoint_steps\":%llu,\"superblocks\":%llu,"
        "\"superblock_blocks\":%llu,\"semantic_steps\":%llu,\"generic_dispatches\":%llu,"
        "\"prototype_blocks_stat\":%llu,\"prototype_steps_stat\":%llu,\"revalidations_stat\":%llu,"
        "\"memory_faults\":%llu,\"translation_callbacks_stat\":%llu,"
        "\"invalidation_checks\":%llu,\"invalidation_skips\":%llu,\"invalidations\":%llu",
        (unsigned long long)f.code.callbacks, (unsigned long long)max_checkpoint_steps,
        (unsigned long long)r.superblock_dispatches, (unsigned long long)r.superblock_blocks,
        (unsigned long long)r.fast_path_steps, (unsigned long long)r.generic_dispatches,
        (unsigned long long)(after.blocks-before.blocks), (unsigned long long)(after.steps-before.steps),
        (unsigned long long)(after.memory_boundaries-before.memory_boundaries),
        (unsigned long long)(after.memory_faults-before.memory_faults),
        (unsigned long long)(ma.translation_callback_walks-mb.translation_callback_walks),
        (unsigned long long)(ca.invalidation_checks-cb.invalidation_checks),
        (unsigned long long)(ca.invalidation_skips-cb.invalidation_skips),
        (unsigned long long)(ca.invalidations-cb.invalidations));
#ifdef P1_LEDGER
    printf(",\"ledger\":{");
#define PRINT_FIELD(field) printf("\"" #field "\":%llu,", (unsigned long long)phase1_ledger.field)
    PRINT_FIELD(chain_entries); PRINT_FIELD(established_entries); PRINT_FIELD(prototype_entries);
    PRINT_FIELD(eligibility_lookups); PRINT_FIELD(program_lookups); PRINT_FIELD(program_creations);
    PRINT_FIELD(validations); PRINT_FIELD(hot_reads); PRINT_FIELD(hot_writes);
    PRINT_FIELD(full_reads); PRINT_FIELD(full_writes);
    PRINT_FIELD(commit_calls); PRINT_FIELD(prototype_steps); PRINT_FIELD(translation_callbacks);
    const char *names[] = {"requested_hist", "limit_hist", "executed_hist", "status_hist"};
    const uint64_t *hist[] = {phase1_ledger.requested, phase1_ledger.limits,
        phase1_ledger.executed, phase1_ledger.statuses};
    for (unsigned j = 0; j < 4; ++j) {
        printf("\"%s\":{", names[j]);
        int comma = 0;
        for (unsigned i = 0; i < (j == 3 ? P1_STATUS_COUNT : 4097); ++i) if (hist[j][i]) {
            if (j == 3) printf("%s\"%s\":%llu", comma ? "," : "", phase1_status_names[i],
                (unsigned long long)hist[j][i]);
            else printf("%s\"%u\":%llu", comma ? "," : "", i, (unsigned long long)hist[j][i]);
            comma = 1;
        }
        printf("}%s", j == 3 ? "}" : ",");
    }
#undef PRINT_FIELD
#endif
    puts("}");
    if (m) avz_native_memory_fast_path_destroy(m);
    avz_native_execution_context_destroy(c); avz_native_block_cache_destroy(f.code.cache);
    return 0;
}
