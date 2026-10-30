/* White-box cache accounting tests using the real decoder and assembly
 * programs. Only allocation failure and diagnostic clocks are intercepted. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

static unsigned create_calls, clock_calls;
static int fail_create, fail_clock;
static AGProgram *test_create(const uint32_t *words, size_t count, uint64_t base) {
    create_calls++;
    return fail_create ? NULL : ag_create(words, count, base);
}
#if AVZ_ASSEMBLY_CACHE_DIAGNOSTICS
static int test_clock(clockid_t clock, struct timespec *now) {
    clock_calls++;
    if (fail_clock) return -1;
    return clock_gettime(clock, now);
}
#define clock_gettime test_clock
#endif
#define ag_create test_create
#include "../Sources/ARM64VizNative/ARM64VizBlockCache.c"
#undef ag_create
#undef clock_gettime

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); \
} } while (0)
#define CHECK_D(x) do { if (AVZ_AC_DIAGNOSTICS) CHECK(x); } while (0)

typedef struct { uint64_t pc; uint32_t word; size_t count; } Fetch;
static int fetch(void *opaque, uint64_t pc, uint64_t *physical, uint32_t *word) {
    Fetch *f = opaque;
    if (pc < f->pc || (pc - f->pc) % 4 || (pc - f->pc) / 4 >= f->count) return 0;
    *physical = pc;
    *word = f->word;
    return 1;
}
static const AVZNativeDecodedBlock *decode_count(AVZNativeBlockCache *cache,
    uint64_t pc, uint32_t word, size_t count) {
    Fetch f = {pc, word, count};
    AVZNativeBlockKey key = {.pc = pc, .current_el = 1};
    uint32_t status;
    const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
        cache, &key, fetch, &f, &status, NULL);
    CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    CHECK(block->instruction_count == count);
    return block;
}
static const AVZNativeDecodedBlock *decode(AVZNativeBlockCache *cache,
    uint64_t pc, uint32_t word) {
    return decode_count(cache, pc, word, 1);
}
static const AGProgram *retained_program(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block) {
    return avz_entry_for_block(cache, block)->assembly.program;
}
static void check_order(AVZNativeBlockCache *cache, unsigned expected_live) {
    unsigned live = 0;
    uint8_t seen[AVZ_BLOCK_CACHE_ENTRY_COUNT] = {0};
    for (unsigned queue = 0; queue < 2; queue++) {
        uint16_t index = cache->assembly_heads[queue], previous = 0;
        size_t bytes = 0;
        while (index) {
            CHECK(index <= AVZ_BLOCK_CACHE_ENTRY_COUNT && !seen[index - 1u]);
            seen[index - 1u] = 1;
            const AVZBlockCacheEntry *entry = &cache->entries[index - 1u];
            const AVZAssemblyRetention *r = &entry->assembly;
            CHECK(entry->valid && r->program && r->queue == queue + 1u);
            CHECK(r->previous == previous && r->reuse <= 2);
            CHECK(r->bytes == ag_program_bytes(r->program));
            bytes += r->bytes;
            previous = index;
            index = r->next;
            live++;
        }
        CHECK(cache->assembly_tails[queue] == previous);
        CHECK(bytes == cache->assembly_bytes[queue]);
    }
    for (size_t i = 0; i < AVZ_BLOCK_CACHE_ENTRY_COUNT; i++)
        CHECK((cache->entries[i].assembly.program != NULL) == (seen[i] != 0));
    CHECK(live == expected_live && live == cache->assembly_count);
    CHECK(cache->assembly_bytes[0] + cache->assembly_bytes[1] <= AVZ_ASSEMBLY_CACHE_BYTE_BUDGET);
    CHECK(cache->assembly_bytes[1] <= AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET);
    CHECK(avz_native_block_cache_diagnostics_snapshot(cache).cache_owned_programs == live);
}
static AVZNativeBlockCache *fresh(uint32_t flags) {
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    CHECK(cache);
    CHECK(avz_native_block_cache_diagnostics_begin(cache, flags) == AVZ_AC_DIAGNOSTICS);
    check_order(cache, 0);
    return cache;
}
static void partition(AVZAssemblyCacheDiagnostics d) {
    CHECK_D(d.requests == d.invalid_requests + d.stale_requests +
        d.program_hits + d.program_misses + d.negative_hits + d.semantic_rejections);
    CHECK_D(d.negative_hits == d.negative_semantic_hits + d.negative_unsupported_hits +
        d.negative_null_hits + d.negative_memory_hits);
    CHECK_D(d.program_misses == d.preparation_attempts);
    CHECK_D(d.preparation_attempts == d.program_allocations + d.preparation_null_results);
    CHECK_D(d.program_allocations == d.admissions + d.unsupported_preparations +
        d.memory_denied_preparations + d.budget_rejections);
}

static void opt_in_and_windows(void) {
    AVZNativeBlockCache *cache = fresh(0);
    const AVZNativeDecodedBlock *block = decode(cache, 0x8000, 0x91000400);
    unsigned clocks = clock_calls;
    const AGProgram *p = avz_assembly_cache_program(cache, block, 0);
    CHECK(p);
    for (int i = 0; i < 100; i++) CHECK(avz_assembly_cache_program(cache, block, 0) == p);
    CHECK(clock_calls == clocks);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK(!d.requests && !d.enabled && d.compiled == AVZ_AC_DIAGNOSTICS);
    CHECK(d.cache_owned_programs == 1 && d.cache_owned_program_bytes == ag_program_bytes(p));
    CHECK(d.cache_storage_bytes > d.cache_owned_program_bytes);
    CHECK(avz_native_block_cache_diagnostics_begin(cache, 128) == 0);
    avz_native_block_cache_diagnostics_begin(cache, AVZ_CACHE_DIAGNOSTICS_COUNTS);
    CHECK(avz_assembly_cache_program(cache, block, 0) == p);
    const AVZNativeDecodedBlock *next = decode(cache, 0x9000, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, next, 0));
    CHECK(clock_calls == clocks);
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.program_hits == 1 && d.program_misses == 1 && !d.preparation_timed_samples);
    CHECK_D(d.peak_cache_owned_programs == 2);
    partition(d);
    avz_native_block_cache_diagnostics_begin(cache, AVZ_CACHE_DIAGNOSTICS_PREPARATION_TIME);
    CHECK(avz_assembly_cache_program(cache, block, 0) == p);
    CHECK(clock_calls == clocks); /* Even timing-enabled hits must not clock. */
    next = decode(cache, 0xa000, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, next, 0));
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(clock_calls == clocks + 2 && d.preparation_timed_samples == 1);
    CHECK_D(d.preparation_ns >= d.preparation_max_ns && !d.preparation_clock_failures);
    fail_clock = 1;
    next = decode(cache, 0xb000, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, next, 0));
    fail_clock = 0;
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.preparation_clock_failures == 1 && d.preparation_timed_samples == 1);
    CHECK(!avz_assembly_cache_program(cache, NULL, 0));
    CHECK(!avz_assembly_cache_program(NULL, block, 0));
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.invalid_requests == 1);
    partition(d);
    avz_native_block_cache_clear(cache);
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK(d.cache_owned_programs == 0 && d.cache_owned_program_bytes == 0);
    CHECK_D(d.clear_releases == 4 && d.peak_cache_owned_programs == 4);
    avz_native_block_cache_destroy(cache);
}

static void rejection_and_memory(void) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    const AVZNativeDecodedBlock *hot = decode(cache, 0x8000, 0x91000400);
    const AGProgram *p = avz_assembly_cache_program(cache, hot, 0);
    CHECK(p);
    for (unsigned i = 0; i < 600; i++) {
        const AVZNativeDecodedBlock *negative = decode(cache, 0x10000 + i * 64, 0xd4000001);
        CHECK(!avz_assembly_cache_program(cache, negative, 0));
        CHECK(!avz_assembly_cache_program(cache, negative, 0));
    }
    CHECK(avz_assembly_cache_program(cache, hot, 0) == p);
    for (unsigned trace = 0; trace < 2; trace++) {
        const AVZNativeDecodedBlock *semantic = decode(cache, 0x30000 + trace * 64, 0x91000400);
        AVZBlockCacheEntry *entry = (AVZBlockCacheEntry *)avz_entry_for_block(cache, semantic);
        if (trace) entry->block.trace_semantic_candidates[0] = 1;
        else entry->block.semantic_candidates[0] = 1;
        unsigned calls = create_calls;
        CHECK(!avz_assembly_cache_program(cache, semantic, 1));
        CHECK(!avz_assembly_cache_program(cache, semantic, 1));
        CHECK(create_calls == calls);
    }
    const AVZNativeDecodedBlock *oom = decode(cache, 0x40000, 0x91000400);
    fail_create = 1;
    CHECK(!avz_assembly_cache_program(cache, oom, 0));
    fail_create = 0;
    unsigned calls = create_calls;
    CHECK(!avz_assembly_cache_program(cache, oom, 0));
    CHECK(create_calls == calls); /* Existing sticky NULL eligibility retained. */
    const AVZNativeDecodedBlock *memory = decode(cache, 0x50000, 0xf9400020);
    CHECK(!avz_assembly_cache_program(cache, memory, 0));
    calls = create_calls;
    CHECK(!avz_assembly_cache_program(cache, memory, 0));
    CHECK(create_calls == calls);
    CHECK(avz_assembly_cache_program(cache, memory, 1));
    CHECK(!avz_assembly_cache_program(cache, memory, 0));
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.negative_unsupported_hits == 600 && d.unsupported_preparations == 600);
    CHECK_D(d.semantic_rejections == 2 && d.negative_semantic_hits == 2);
    CHECK_D(d.preparation_null_results == 1 && d.negative_null_hits == 1);
    CHECK_D(d.memory_denied_preparations == 1 && d.negative_memory_hits == 2);
    CHECK_D(d.admissions == 2 && !d.positive_evictions && !d.positive_repreparations);
    CHECK_D(d.transient_releases == 601);
    CHECK(d.cache_owned_programs == 2);
    partition(d);
    avz_native_block_cache_destroy(cache);
}

static void retention_lifecycle(uint32_t flags) {
    AVZNativeBlockCache *cache = fresh(flags);
    for (unsigned cycle = 0; cycle < 3; cycle++) {
        const AVZNativeDecodedBlock *blocks[8];
        const AGProgram *programs[8];
        for (unsigned i = 0; i < 8; i++) {
            blocks[i] = decode(cache, 0x8000 + i * 64, 0x91000400);
            programs[i] = avz_assembly_cache_program(cache, blocks[i], 0);
            CHECK(programs[i]);
            CHECK(avz_assembly_cache_program(cache, blocks[i], 0) == programs[i]);
            if (i % 2) CHECK(avz_assembly_cache_program(cache, blocks[i], 0) == programs[i]);
        }
        check_order(cache, 8);
        /* Remove head, middle and tail, in both probation and protection. */
        unsigned holes[] = {0, 1, 3, 6, 7};
        for (unsigned i = 0; i < 5; i++) {
            uint64_t pc = blocks[holes[i]]->key.pc;
            avz_native_block_cache_invalidate_physical_range(cache, pc, 4);
            avz_native_block_cache_invalidate_physical_range(cache, pc, 4);
            check_order(cache, 7 - i);
        }
        const AVZNativeDecodedBlock *failed = decode(cache, 0x9000, 0x91000400);
        fail_create = 1;
        CHECK(!avz_assembly_cache_program(cache, failed, 0));
        fail_create = 0;
        check_order(cache, 3);
        for (unsigned i = 0; i < 5; i++) {
            const AVZNativeDecodedBlock *next = decode(cache, 0xa000 + i * 64, 0x91000400);
            CHECK(avz_assembly_cache_program(cache, next, 0));
            check_order(cache, 4 + i);
        }
        unsigned survivors[] = {2, 4, 5};
        for (unsigned i = 0; i < 3; i++)
            CHECK(avz_assembly_cache_program(cache, blocks[survivors[i]], 0) == programs[survivors[i]]);
        AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
        CHECK(!d.positive_evictions && !d.evictions_with_free_slots);
        avz_native_block_cache_clear(cache);
        check_order(cache, 0);
        avz_native_block_cache_clear(cache);
        check_order(cache, 0);
    }
    avz_native_block_cache_destroy(cache);
}

static void cyclic_capacity(uint32_t flags) {
    AVZNativeBlockCache *cache = fresh(flags);
    const AVZNativeDecodedBlock *blocks[257];
    const AGProgram *programs[257];
    unsigned calls = create_calls;
    for (unsigned pass = 0; pass < 3; pass++) {
        for (unsigned i = 0; i < 257; i++) {
            const AVZNativeDecodedBlock *block = decode(cache, 0x10000 + i * 64, 0x91000400);
            const AGProgram *program = avz_assembly_cache_program(cache, block, 0);
            CHECK(program);
            if (!pass) { blocks[i] = block; programs[i] = program; }
            else CHECK(block == blocks[i] && program == programs[i]);
        }
        check_order(cache, 257);
    }
    CHECK(create_calls - calls == 257);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK(!d.positive_evictions && !d.positive_repreparations);
    if (flags) {
        CHECK_D(d.program_misses == 257 && d.program_hits == 514);
        CHECK_D(d.promotions == 257);
    } else CHECK(!d.requests);
    CHECK(d.program_capacity == AVZ_BLOCK_CACHE_ENTRY_COUNT);
    CHECK(d.program_byte_budget == AVZ_ASSEMBLY_CACHE_BYTE_BUDGET);
    CHECK(d.protected_byte_budget == AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET);
    CHECK(d.protected_program_bytes == d.cache_owned_program_bytes);
    partition(d);
    printf("cyclic257: flags=%u preparations=257 for 771 lookups; no re-preparation\n", flags);
    avz_native_block_cache_diagnostics_begin(cache, 0);
    avz_native_block_cache_clear(cache);
    const AVZNativeDecodedBlock *block = decode(cache, 0x8000, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, block, 0));
    avz_native_block_cache_diagnostics_begin(cache, AVZ_CACHE_DIAGNOSTICS_COUNTS);
    d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK(d.cache_owned_programs == 1 && !d.requests);
    CHECK_D(d.peak_cache_owned_programs == 1);
    avz_native_block_cache_clear(cache);
    check_order(cache, 0);
    CHECK_D(avz_native_block_cache_diagnostics_snapshot(cache).clear_releases == 1);
    avz_native_block_cache_destroy(cache);
}

/* Avoid decoded-set replacement so these fixtures isolate program-budget
 * pressure, not a different cache. Up to four decoded entries per set. */
static const AVZNativeDecodedBlock *distinct_block(AVZNativeBlockCache *cache,
    uint64_t *pc, uint8_t *set_uses, size_t count) {
    for (;;) {
        AVZNativeBlockKey key = {.pc = *pc, .current_el = 1};
        *pc += 128;
        size_t set = avz_block_set_index(avz_block_key_hash(cache, &key));
        if (set_uses[set] >= AVZ_BLOCK_CACHE_WAY_COUNT) continue;
        set_uses[set]++;
        return decode_count(cache, key.pc, 0x91000400, count);
    }
}

static void budget_pressure_and_scan(uint32_t flags) {
    AVZNativeBlockCache *cache = fresh(flags);
    uint8_t set_uses[AVZ_BLOCK_CACHE_SET_COUNT] = {0};
    uint64_t pc = 0x100000;
    const AVZNativeDecodedBlock *hot = distinct_block(cache, &pc, set_uses, 16);
    const AGProgram *program = avz_assembly_cache_program(cache, hot, 0);
    CHECK(program);
    size_t bytes = ag_program_bytes(program);
    CHECK(avz_assembly_cache_program(cache, hot, 0) == program);
    CHECK(!cache->assembly_bytes[1]); /* Selection/execution pair is not reuse. */
    CHECK(avz_assembly_cache_program(cache, hot, 0) == program);
    CHECK(cache->assembly_bytes[1] == bytes);
    unsigned capacity = AVZ_ASSEMBLY_CACHE_BYTE_BUDGET / bytes;
    CHECK(capacity > AVZ_ASSEMBLY_CACHE_MAX_RETIREMENTS);
    unsigned scans = capacity * 2 + 17;
    CHECK(scans + 1 < AVZ_BLOCK_CACHE_ENTRY_COUNT);
    const AVZNativeDecodedBlock *first_cold = NULL;
    for (unsigned i = 0; i < scans; i++) {
        const AVZNativeDecodedBlock *block = distinct_block(cache, &pc, set_uses, 16);
        const AGProgram *cold = avz_assembly_cache_program(cache, block, 0);
        CHECK(cold && avz_assembly_cache_program(cache, block, 0) == cold);
        if (!i) first_cold = block;
        CHECK(retained_program(cache, hot) == program);
        CHECK(cache->assembly_bytes[1] == bytes);
        if (i % 256 == 0) check_order(cache, cache->assembly_count);
    }
    check_order(cache, capacity);
    CHECK(!retained_program(cache, first_cold));
    unsigned calls = create_calls;
    CHECK(avz_assembly_cache_program(cache, hot, 0) == program);
    CHECK(create_calls == calls);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    if (flags) {
        CHECK_D(d.budget_evictions == scans + 1 - capacity);
        CHECK_D(d.positive_evictions == d.budget_evictions && !d.entry_releases);
        CHECK_D(d.promotions == 1 && !d.protected_demotions);
        CHECK_D(d.peak_admission_retirements == 1);
        CHECK_D(d.peak_preparation_live_bytes <= d.program_byte_budget + bytes);
    }
    CHECK(!d.evictions_with_free_slots);
    CHECK(avz_assembly_cache_program(cache, first_cold, 0));
    if (flags) CHECK_D(avz_native_block_cache_diagnostics_snapshot(cache).positive_repreparations == 1);
    partition(avz_native_block_cache_diagnostics_snapshot(cache));
    /* Oversized request must not flush the cache; a pathological request that
     * would need >64 victims must stop at the hard admission work limit. */
    CHECK(!avz_assembly_make_room(cache, AVZ_ASSEMBLY_CACHE_BYTE_BUDGET + 1u));
    check_order(cache, capacity);
    CHECK(!avz_assembly_make_room(cache, AVZ_ASSEMBLY_CACHE_BYTE_BUDGET));
    check_order(cache, capacity - AVZ_ASSEMBLY_CACHE_MAX_RETIREMENTS);
    if (flags) CHECK_D(avz_native_block_cache_diagnostics_snapshot(cache).peak_admission_retirements == 64);
    printf("scan pressure: flags=%u budget=%u cold=%u hot retained, residency bounded\n",
        flags, AVZ_ASSEMBLY_CACHE_BYTE_BUDGET, scans);
    avz_native_block_cache_clear(cache);
    check_order(cache, 0);
    avz_native_block_cache_destroy(cache);
}

static void protected_pressure(void) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    uint8_t set_uses[AVZ_BLOCK_CACHE_SET_COUNT] = {0};
    uint64_t pc = 0x100000;
    const AVZNativeDecodedBlock *first = distinct_block(cache, &pc, set_uses, 16);
    const AGProgram *original = avz_assembly_cache_program(cache, first, 0);
    CHECK(original);
    size_t bytes = ag_program_bytes(original);
    CHECK(avz_assembly_cache_program(cache, first, 0) == original);
    CHECK(avz_assembly_cache_program(cache, first, 0) == original);
    unsigned protected_capacity = AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET / bytes;
    for (unsigned i = 1; i <= protected_capacity; i++) {
        const AVZNativeDecodedBlock *block = distinct_block(cache, &pc, set_uses, 16);
        const AGProgram *program = avz_assembly_cache_program(cache, block, 0);
        CHECK(program && avz_assembly_cache_program(cache, block, 0) == program);
        CHECK(avz_assembly_cache_program(cache, block, 0) == program);
    }
    CHECK(retained_program(cache, first) == original);
    CHECK(avz_entry_for_block(cache, first)->assembly.queue == 1);
    CHECK(cache->assembly_bytes[1] == protected_capacity * bytes);
    check_order(cache, protected_capacity + 1);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.protected_demotions == 1 && !d.positive_evictions);
    /* Demotion keeps preparation and eligibility; third lookup protects again. */
    unsigned calls = create_calls;
    CHECK(avz_assembly_cache_program(cache, first, 0) == original);
    CHECK(avz_assembly_cache_program(cache, first, 0) == original);
    CHECK(create_calls == calls && avz_entry_for_block(cache, first)->assembly.queue == 2);
    check_order(cache, protected_capacity + 1);
    avz_native_block_cache_destroy(cache);
}

static void mixed_size_pressure(void) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    uint8_t set_uses[AVZ_BLOCK_CACHE_SET_COUNT] = {0};
    uint64_t pc = 0x100000;
    const AVZNativeDecodedBlock *small = distinct_block(cache, &pc, set_uses, 1);
    const AGProgram *program = avz_assembly_cache_program(cache, small, 0);
    CHECK(program);
    size_t small_bytes = ag_program_bytes(program);
    unsigned protected_capacity = AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET / small_bytes;
    for (unsigned i = 0; i < protected_capacity; i++) {
        if (i) small = distinct_block(cache, &pc, set_uses, 1);
        program = avz_assembly_cache_program(cache, small, 0);
        CHECK(program && avz_assembly_cache_program(cache, small, 0) == program);
        CHECK(avz_assembly_cache_program(cache, small, 0) == program);
    }
    const AVZNativeDecodedBlock *large = distinct_block(cache, &pc, set_uses, 16);
    const AGProgram *big = avz_assembly_cache_program(cache, large, 0);
    CHECK(big && avz_assembly_cache_program(cache, large, 0) == big);
    unsigned demotions = 0;
    while (avz_entry_for_block(cache, large)->assembly.queue == 1) {
        size_t before = cache->assembly_bytes[1];
        CHECK(avz_assembly_cache_program(cache, large, 0) == big);
        size_t admitted = avz_entry_for_block(cache, large)->assembly.queue == 2 ? ag_program_bytes(big) : 0;
        CHECK(cache->assembly_bytes[1] + small_bytes == before + admitted);
        CHECK(++demotions < 16);
    }
    CHECK(demotions > 1);
    check_order(cache, protected_capacity + 1);
    /* Fill the remainder with small probation entries, then admit one large
     * program. It must reclaim several byte-weighted victims, not just one. */
    while (cache->assembly_bytes[0] + cache->assembly_bytes[1] + small_bytes <=
           AVZ_ASSEMBLY_CACHE_BYTE_BUDGET) {
        small = distinct_block(cache, &pc, set_uses, 1);
        CHECK(avz_assembly_cache_program(cache, small, 0));
    }
    unsigned before = cache->assembly_count;
    large = distinct_block(cache, &pc, set_uses, 16);
    CHECK(avz_assembly_cache_program(cache, large, 0));
    CHECK(cache->assembly_count + 1 < before);
    check_order(cache, cache->assembly_count);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.peak_admission_retirements > 1 && d.peak_admission_retirements <= 64);
    CHECK_D(!d.entry_releases && d.protected_demotions == demotions);
    partition(d);
    avz_native_block_cache_destroy(cache);
}

static int mapping_valid;
static int validate_mapping(void *opaque, uint64_t va, uint64_t pa) {
    (void)opaque;
    return mapping_valid && va == pa;
}
static void invalidation(void) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    uint64_t storage = avz_native_block_cache_diagnostics_snapshot(cache).cache_storage_bytes;
    CHECK(avz_native_block_cache_configure_physical_range(cache, 0x8000, 4096));
    CHECK(avz_native_block_cache_diagnostics_snapshot(cache).cache_storage_bytes == storage + 11);
    mapping_valid = 1;
    avz_native_block_cache_set_mapping_validator(cache, validate_mapping, NULL);
    const AVZNativeDecodedBlock *block = decode(cache, 0x8000, 0x91000400);
    const AGProgram *p = avz_assembly_cache_program(cache, block, 0);
    CHECK(p);
    avz_native_block_cache_invalidate_translation_mappings(cache);
    CHECK(avz_assembly_cache_program(cache, block, 0) == p);
    mapping_valid = 0;
    avz_native_block_cache_invalidate_translation_mappings(cache);
    CHECK(!avz_assembly_cache_program(cache, block, 0));
    check_order(cache, 0);
    mapping_valid = 1;
    block = decode(cache, 0x8000, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, block, 0));
    check_order(cache, 1);
    avz_native_block_cache_invalidate_physical_range(cache, 0x8000, 4);
    CHECK(!avz_assembly_cache_program(cache, block, 0));
    check_order(cache, 0);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.stale_requests == 2 && d.entry_releases == 2);
    CHECK(!d.cache_owned_programs);
    partition(d);
    avz_native_block_cache_destroy(cache);
}

static void shared_invalidation(void) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    AVZGuestMemory *memory = avz_guest_memory_create(4096);
    CHECK(memory);
    CHECK(avz_native_block_cache_configure_physical_range(cache, 0, 4096));
    avz_native_block_cache_set_guest_memory(cache, memory);
    const AVZNativeDecodedBlock *block = decode(cache, 0, 0x91000400);
    CHECK(avz_assembly_cache_program(cache, block, 0));
    avz_guest_memory_note_write(memory, 0, 4);
    CHECK(!avz_assembly_cache_program(cache, block, 0));
    check_order(cache, 0);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(cache);
    CHECK_D(d.stale_requests == 1 && d.entry_releases == 1);
    CHECK(!d.cache_owned_programs);
    avz_native_block_cache_destroy(cache);
    avz_guest_memory_destroy(memory);
}

typedef struct {
    AVZNativeBlockCache *cache;
    const AGProgram *program, *replacement;
    unsigned reads;
    int invalidate_only;
} Pin;
static int no_ram_translation(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    (void)opaque; (void)address; (void)width; (void)write; (void)physical;
    return 0;
}
static int pinned_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Pin *pin = opaque;
    CHECK(address == 0x100000 && width == 8);
    CHECK(pin->program->active_runs == 1 && !pin->program->retired);
    if (pin->invalidate_only)
    {
        if (pin->invalidate_only == 2) {
            uint8_t set_uses[AVZ_BLOCK_CACHE_SET_COUNT] = {0};
            AVZNativeBlockKey key = {.pc = 0x8000, .current_el = 1};
            set_uses[avz_block_set_index(avz_block_key_hash(pin->cache, &key))] = 4;
            uint64_t pc = 0x4000000;
            unsigned admissions = 0;
            while (!pin->program->retired) {
                const AVZNativeDecodedBlock *cold = distinct_block(pin->cache, &pc, set_uses, 16);
                CHECK(avz_assembly_cache_program(pin->cache, cold, 0));
                CHECK(++admissions < AVZ_BLOCK_CACHE_ENTRY_COUNT);
            }
            CHECK(pin->program->active_runs == 1);
            CHECK_D(avz_native_block_cache_diagnostics_snapshot(pin->cache).budget_evictions > 0);
        }
        avz_native_block_cache_invalidate_physical_range(pin->cache, 0x8000, 4);
    }
    else avz_native_block_cache_clear(pin->cache);
    CHECK(pin->program->active_runs == 1 && pin->program->retired);
    check_order(pin->cache, pin->cache->assembly_count);
    AVZAssemblyCacheDiagnostics d = avz_native_block_cache_diagnostics_snapshot(pin->cache);
    if (pin->invalidate_only != 2) {
        CHECK(!d.cache_owned_program_bytes && !d.cache_owned_programs);
        CHECK_D(pin->invalidate_only ? d.entry_releases == 1 : d.clear_releases == 1);
    }
    const AVZNativeDecodedBlock *block = decode(pin->cache, 0x8000, 0x91000400);
    pin->replacement = avz_assembly_cache_program(pin->cache, block, 0);
    CHECK(pin->replacement && pin->replacement != pin->program);
    CHECK(retained_program(pin->cache, block) == pin->replacement);
    CHECK(pin->program->active_runs == 1 && pin->program->retired);
    check_order(pin->cache, pin->cache->assembly_count);
    pin->reads++;
    *value = 73;
    return 1;
}
static void lifetime_pin(int invalidate_only) {
    AVZNativeBlockCache *cache = fresh(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    Pin pin = {.cache = cache, .invalidate_only = invalidate_only};
    uint8_t ram[4096] = {0};
    AVZNativeMemoryFastPath *memory = avz_native_memory_fast_path_create(
        ram, 0x200000, sizeof(ram), cache, &pin, no_ram_translation, pinned_read, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(memory);
    const AVZNativeDecodedBlock *block = decode(cache, 0x8000, 0xf9400020);
    pin.program = avz_assembly_cache_program(cache, block, 1);
    CHECK(pin.program);
    AVZNativeCPU cpu = {.pc = 0x8000};
    cpu.x[1] = 0x100000;
    AVZNativeBlockResult result = ag_run_memory(pin.program, 1, &cpu, NULL, memory);
    CHECK(result.steps == 1 && cpu.x[0] == 73 && cpu.pc == 0x8004 && pin.reads == 1);
    cpu.pc = 0x8000;
    result = ag_run(pin.replacement, 1, &cpu, NULL);
    CHECK(result.steps == 1 && cpu.x[0] == 74 && cpu.pc == 0x8004);
    avz_native_memory_fast_path_destroy(memory);
    avz_native_block_cache_destroy(cache);
}

int main(void) {
    CHECK(!avz_native_block_cache_diagnostics_begin(NULL, 1));
    CHECK(!avz_native_block_cache_diagnostics_snapshot(NULL).cache_storage_bytes);
    opt_in_and_windows();
    rejection_and_memory();
    retention_lifecycle(0);
    retention_lifecycle(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    cyclic_capacity(0);
    cyclic_capacity(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    budget_pressure_and_scan(0);
    budget_pressure_and_scan(AVZ_CACHE_DIAGNOSTICS_COUNTS);
    protected_pressure();
    mixed_size_pressure();
    invalidation();
    shared_invalidation();
    lifetime_pin(0);
    lifetime_pin(1);
    lifetime_pin(2);
    CHECK(clock_calls == (AVZ_AC_DIAGNOSTICS ? 4u : 0u));
    printf("assembly cache diagnostics: PASS compiled=%d creates=%u clocks=%u\n",
        AVZ_AC_DIAGNOSTICS, create_calls, clock_calls);
    return 0;
}
