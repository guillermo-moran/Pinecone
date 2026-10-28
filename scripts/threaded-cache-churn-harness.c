/* White-box adapter tests; runner snapshots each variant's own dependencies. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ARM64VizNative.h"
#include "ARM64VizThreadedPrototype.h"

#ifndef AVZ_CHURN_MEMORY_AWARE
#define AVZ_CHURN_MEMORY_AWARE 0
#endif

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static struct {
    uint64_t scans, supports, memory_supports, attempts, creates, destroys, live, peak, bytes, peak_bytes;
} measured;
static int lookup_scanned, fail_next;

#if AVZ_THREADED_PROTOTYPE_ENABLE
static int counted_supports(const AVZNativeInstruction *instruction) {
    if (!lookup_scanned++) measured.scans++;
    measured.supports++;
    return avz_tp_supports_instruction(instruction);
}
#if AVZ_CHURN_MEMORY_AWARE
static int counted_memory_supports(const AVZNativeInstruction *instruction) {
    measured.memory_supports++;
    return avz_tp_supports_instruction_with_memory(instruction);
}
#define avz_tp_supports_instruction_with_memory counted_memory_supports
#endif
static AVZThreadedPrototype *counted_create(const uint32_t *words, size_t count,
                                           uint64_t pc) {
    measured.attempts++;
    if (fail_next) { fail_next = 0; return NULL; }
    AVZThreadedPrototype *program = avz_tp_create(words, count, pc);
    if (program) {
        measured.creates++; measured.live++;
        measured.bytes += avz_tp_program_bytes(program);
        if (measured.live > measured.peak) measured.peak = measured.live;
        if (measured.bytes > measured.peak_bytes) measured.peak_bytes = measured.bytes;
        CHECK(measured.live <= 256);
    }
    return program;
}
static void counted_destroy(AVZThreadedPrototype *program) {
    if (program) {
        CHECK(measured.live > 0);
        measured.live--; measured.destroys++;
        measured.bytes -= avz_tp_program_bytes(program);
    }
    avz_tp_destroy(program);
}
#define avz_tp_supports_instruction counted_supports
#define avz_tp_create counted_create
#define avz_tp_destroy counted_destroy
#endif
#include AVZ_CACHE_SOURCE
#undef avz_tp_supports_instruction
#undef avz_tp_supports_instruction_with_memory
#undef avz_tp_create
#undef avz_tp_destroy

static AVZBlockCacheEntry *seed(AVZNativeBlockCache *cache, size_t index,
                                 int unsupported, unsigned immediate) {
    AVZBlockCacheEntry *entry = &cache->entries[index];
    if (entry->valid) avz_invalidate_entry(cache, index);
    memset(&entry->block, 0, sizeof(entry->block));
    entry->block.key.pc = 0x100000 + index * 0x1000;
    entry->block.instruction_count = 8;
    for (size_t i = 0; i < 8; i++) {
        uint32_t word = i == 7 ? 0x17fffff9u : 0x91000000u + (immediate << 10);
        /* Unsupported hint remains negative even as memory coverage expands. */
        if (unsupported && i == 6) word = 0xd503203fu; /* YIELD */
        CHECK(avz_native_decode_instruction(word, &entry->block.instructions[i]));
        entry->block.physical_addresses[i] = entry->block.key.pc + i * 4;
    }
    entry->serial = avz_allocate_block_serial(cache);
    entry->validated_code_mutation_epoch = cache->code_mutation_epoch;
    entry->validated_shared_code_mutation_epoch =
        avz_native_block_cache_shared_code_mutation_epoch(cache);
    entry->validated_translation_epoch = cache->translation_epoch;
    entry->valid = 1;
    avz_index_entry(cache, index);
    return entry;
}

#if AVZ_THREADED_PROTOTYPE_ENABLE
static const AVZThreadedPrototype *lookup(AVZNativeBlockCache *cache, size_t index) {
    lookup_scanned = 0;
    return avz_native_block_cache_threaded_program(cache, &cache->entries[index].block);
}
static uint64_t execute(const AVZThreadedPrototype *program, uint64_t pc) {
    AVZNativeCPU cpu = {0}; cpu.pc = pc;
    AVZNativeBlockResult result = avz_tp_run(program, 1, &cpu);
    CHECK(result.steps == 1);
    return cpu.x[0];
}
static int reject_mapping(void *context, uint64_t va, uint64_t pa) {
    (void)context; (void)va; (void)pa; return 0;
}
static int fetch_pair(void *context, uint64_t pc, uint64_t *physical, uint32_t *word) {
    (void)context; *physical = pc;
    *word = (pc & 4) ? 0x17ffffffu : 0x91000400u;
    return 1;
}
static void decode_eviction(void) {
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    size_t found = 0;
    for (uint64_t pc = 0x1000; found < 5; pc += 0x1000) {
        AVZNativeBlockKey key = {.pc = pc};
        if (avz_block_set_index(avz_block_key_hash(cache, &key)) != 0) continue;
        uint32_t status, unsupported;
        const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
            cache, &key, fetch_pair, NULL, &status, &unsupported);
        CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
        CHECK(avz_native_block_cache_threaded_program(cache, block));
        found++;
    }
    CHECK(cache->statistics.evictions == 1);
#if AVZ_CHURN_CANDIDATE
    CHECK(measured.live == 4);
#endif
    avz_native_block_cache_destroy(cache); CHECK(measured.live == 0);
}
#if AVZ_CHURN_CANDIDATE
static void check_fifo_links(AVZNativeBlockCache *cache) {
    unsigned seen[256] = {0};
    size_t slot = cache->threaded_lru;
    int live_seen = 0;
    for (size_t i = 0; i < 256; i++) {
        CHECK(slot < 256 && !seen[slot]++);
        size_t next = cache->threaded_programs[slot].next;
        CHECK(next < 256 && cache->threaded_programs[next].previous == slot);
        if (cache->threaded_programs[slot].program) {
            live_seen = 1;
            CHECK(cache->threaded_programs[slot].owner->threaded_slot == slot + 1);
        } else CHECK(!live_seen);
        slot = next;
    }
    CHECK(slot == cache->threaded_lru);
}
static void fifo_correctness(void) {
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    for (size_t i = 1; i <= 256; i++) { seed(cache, i, 0, 1); CHECK(lookup(cache, i)); }
    uint16_t head = cache->threaded_lru, previous[256], next[256];
    for (size_t i = 0; i < 256; i++) {
        previous[i] = cache->threaded_programs[i].previous;
        next[i] = cache->threaded_programs[i].next;
    }
    CHECK(lookup(cache, 1));
    CHECK(cache->threaded_lru == head);
    for (size_t i = 0; i < 256; i++) {
        CHECK(previous[i] == cache->threaded_programs[i].previous);
        CHECK(next[i] == cache->threaded_programs[i].next);
    }
    seed(cache, 257, 0, 1); CHECK(lookup(cache, 257));
    /* A hit must not save the oldest insertion from FIFO replacement. */
    CHECK(!cache->entries[1].threaded_slot && cache->entries[2].threaded_slot);
    check_fifo_links(cache);
    avz_invalidate_entry(cache, 128); check_fifo_links(cache);
    CHECK(measured.live == 255);
    CHECK(lookup(cache, 1)); check_fifo_links(cache); CHECK(measured.live == 256);
    CHECK(cache->entries[2].threaded_slot);
    for (size_t i = 3; i < 257; i += 3) { avz_invalidate_entry(cache, i); check_fifo_links(cache); }
    for (size_t i = 1; i <= 257; i++) {
        seed(cache, i, 0, 1); CHECK(lookup(cache, i)); check_fifo_links(cache);
    }
    avz_native_block_cache_clear(cache); check_fifo_links(cache);
    avz_native_block_cache_destroy(cache); CHECK(!measured.live);
}
#if AVZ_CHURN_MEMORY_AWARE
static const AVZThreadedPrototype *lookup_memory(AVZNativeBlockCache *cache,
                                               size_t index) {
    lookup_scanned = 0;
    return avz_native_block_cache_threaded_program_with_memory(
        cache, &cache->entries[index].block, 1);
}
static void memory_eligibility_correctness(void) {
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    AVZBlockCacheEntry *entry = seed(cache, 1, 0, 1);
    CHECK(avz_native_decode_instruction(0xf9400022u, &entry->block.instructions[6]));
    uint64_t scans = measured.scans;
    CHECK(!lookup(cache, 1) && entry->threaded_eligibility == 4);
    CHECK(!lookup(cache, 1) && measured.scans == scans + 1);
    const AVZThreadedPrototype *program = lookup_memory(cache, 1); CHECK(program);
    CHECK(avz_tp_program_uses_memory(program));
    CHECK(!lookup(cache, 1)); /* An allocated class-4 program remains gated. */
    uint16_t head = cache->threaded_lru;
    CHECK(lookup_memory(cache, 1) == program && cache->threaded_lru == head);
    CHECK(measured.scans == scans + 1);
    for (size_t i = 2; i <= 257; i++) { seed(cache, i, 0, 1); CHECK(lookup(cache, i)); }
    CHECK(!entry->threaded_slot && entry->threaded_eligibility == 4);
    scans = measured.scans;
    CHECK(!lookup(cache, 1));
    CHECK(lookup_memory(cache, 1));
    CHECK(measured.scans == scans);
    check_fifo_links(cache);
    seed(cache, 1, 0, 1); /* New decoded lifetime must drop memory eligibility. */
    program = lookup(cache, 1); CHECK(program && !avz_tp_program_uses_memory(program));
    avz_native_block_cache_destroy(cache); CHECK(!measured.live);
    puts("memory_eligibility=pass class4_gate,cached_gate,eviction,recreation,lifetime_reset");
}
#endif
#endif
static void correctness(void) {
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    AVZBlockCacheEntry *e = seed(cache, 1, 0, 1);
    const AVZThreadedPrototype *p = lookup(cache, 1); CHECK(p);
    CHECK(execute(p, e->block.key.pc) == 1);
    CHECK(lookup(cache, 1) == p);
    avz_native_block_cache_invalidate_physical_range(cache, e->block.key.pc, 4);
    CHECK(!e->valid && lookup(cache, 1) == NULL);
#if AVZ_CHURN_CANDIDATE
    CHECK(measured.live == 0);
#endif
    seed(cache, 1, 0, 2);
    CHECK(execute(lookup(cache, 1), e->block.key.pc) == 2);

    /* Actual nonzero serial allocator wrap, same decoded-entry address. */
    avz_native_block_cache_clear(cache);
    cache->next_serial = 0; seed(cache, 1, 0, 1); CHECK(lookup(cache, 1));
    cache->next_serial = UINT64_MAX; seed(cache, 1, 0, 2);
    uint64_t recycled = execute(lookup(cache, 1), e->block.key.pc);
#if AVZ_CHURN_CANDIDATE
    CHECK(recycled == 2);
#else
    printf("known_baseline_serial_recycling_stale=%d\n", recycled != 2);
#endif

    avz_native_block_cache_clear(cache); CHECK(measured.live == 0);
    seed(cache, 1, 1, 1);
    uint64_t scans = measured.scans;
    CHECK(!lookup(cache, 1) && !lookup(cache, 1));
    CHECK(measured.scans == scans + 1);
    seed(cache, 1, 0, 1); CHECK(lookup(cache, 1));
    avz_discard_stale_entry(cache, 1); CHECK(!lookup(cache, 1));
#if AVZ_CHURN_CANDIDATE
    CHECK(measured.live == 0);
#endif
    seed(cache, 1, 0, 1); CHECK(lookup(cache, 1));
    uint64_t token = 1;
    e->block.code_page_generation_tokens[0] = &token;
    e->block.code_page_generations[0] = token;
    token++; cache->code_mutation_epoch++;
    CHECK(!lookup(cache, 1));
#if AVZ_CHURN_CANDIDATE
    CHECK(measured.live == 0);
#endif
    avz_native_block_cache_clear(cache);
    seed(cache, 1, 0, 1); CHECK(lookup(cache, 1));
    avz_native_block_cache_set_mapping_validator(cache, reject_mapping, NULL);
    avz_native_block_cache_invalidate_translation_mappings(cache);
    CHECK(!lookup(cache, 1));
    avz_native_block_cache_clear(cache);
    seed(cache, 1, 0, 1); fail_next = 1;
    uint64_t attempts = measured.attempts;
    CHECK(!lookup(cache, 1) && !lookup(cache, 1));
    CHECK(measured.attempts == attempts + 1);
    seed(cache, 1, 0, 2); CHECK(lookup(cache, 1));
    avz_native_block_cache_destroy(cache);
    CHECK(measured.live == 0 && measured.bytes == 0);
    CHECK(measured.creates == measured.destroys);
    AVZGuestMemory *memory = avz_guest_memory_create(4096); CHECK(memory);
    cache = avz_native_block_cache_create(); CHECK(cache);
    CHECK(avz_native_block_cache_bind_physical_memory(cache,
          avz_guest_memory_bytes(memory), 0x101000, 4096));
    avz_native_block_cache_set_guest_memory(cache, memory);
    seed(cache, 1, 0, 1); CHECK(lookup(cache, 1));
    avz_guest_memory_note_write(memory, 0, 4);
    CHECK(!lookup(cache, 1));
    avz_native_block_cache_destroy(cache); avz_guest_memory_destroy(memory);
    CHECK(!measured.live);
    decode_eviction();
#if AVZ_CHURN_CANDIDATE
    fifo_correctness();
#if AVZ_CHURN_MEMORY_AWARE
    memory_eligibility_correctness();
#endif
#endif
    puts("correctness=pass invalidation,clear,destroy,negative,allocation_failure,code_generation,shared_generation,mapping,decode_eviction");
#if AVZ_CHURN_CANDIDATE
    puts("candidate_extra=pass serial_recycling,fifo_order,hit_does_not_reorder,fifo_links,free_slot_reuse");
#endif
}

static void stream(const char *name, unsigned mode, uint64_t iterations) {
    CHECK(measured.live == 0); memset(&measured, 0, sizeof(measured));
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    size_t collision[5], found = 0;
    for (size_t i = 1; i < 4096; i++) {
        if ((avz_mix_u64(i) & 63u) == 0 && found < 5) collision[found++] = i;
        seed(cache, i, mode == 3 || (mode == 4 && (i % 4 != 0)), 1);
    }
    CHECK(found == 5);
    uint64_t positive = 0, checksum = 0;
    clock_t start = clock();
    for (uint64_t i = 0; i < iterations; i++) {
        size_t index;
        if (mode == 0) index = 1 + (i % 32); /* compact all-supported hot set */
        else if (mode == 1) index = 1 + 256 * (i % 4); /* old direct-slot collision */
        else if (mode == 2) index = collision[i % 5]; /* rejected four-way policy */
        else if (mode == 3) index = 1 + 256 * (i % 4); /* colliding negatives */
        else if (mode == 4) {
            /* 90% 64-entry hot working set, 10% 3072-entry cold stream. */
            index = i % 10 ? 1 + ((i * 17) % 64) : 1024 + ((i / 10) % 3072);
        } else index = 1 + (i % 4095); /* positive capacity stress */
        const AVZThreadedPrototype *p = lookup(cache, index);
        CHECK((p != NULL) == !(mode == 3 || (mode == 4 && index % 4 != 0)));
        if (p) { positive++; checksum += index; }
        if (p && i < 32) CHECK(execute(p, cache->entries[index].block.key.pc) == 1);
    }
    double cpu_s = (double)(clock() - start) / CLOCKS_PER_SEC;
    printf("stream=%s lookups=%" PRIu64 " positive=%" PRIu64 " checksum=%" PRIu64
           " scans=%" PRIu64 " supports=%" PRIu64 " memory_supports=%" PRIu64 " creates=%" PRIu64
           " destroys_before_clear=%" PRIu64 " peak_programs=%" PRIu64
           " peak_bytes=%" PRIu64 " cpu_s=%.6f",
           name, iterations, positive, checksum, measured.scans, measured.supports, measured.memory_supports,
           measured.creates, measured.destroys, measured.peak, measured.peak_bytes, cpu_s);
#if AVZ_CHURN_CANDIDATE && AVZ_THREADED_CACHE_DIAGNOSTICS
    printf(" hits=%" PRIu64 " negative_hits=%" PRIu64 " collisions=%" PRIu64,
           cache->threaded_statistics.hits, cache->threaded_statistics.negative_hits,
           cache->threaded_statistics.collisions);
    CHECK(cache->threaded_statistics.eligibility_scans == measured.scans);
    CHECK(cache->threaded_statistics.creations == measured.creates);
    CHECK(cache->threaded_statistics.destructions == measured.destroys);
#endif
    putchar('\n');
    avz_native_block_cache_clear(cache);
    CHECK(measured.live == 0 && measured.bytes == 0);
    CHECK(measured.creates == measured.destroys);
    avz_native_block_cache_destroy(cache);
}
#endif

int main(int argc, char **argv) {
    uint64_t iterations = argc > 1 ? strtoull(argv[1], NULL, 10) : 2000;
    CHECK(iterations > 0 && iterations <= 10000000);
    printf("candidate=%d enabled=%d diagnostics=%d memory_aware=%d entry_bytes=%zu cache_bytes=%zu\n",
           AVZ_CHURN_CANDIDATE, AVZ_THREADED_PROTOTYPE_ENABLE,
           AVZ_THREADED_CACHE_DIAGNOSTICS, AVZ_CHURN_MEMORY_AWARE,
           sizeof(AVZBlockCacheEntry), sizeof(AVZNativeBlockCache));
#if AVZ_THREADED_PROTOTYPE_ENABLE
    uint32_t max_words[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    for (size_t i = 0; i < AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS; i++) max_words[i] = 0xd503201f;
    AVZThreadedPrototype *max_program = avz_tp_create(max_words,
        AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS, 0x8000); CHECK(max_program);
    printf("max_program_bytes=%zu program_payload_bound=%zu\n",
           avz_tp_program_bytes(max_program), 256 * avz_tp_program_bytes(max_program));
    avz_tp_destroy(max_program);
    correctness();
    const char *names[] = {"hot", "direct_collision", "fourway_collision", "negative_collision", "mixed_hot_cold", "capacity"};
    for (unsigned mode = 0; mode < 6; mode++) stream(names[mode], mode, iterations);
#else
    CHECK(!avz_tp_available());
    uint32_t words[] = {0x91000400, 0x17ffffff};
    CHECK(!avz_tp_create(words, 2, 0x8000));
    AVZNativeBlockCache *cache = avz_native_block_cache_create(); CHECK(cache);
    seed(cache, 1, 0, 1); avz_invalidate_entry(cache, 1);
    avz_native_block_cache_clear(cache); avz_native_block_cache_destroy(cache);
    puts("disabled=pass");
#endif
    return 0;
}
