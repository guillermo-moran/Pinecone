#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdio.h>
#include <time.h>
#include "ARM64VizNative.h"

static uint64_t validation_calls, successor_calls;
static int counted_current(AVZNativeBlockCache *, const AVZNativeDecodedBlock *);
static const AVZNativeDecodedBlock *counted_recent(AVZNativeBlockCache *,
    const AVZNativeDecodedBlock *, uint64_t, const AVZNativeBlockKey *, uint64_t *);
#define avz_native_decoded_block_code_is_current counted_current
#define avz_native_decoded_block_find_recent_successor counted_recent
#ifndef AVZ_VALIDATION_NATIVE_SOURCE
#define AVZ_VALIDATION_NATIVE_SOURCE "../Sources/ARM64VizNative/ARM64VizNative.c"
#endif
#include AVZ_VALIDATION_NATIVE_SOURCE
#undef avz_native_decoded_block_code_is_current
#undef avz_native_decoded_block_find_recent_successor

static int counted_current(AVZNativeBlockCache *c, const AVZNativeDecodedBlock *b) {
    validation_calls++;
    return avz_native_decoded_block_code_is_current(c, b);
}
static const AVZNativeDecodedBlock *counted_recent(AVZNativeBlockCache *c,
    const AVZNativeDecodedBlock *b, uint64_t s, const AVZNativeBlockKey *k, uint64_t *t) {
    successor_calls++;
    return avz_native_decoded_block_find_recent_successor(c, b, s, k, t);
}

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
enum { BASE = 0x8000, SIZE = 0x10000, DATA = BASE + 0x8000 };
typedef struct {
    AVZGuestMemory *memory;
    AVZNativeBlockCache *cache;
    AVZNativeExecutionContext *context;
    AVZNativeBlockKey key;
    uint64_t bias, limit, callbacks, checkpoint_steps, checkpoint_blocks, mutation_pc;
    unsigned mutate_checkpoint, mutate_store, waits, exceptions, recycle_read;
    unsigned unrelated_read, lookup_write, unstable_mapping, fail_read;
    uint64_t zero_checkpoints;
} Fixture;

static void put(Fixture *f, uint64_t pc, uint32_t raw) {
    memcpy(avz_guest_memory_bytes(f->memory) + pc - BASE, &raw, 4);
}
static void invalidate(Fixture *f, uint64_t pc) {
    avz_guest_memory_note_write(f->memory, pc - BASE, 4);
    avz_native_block_cache_invalidate_physical_range(f->cache, pc, 4);
}
static int fetch(void *opaque, uint64_t pc, uint64_t *physical, uint32_t *raw) {
    Fixture *f = opaque;
    if (f->lookup_write) {
        f->lookup_write = 0;
        put(f, BASE + 0x2000, 0xd503201f);
        invalidate(f, BASE + 0x2000);
    }
    *physical = pc + f->bias;
    if (*physical < BASE || *physical - BASE > SIZE - 4 || (pc & 3)) return 0;
    memcpy(raw, avz_guest_memory_bytes(f->memory) + *physical - BASE, 4);
    return 1;
}
static int mapping(void *opaque, uint64_t va, uint64_t pa) {
    Fixture *f = opaque;
    if (f->unstable_mapping) {
        f->unstable_mapping = 0;
        invalidate(f, BASE + 0x2000);
    }
    return va + f->bias == pa;
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque;
    (void)write;
    *physical = address + f->bias;
    return *physical >= BASE && *physical - BASE <= SIZE - width;
}
static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    if (address != DATA || width != 8 || f->fail_read) return 0;
    memcpy(value, avz_guest_memory_bytes(f->memory) + DATA - BASE, 8);
    if (f->unrelated_read) {
        unsigned mode = f->unrelated_read;
        f->unrelated_read = 0;
        if (mode == 1) invalidate(f, BASE + 0x2000);
        if (mode == 2) avz_guest_memory_note_write(f->memory, 0x2000, 4);
        if (mode == 3) {
            AVZNativeBlockKey selected_key = f->key; selected_key.pc = BASE;
            uint32_t status, unsupported;
            const AVZNativeDecodedBlock *selected = avz_native_block_cache_get_or_decode(
                f->cache, &selected_key, fetch, f, &status, &unsupported);
            uint64_t serial = avz_native_decoded_block_serial(f->cache, selected);
            uint64_t mutation = avz_native_block_cache_mutation_epoch(f->cache);
            for (unsigned i = 1; i <= 200000 && mutation ==
                    avz_native_block_cache_mutation_epoch(f->cache); i++) {
                AVZNativeBlockKey other = f->key;
                other.pc = BASE + 0x2000; other.ttbr0_el1 = (uint64_t)i << 12;
                CHECK(avz_native_block_cache_get_or_decode(
                    f->cache, &other, fetch, f, &status, &unsupported));
            }
            CHECK(mutation != avz_native_block_cache_mutation_epoch(f->cache));
            CHECK(serial && avz_native_decoded_block_serial(f->cache, selected) == serial);
        }
        if (mode == 4 || mode == 5) {
            avz_native_block_cache_invalidate_translation_mappings(f->cache);
            f->unstable_mapping = mode == 5;
        }
    }
    if (f->recycle_read) {
        f->recycle_read = 0;
        AVZNativeBlockKey key = f->key; key.pc = BASE;
        uint32_t status, unsupported;
        const AVZNativeDecodedBlock *old = avz_native_block_cache_get_or_decode(
            f->cache, &key, fetch, f, &status, &unsupported);
        put(f, BASE + 4, 0xf9400143); /* replacement load targets x3, not x2 */
        avz_native_block_cache_clear(f->cache);
        const AVZNativeDecodedBlock *replacement = avz_native_block_cache_get_or_decode(
            f->cache, &key, fetch, f, &status, &unsupported);
        CHECK(old && replacement == old);
    }
    return 1;
}
static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    if (address != DATA || width != 8) return 0;
    memcpy(avz_guest_memory_bytes(f->memory) + DATA - BASE, &value, 8);
    if (f->mutate_store) {
        f->mutate_store = 0;
        uint64_t pc = f->mutation_pc ? f->mutation_pc : BASE + 0x40;
        put(f, pc, 0x91002421); /* add x1, x1, #9 */
        invalidate(f, pc);
    }
    return 1;
}
static int wait_callback(void *opaque, uint32_t raw, uint64_t *pc) {
    Fixture *f = opaque;
    (void)raw;
    f->waits++;
    *pc += 4;
    return AVZ_NATIVE_WAIT_YIELD;
}
static int exception_callback(void *opaque, uint32_t raw, uint64_t *registers,
    uint64_t *pstate, uint64_t *sp, uint64_t *pc) {
    Fixture *f = opaque;
    (void)registers; (void)pstate; (void)sp;
    CHECK(raw == 0xd4000001);
    f->exceptions++;
    put(f, BASE + 0x40, 0x91002421);
    invalidate(f, BASE + 0x40);
    *pc = BASE + 0x40;
    return 1;
}
static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Fixture *f = opaque;
    (void)total; (void)pc; (void)pstate; (void)remaining;
    CHECK(steps <= f->limit);
    f->callbacks++;
    f->zero_checkpoints += steps == 0;
    f->checkpoint_steps += steps;
    f->checkpoint_blocks += blocks;
    if (f->mutate_checkpoint) {
        f->mutate_checkpoint = 0;
        put(f, BASE + 0x40, 0x91002421);
        invalidate(f, BASE + 0x40);
    }
    return f->limit;
}
static AVZNativeChainResult run(Fixture *f, uint64_t budget, uint64_t blocks,
    uint64_t interval) {
    return avz_native_execution_context_run_cached_chain_checkpointed(
        f->context, f->cache, &f->key, f->limit, budget, blocks, interval,
        checkpoint, f, fetch, f, read_memory, write_memory,
        NULL, NULL, NULL, NULL, NULL, NULL, exception_callback, wait_callback, f);
}
static void reset_cpu(Fixture *f) {
    memset(&f->context->cpu, 0, sizeof(f->context->cpu));
    f->context->cpu.pc = BASE;
    f->context->cpu.pstate = 5;
    f->context->cpu.x[10] = DATA;
    f->callbacks = f->checkpoint_steps = f->checkpoint_blocks = 0;
    f->zero_checkpoints = 0;
}
static Fixture fixture(int mixed) {
    Fixture f = {.limit = 1000000, .key = {.current_el = 1}};
    f.memory = avz_guest_memory_create(SIZE);
    f.cache = avz_native_block_cache_create();
    f.context = avz_native_execution_context_create();
    CHECK(f.memory && f.cache && f.context);
    CHECK(avz_native_block_cache_bind_physical_memory(f.cache,
        avz_guest_memory_bytes(f.memory), BASE, SIZE));
    avz_native_block_cache_set_guest_memory(f.cache, f.memory);
    put(&f, BASE, 0x91000400); /* add x0, x0, #1 */
    put(&f, BASE + 4, mixed ? 0xf9400142 : 0xd503201f);
    put(&f, BASE + 8, mixed ? 0xf9000142 : 0xd503201f);
    put(&f, BASE + 12, 0x1400000d); /* b BASE+0x40 */
    put(&f, BASE + 0x40, 0x91000421); /* add x1, x1, #1 */
    put(&f, BASE + 0x44, 0xd503201f);
    put(&f, BASE + 0x48, 0x17ffffee); /* b BASE */
    reset_cpu(&f);
    return f;
}
static void destroy(Fixture *f) {
    avz_native_execution_context_destroy(f->context);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->memory);
}
static void warm(Fixture *f) {
    CHECK(run(f, 224, 10000, 10000).steps == 224);
    CHECK(run(f, 224, 10000, 10000).superblock_dispatches > 0);
    reset_cpu(f);
}
static void reference(Fixture *f, AVZNativeCPU *cpu, uint64_t steps) {
    for (uint64_t i = 0; i < steps; i++) {
        uint32_t raw; uint64_t pa; AVZNativeInstruction instruction;
        CHECK(fetch(f, cpu->pc, &pa, &raw));
        CHECK(avz_native_decode_instruction(raw, &instruction));
        CHECK(execute_decoded_instruction(&instruction, cpu, read_memory,
            write_memory, NULL, NULL, NULL, NULL, NULL, NULL,
            wait_callback, 0, f));
    }
}
static void budgets(void) {
    unsigned cases = 0;
    for (int mixed = 0; mixed < 2; mixed++) {
        Fixture f = fixture(mixed); warm(&f);
        for (uint64_t limit = 1; limit <= 17; limit += 4)
        for (uint64_t budget = 1; budget <= 97; budget++)
        for (uint64_t blocks = 1; blocks <= 8; blocks += 7) {
            reset_cpu(&f); f.limit = limit;
            AVZNativeCPU expected = f.context->cpu;
            AVZNativeChainResult result = run(&f, budget, blocks, 3);
            CHECK(result.steps > 0 && result.steps <= budget);
            CHECK(result.blocks <= blocks);
            CHECK(result.steps == f.checkpoint_steps);
            CHECK(result.blocks == f.checkpoint_blocks);
            reference(&f, &expected, result.steps);
            CHECK(memcmp(&expected, &f.context->cpu, sizeof(expected)) == 0);
            cases++;
        }
        destroy(&f);
    }
    printf("PASS budgets: %u cached-chain differential cases\n", cases);
}
static void stale(void) {
    Fixture f = fixture(0); warm(&f);
    for (unsigned mode = 0; mode < 4; mode++) {
        reset_cpu(&f);
        put(&f, BASE + 0x40, 0x91000021 | ((mode + 2) << 10));
        if (mode == 0) invalidate(&f, BASE + 0x40);
        if (mode == 1) avz_guest_memory_note_write(f.memory, 0x40, 4);
        if (mode == 2) avz_native_block_cache_clear(f.cache);
        if (mode == 3) {
            /* Same key and virtual PCs, different physical pages after TLBI. */
            memcpy(avz_guest_memory_bytes(f.memory) + 0x1000,
                avz_guest_memory_bytes(f.memory), 0x1000);
            f.bias = 0x1000;
            avz_native_block_cache_set_mapping_validator(f.cache, mapping, &f);
            avz_native_block_cache_invalidate_translation_mappings(f.cache);
        }
        CHECK(run(&f, 7, 100, 100).steps == 7);
        CHECK(f.context->cpu.x[1] == mode + 2);
    }
    reset_cpu(&f);
    f.key.ttbr0_el1 = UINT64_C(0x1234000000010000);
    f.key.tcr_el1 = 16;
    CHECK(run(&f, 7, 100, 100).steps == 7 && f.context->cpu.x[1] == 5);
    destroy(&f);
    puts("PASS stale: local write, shared-vCPU write, clear, same-key remap, TTBR/ASID");
}
static void checkpoint_invalidation(void) {
    Fixture f = fixture(0);
    put(&f, BASE + 0x40, 0xd503207f); /* wfi: pre-execution checkpoint */
    f.mutate_checkpoint = 1;
    AVZNativeChainResult result = run(&f, 7, 100, 100);
    CHECK(result.steps == 7 && f.context->cpu.x[1] == 9 && f.waits == 0);
    destroy(&f);
    puts("PASS checkpoint: stale selected barrier reselected before execution");
}
static void recycling(void) {
    Fixture f = fixture(0);
    f.key.sctlr_el1 = 1;
    warm(&f);
    AVZNativeBlockKey key = f.key; key.pc = BASE;
    int hit = 0;
    const AVZNativeSuperblock *trace = avz_native_find_superblock(f.context, f.cache, &key, &hit);
    CHECK(trace && trace->count >= 2);
    const AVZNativeDecodedBlock *old = trace->blocks[0];
    uint64_t serial = trace->serials[0];
    memcpy(avz_guest_memory_bytes(f.memory) + 0x1000,
        avz_guest_memory_bytes(f.memory), 0x1000);
    f.bias = 0x1000;
    /* Evict its set without reset: physical-page tokens still protect the copy. */
    uint32_t status, unsupported;
    int recycled = 0;
    for (unsigned i = 1; i <= 200000 && !recycled; i++) {
        AVZNativeBlockKey other = key;
        other.ttbr0_el1 = (uint64_t)i << 12;
        const AVZNativeDecodedBlock *b = avz_native_block_cache_get_or_decode(
            f.cache, &other, fetch, &f, &status, &unsupported);
        CHECK(b);
        recycled = avz_native_decoded_block_serial(f.cache, old) != serial;
        for (size_t slot = 0; slot < trace->count; slot++)
            recycled &= !avz_native_serial_token_matches(trace->serial_tokens[slot], trace->serials[slot]);
    }
    CHECK(recycled);
    f.bias = 0;
    put(&f, BASE + 0x40, 0x91002421);
    avz_guest_memory_note_write(f.memory, 0x40, 4);
    reset_cpu(&f);
    CHECK(run(&f, 7, 100, 100).steps == 7);
    CHECK(f.context->cpu.x[1] == 9);
    destroy(&f);
    puts("PASS recycling: same-pointer different-serial entry, shared write");
}
static void self_modifying(void) {
    for (int trained = 0; trained < 2; trained++)
    for (int within_block = 0; within_block < 2; within_block++) {
        Fixture f = fixture(1);
        put(&f, BASE + 16, 0x1400000c); /* b BASE+0x40 */
        if (trained) warm(&f);
        f.mutate_store = 1;
        f.mutation_pc = within_block ? BASE + 12 : BASE + 0x40;
        uint64_t budget = within_block ? 6 : 7;
        CHECK(run(&f, budget, 100, 100).steps == budget);
        CHECK(f.context->cpu.x[1] == (within_block ? 10 : 9));
        destroy(&f);
    }
    puts("PASS self-modifying: cold/warm chains, current/later block");
}
static void exception_boundary(void) {
    Fixture f = fixture(0);
    put(&f, BASE + 4, 0xd4000001);
    AVZNativeChainResult result = run(&f, 3, 100, 100);
    CHECK(result.steps == 3 && f.checkpoint_steps == 3 && f.exceptions == 1);
    CHECK(f.context->cpu.x[0] == 1 && f.context->cpu.x[1] == 9);
    CHECK(f.context->cpu.pc == BASE + 0x44);
    destroy(&f);
    puts("PASS exception: exact retirement and freshly decoded target after callback");
}
static void callback_recycling(void) {
    Fixture f = fixture(1);
    uint64_t data = 17;
    memcpy(avz_guest_memory_bytes(f.memory) + DATA - BASE, &data, 8);
    f.recycle_read = 1;
    CHECK(run(&f, 3, 100, 100).steps == 3);
    CHECK(f.context->cpu.x[2] == 17 && f.context->cpu.x[3] == 0);
    memcpy(&data, avz_guest_memory_bytes(f.memory) + DATA - BASE, 8);
    CHECK(data == 17);
    destroy(&f);
    puts("PASS callback recycling: current instruction operands survive same-pointer reuse");
}
static void irq_timer(void) {
    Fixture f = fixture(0); warm(&f);
    AVZNativeMemoryFastPath *path = avz_native_memory_fast_path_create(
        avz_guest_memory_bytes(f.memory), BASE, SIZE, f.cache, &f,
        translate, read_memory, write_memory, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(path && avz_native_memory_fast_path_set_guest_memory(path, f.memory));
    for (uint64_t deadline = 1; deadline <= 17; deadline++) {
        reset_cpu(&f); f.limit = deadline;
        AVZNativeArchitecturalState state = {.cntp_ctl_el0 = 1,
            .cntp_cval_el0 = deadline, .timer_cycles_per_instruction = 1};
        avz_native_memory_fast_path_set_architectural_state(path, &state);
        AVZNativeChainResult result = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
            f.context, f.cache, &f.key, deadline, 100, 100, 100,
            checkpoint, &f, fetch, &f, avz_native_fast_memory_read,
            avz_native_fast_memory_write, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, path);
        avz_native_memory_fast_path_get_architectural_state(path, &state);
        CHECK(result.steps == deadline && result.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(state.counter_ticks == deadline);
        CHECK(avz_native_memory_fast_path_advance_time(path, 0, 5));
        CHECK(f.checkpoint_steps == deadline);
    }
    for (int masked = 0; masked < 2; masked++) {
        reset_cpu(&f); f.limit = 1;
        f.context->cpu.pstate = masked ? 0x85 : 5;
        AVZNativeArchitecturalState state = {.pending_irq = 1,
            .timer_cycles_per_instruction = 1};
        avz_native_memory_fast_path_set_architectural_state(path, &state);
        AVZNativeChainResult result = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
            f.context, f.cache, &f.key, 1, 4, 100, 100,
            checkpoint, &f, fetch, &f, avz_native_fast_memory_read,
            avz_native_fast_memory_write, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, path);
        CHECK(result.steps == (masked ? 4 : 1));
        CHECK(result.status == (masked ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_YIELDED));
    }
    avz_native_memory_fast_path_destroy(path); destroy(&f);
    puts("PASS timer: 17 exact timer deadlines, pending IRQ masked/unmasked");
}
static void counts(void) {
    for (int self = 0; self < 2; self++) {
    Fixture f = fixture(1);
    if (self) put(&f, BASE + 12, 0x17fffffd);
    warm(&f);
    for (size_t s = 0; s < AVZ_NATIVE_SUPERBLOCK_COUNT; s++)
        f.context->superblocks[s].valid = 0;
    validation_calls = successor_calls = 0;
    AVZNativeChainResult result = run(&f, 224, 1000, 1000);
    CHECK(result.steps == 224 && result.superblock_dispatches > 0);
    printf("PASS counts: self=%d steps=%" PRIu64 " validations=%" PRIu64
        " recent_successors=%" PRIu64 " checksum=%" PRIu64 "\n",
        self, result.steps, validation_calls, successor_calls,
        f.context->cpu.x[0] + f.context->cpu.x[1] + f.context->cpu.pc);
    destroy(&f);
    }
}
static void unrelated_changes(void) {
    for (unsigned mode = 1; mode <= 4; mode++)
    for (int trained = 0; trained < 2; trained++) {
        Fixture f = fixture(1);
        f.key.sctlr_el1 = 1;
        avz_native_block_cache_set_mapping_validator(f.cache, mapping, &f);
        put(&f, BASE + 0x2000, 0x14000000);
        AVZNativeBlockKey other = f.key; other.pc = BASE + 0x2000;
        uint32_t status, unsupported;
        CHECK(avz_native_block_cache_get_or_decode(
            f.cache, &other, fetch, &f, &status, &unsupported));
        if (trained) warm(&f);
        f.unrelated_read = mode;
        uint64_t budget = trained ? 7 : 4;
        AVZNativeChainResult result = run(&f, budget, trained ? 2 : 1, 100);
        CHECK(result.steps == budget && result.blocks == (trained ? 2 : 1));
        CHECK(result.superblock_dispatches == (trained ? 1 : 0));
        CHECK(f.context->cpu.x[0] == 1 && f.context->cpu.x[1] == (uint64_t)trained);
        CHECK(f.zero_checkpoints == 0 && f.unrelated_read == 0);
        destroy(&f);
    }
    puts("PASS unrelated: cold/warm local/shared writes, eviction, unchanged remap; no fragmentation");
}
static void lookup_epochs(void) {
    for (int checkpointed = 0; checkpointed < 2; checkpointed++) {
        Fixture f = fixture(1);
        put(&f, BASE + 0x2000, 0x14000000);
        AVZNativeBlockKey other = f.key; other.pc = BASE + 0x2000;
        uint32_t status, unsupported;
        CHECK(avz_native_block_cache_get_or_decode(
            f.cache, &other, fetch, &f, &status, &unsupported));
        f.lookup_write = 1;
        AVZNativeChainResult result = checkpointed ? run(&f, 4, 1, 100) :
            avz_native_execution_context_run_cached_chain(
                f.context, f.cache, &f.key, 4, 1, fetch, &f,
                read_memory, write_memory, NULL, NULL, NULL, NULL, NULL,
                NULL, exception_callback, wait_callback, &f);
        CHECK(result.steps == 4 && result.blocks == 1 && f.lookup_write == 0);
        CHECK(f.context->cpu.pc == BASE + 0x40 && f.context->cpu.x[0] == 1);
        CHECK(f.zero_checkpoints == 0);
        destroy(&f);
    }
    puts("PASS lookup epochs: both cached-chain APIs execute valid selected block without zero-step host exit");
}
static void revalidation_boundaries(void) {
    for (int trained = 0; trained < 2; trained++) {
        Fixture f = fixture(1);
        avz_native_block_cache_set_mapping_validator(f.cache, mapping, &f);
        put(&f, BASE + 0x2000, 0x14000000);
        AVZNativeBlockKey other = f.key; other.pc = BASE + 0x2000;
        uint32_t status, unsupported;
        CHECK(avz_native_block_cache_get_or_decode(
            f.cache, &other, fetch, &f, &status, &unsupported));
        if (trained) warm(&f);
        f.unrelated_read = 5;
        AVZNativeChainResult result = run(&f, 4, 1, 100);
        CHECK(result.steps == 2 && f.context->cpu.pc == BASE + 8);
        CHECK(f.unstable_mapping == 0);
        reset_cpu(&f); f.fail_read = 1;
        result = run(&f, 4, 1, 100);
        CHECK(result.steps == 1 && f.context->cpu.pc == BASE + 4);
        CHECK(result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        destroy(&f);
    }
    puts("PASS revalidation boundaries: changing epoch during validation exits; load faults retain PC/retirement");
}
static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
static void benchmark(uint64_t iterations) {
    for (int compose = 0; compose < 2; compose++)
    for (int mixed = 0; mixed < 2; mixed++) {
        Fixture f = fixture(mixed); warm(&f);
        f.limit = UINT64_MAX;
        validation_calls = successor_calls = 0;
        double start = now();
        uint64_t steps = 0;
        for (uint64_t i = 0; i < iterations; i++) {
            /* Force composition without flushing decoded entries or links. */
            if (compose)
                for (size_t s = 0; s < AVZ_NATIVE_SUPERBLOCK_COUNT; s++)
                    f.context->superblocks[s].valid = 0;
            AVZNativeChainResult r = run(&f, 224, 1000, 1000);
            CHECK(r.steps == 224); steps += r.steps;
        }
        printf("workload=%s-%s steps=%" PRIu64 " seconds=%.9f validations=%" PRIu64
            " successors=%" PRIu64 " checksum=%" PRIu64 "\n", compose ? "compose" : "steady", mixed ? "memory" : "arithmetic",
            steps, now() - start, validation_calls, successor_calls,
            f.context->cpu.x[0] + f.context->cpu.x[1] + f.context->cpu.pc);
        destroy(&f);
    }
}
int main(int argc, char **argv) {
    CHECK(argc >= 2);
    if (!strcmp(argv[1], "budgets")) budgets();
    else if (!strcmp(argv[1], "stale")) stale();
    else if (!strcmp(argv[1], "checkpoint")) checkpoint_invalidation();
    else if (!strcmp(argv[1], "recycling")) recycling();
    else if (!strcmp(argv[1], "self-modifying")) self_modifying();
    else if (!strcmp(argv[1], "exception")) exception_boundary();
    else if (!strcmp(argv[1], "callback-recycling")) callback_recycling();
    else if (!strcmp(argv[1], "timer")) irq_timer();
    else if (!strcmp(argv[1], "counts")) counts();
    else if (!strcmp(argv[1], "unrelated")) unrelated_changes();
    else if (!strcmp(argv[1], "lookup-epochs")) lookup_epochs();
    else if (!strcmp(argv[1], "revalidation-boundaries")) revalidation_boundaries();
    else if (!strcmp(argv[1], "benchmark")) benchmark(argc > 2 ? strtoull(argv[2], NULL, 10) : 1000);
    else CHECK(0);
    return 0;
}
