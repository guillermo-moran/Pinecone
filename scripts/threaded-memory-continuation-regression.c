/* Dedicated adversarial tests. Run via run-threaded-runtime-regressions.sh.
 * Each vCPU owns its cache/fast path; only guest RAM/epochs are shared. */
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#if AVZ_TEST_ASSEMBLY
#include "assembly-test-adapter.h"
#endif

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "continuation line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { RAM_SIZE = 0x40000, CODE = 0x1000, DATA = 0x4000, DEVICE = 0x100000 };
enum { NONE, CLEAR, EVICT, REMAP, TRANSLATE_CLEAR };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache[2];
    AVZNativeMemoryFastPath *path[2];
    unsigned calls, faults, action;
    int fail, remapped;
    uint64_t last_value;
} Fixture;

static const AVZThreadedPrototype *cached(Fixture *f, uint64_t pc) {
    AVZNativeBlockKey key = {.pc = pc, .current_el = 1};
    uint32_t status, unsupported;
    const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
        f->cache[0], &key, avz_native_fast_fetch_instruction, f->path[0],
        &status, &unsupported);
    CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    const AVZThreadedPrototype *p = avz_native_block_cache_threaded_program_with_memory(
        f->cache[0], block, 1);
    CHECK(p);
    return p;
}

static void action(Fixture *f) {
    unsigned action = f->action;
    f->action = NONE;
    if (action == CLEAR || action == TRANSLATE_CLEAR) {
        avz_native_block_cache_clear(f->cache[0]);
    } else if (action == EVICT) {
        /* Exceed the auxiliary program pool while the original is pinned. */
        for (unsigned i = 0; i < 300; i++) {
            uint32_t code[] = {0xd503201f, 0x14000001};
            uint64_t pc = 0x10000 + i * 16;
            memcpy(avz_guest_memory_bytes(f->ram) + pc, code, sizeof(code));
            (void)cached(f, pc);
        }
    } else if (action == REMAP) {
        f->remapped = 1;
        avz_native_memory_fast_path_invalidate_translation(f->path[0]);
    }
}

static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque;
    (void)write;
    if (f->action == TRANSLATE_CLEAR && address == DATA) action(f);
    if (address > RAM_SIZE - width) return 0;
    *physical = address + (f->remapped && address >= DATA && address < DATA + 4096 ? 4096 : 0);
    return 1;
}

static int device_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    if (address != DEVICE) {
        CHECK(width <= 8 && address <= RAM_SIZE - width);
        avz_guest_memory_lock_range(f->ram, address, width);
        *value = 0;
        memcpy(value, avz_guest_memory_bytes(f->ram) + address, width);
        avz_guest_memory_unlock_range(f->ram, address, width);
        return 1;
    }
    CHECK(address == DEVICE && width == 8);
    f->calls++;
    action(f);
    *value = 73;
    return !f->fail;
}

static int device_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    if (address != DEVICE) {
        CHECK(width <= 8 && address <= RAM_SIZE - width);
        avz_guest_memory_lock_range(f->ram, address, width);
        memcpy(avz_guest_memory_bytes(f->ram) + address, &value, width);
        avz_guest_memory_note_write(f->ram, address, width);
        avz_guest_memory_unlock_range(f->ram, address, width);
        return 1;
    }
    CHECK(address == DEVICE && width == 8);
    f->calls++;
    f->last_value = value;
    action(f);
    return !f->fail;
}

static void fault(void *opaque, uint64_t address, uint8_t access,
    uint8_t level, uint8_t status) {
    Fixture *f = opaque;
    (void)address; (void)access; (void)level; (void)status;
    f->faults++;
    action(f);
}

static void init(Fixture *f, const uint32_t *words, size_t count) {
    memset(f, 0, sizeof(*f));
    f->ram = avz_guest_memory_create(RAM_SIZE);
    CHECK(f->ram);
    memcpy(avz_guest_memory_bytes(f->ram) + CODE, words, count * 4);
    for (unsigned i = 0; i < 2; i++) {
        f->cache[i] = avz_native_block_cache_create();
        CHECK(f->cache[i]);
        CHECK(avz_native_block_cache_bind_physical_memory(f->cache[i],
            avz_guest_memory_bytes(f->ram), 0, RAM_SIZE));
        f->path[i] = avz_native_memory_fast_path_create(avz_guest_memory_bytes(f->ram),
            0, RAM_SIZE, f->cache[i], f, translate, device_read, device_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(f->path[i] && avz_native_memory_fast_path_set_guest_memory(f->path[i], f->ram));
        /* Production uses cheap telemetry; detailed accounting intentionally
         * routes assembly memory operations through terminal C helpers. */
        avz_native_memory_fast_path_set_detailed_statistics_enabled(f->path[i], 0);
        avz_native_memory_fast_path_set_instruction_translator(f->path[i], translate);
    }
}

static void finish(Fixture *f) {
    for (unsigned i = 0; i < 2; i++) {
        avz_native_memory_fast_path_destroy(f->path[i]);
        avz_native_block_cache_destroy(f->cache[i]);
    }
    avz_guest_memory_destroy(f->ram);
}

static void warm(Fixture *f, uint64_t address, uint8_t width, uint64_t value) {
    uint64_t readback;
    CHECK(avz_native_fast_memory_write(f->path[0], address, width, value));
    CHECK(avz_native_fast_memory_read(f->path[0], address, width, &readback));
}

static AVZNativeCPU cpu(void) {
    AVZNativeCPU c = {.pc = CODE, .pstate = 5, .sp = DATA,
        .exclusive_valid = 1, .exclusive_size = 8,
        .exclusive_address = DATA, .exclusive_generation = 77};
    c.x[10] = DATA;
    c.x[11] = DATA + 4096;
    return c;
}

static void hot_differential(void) {
    unsigned cases = 0;
    for (unsigned size = 0; size < 4; size++)
    for (unsigned sp = 0; sp < 2; sp++)
    for (unsigned zero = 0; zero < 2; zero++)
    for (unsigned budget = 0; budget < 24; budget++) {
        unsigned base = sp ? 31 : 10, reg = zero ? 31 : 0;
        uint32_t words[] = {0x39400000 | (size << 30) | (base << 5) | reg,
            0x91000400, 0x39000000 | (size << 30) | (base << 5) | reg, 0x17fffffd};
        Fixture a, b;
        init(&a, words, 4); init(&b, words, 4);
        warm(&a, DATA, 1u << size, UINT64_MAX);
        warm(&b, DATA, 1u << size, UINT64_MAX);
        avz_guest_memory_advance_dirty_epoch(a.ram);
        avz_guest_memory_advance_dirty_epoch(b.ram);
        const AVZThreadedPrototype *p = cached(&a, CODE);
        AVZNativeCPU actual = cpu(), expected = actual;
        AVZNativeInstruction decoded[4];
        for (unsigned i = 0; i < 4; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
        AVZNativeBlockResult got = avz_tp_run_with_memory(p, budget, &actual, a.path[0]);
        AVZNativeBlockResult want = avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
            decoded, 4, CODE, budget, expected.x, NULL, NULL,
            &expected.sp, &expected.pc, &expected.pstate, &expected.fpcr, &expected.fpsr,
            &expected.exclusive_address, &expected.exclusive_generation,
            &expected.exclusive_size, &expected.exclusive_valid, &expected.halted,
            avz_native_fast_memory_read, avz_native_fast_memory_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, b.path[0]);
        if (got.steps != budget || got.status != AVZ_NATIVE_STATUS_MAX_STEPS)
            fprintf(stderr, "hot size=%u sp=%u zero=%u budget=%u: steps=%llu status=%u pc=%llx\n",
                size, sp, zero, budget, (unsigned long long)got.steps, got.status,
                (unsigned long long)actual.pc);
        CHECK(got.steps == budget && got.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(got.steps == want.steps && got.status == want.status);
        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
        CHECK(memcmp(avz_guest_memory_bytes(a.ram), avz_guest_memory_bytes(b.ram), RAM_SIZE) == 0);
        AVZGuestDirtyRange ar[8], br[8];
        size_t ac = avz_guest_memory_dirty_ranges(a.ram, 0, RAM_SIZE, 0, UINT64_MAX, ar, 8);
        size_t bc = avz_guest_memory_dirty_ranges(b.ram, 0, RAM_SIZE, 0, UINT64_MAX, br, 8);
        CHECK(ac == bc && memcmp(ar, br, ac * sizeof(*ar)) == 0);
        CHECK(!a.calls && !a.faults);
        finish(&a); finish(&b); cases++;
    }
    printf("PASS hot continuation: %u width/SP/XZR/budget differential cases\n", cases);
}

static void callbacks(void) {
    for (unsigned store = 0; store < 2; store++)
    for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned physical = 0; physical < 2; physical++)
    for (unsigned act = NONE; act <= REMAP; act++)
    for (unsigned budget = 1; budget <= 3; budget++) {
        uint32_t words[] = {store ? 0xf9000140 : 0xf9400140, 0x91000421, 0x17fffffe};
        Fixture f; init(&f, words, 3);
        if (physical) {
            AVZNativeStage1TranslationState s = {.current_el = 1};
            avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
            avz_native_memory_fast_path_set_physical_memory_callbacks(f.path[0], device_read, device_write);
        }
        const AVZThreadedPrototype *p = cached(&f, CODE);
        AVZNativeCPU c = cpu(); c.x[10] = DEVICE; c.x[0] = 0x123456789;
        AVZNativeCPU before = c;
        f.fail = fail; f.action = act;
        AVZNativeBlockResult r = avz_tp_run_with_memory(p, budget, &c, f.path[0]);
        CHECK(f.calls == 1 && c.x[1] == 0);
        CHECK(r.steps == (fail ? 0 : 1));
        CHECK(r.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(!fail || memcmp(&c, &before, sizeof(c)) == 0);
        if (!fail) CHECK(c.pc == CODE + 4);
        if (store) CHECK(f.last_value == before.x[0]);
        finish(&f);
    }
    /* A translation callback can retire the current allocation before RAM is read. */
    uint32_t words[] = {0xf9400140, 0x91000421, 0x17fffffe};
    Fixture f; init(&f, words, 3);
    const AVZThreadedPrototype *p = cached(&f, CODE);
    f.action = TRANSLATE_CLEAR;
    AVZNativeCPU c = cpu();
    AVZNativeBlockResult r = avz_tp_run_with_memory(p, 3, &c, f.path[0]);
    CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
    finish(&f);
    puts("PASS callback success/failure, physical MMIO exactly once, clear, 300-program eviction, remap");
}

static void code_writes_and_entry_races(void) {
    uint32_t words[] = {0xb9000140, 0x91000421, 0x17fffffe};
    for (unsigned other_vcpu = 0; other_vcpu < 2; other_vcpu++)
    for (unsigned budget = 1; budget <= 3; budget++) {
        Fixture f; init(&f, words, 3);
        warm(&f, CODE + 4, 4, words[1]);
        const AVZThreadedPrototype *p = cached(&f, CODE);
        uint64_t local = avz_native_block_cache_code_mutation_epoch(f.cache[0]);
        uint64_t shared = avz_native_block_cache_shared_code_mutation_epoch(f.cache[0]);
        AVZNativeCPU c = cpu(); c.x[10] = CODE + 4; c.x[0] = 0x91000821;
        if (other_vcpu) CHECK(avz_native_fast_memory_write(f.path[1], CODE + 4, 4, c.x[0]));
        AVZNativeBlockResult r = avz_tp_run_guarded(p, budget, &c, f.path[0], f.cache[0], local, shared);
        CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == (other_vcpu ? 0 : 1));
        CHECK(c.x[1] == 0);
        c.pc = CODE + 4;
        p = cached(&f, CODE + 4);
        r = avz_tp_run_with_memory(p, 1, &c, f.path[0]);
        CHECK(r.steps == 1 && c.x[1] == 2);
        finish(&f);
    }
    /* A local mapping invalidation need not retire the allocation to stop it. */
    Fixture f; init(&f, words, 3);
    const AVZThreadedPrototype *p = cached(&f, CODE);
    uint64_t local = avz_native_block_cache_code_mutation_epoch(f.cache[0]);
    uint64_t shared = avz_native_block_cache_shared_code_mutation_epoch(f.cache[0]);
    avz_native_block_cache_invalidate_translation_mappings(f.cache[0]);
    AVZNativeCPU c = cpu();
    AVZNativeBlockResult r = avz_tp_run_guarded(p, 3, &c, f.path[0], f.cache[0], local, shared);
    CHECK(r.steps == 0 && r.status == AVZ_TP_STATUS_REVALIDATE);
    finish(&f);
    puts("PASS hot self-modifying store, shared code entry race, local remap entry race");
}

static void remap_and_pending_tlbi(void) {
    uint32_t words[] = {0xf9400140, 0xf9400161, 0x14000001};
    Fixture f; init(&f, words, 3);
    warm(&f, DATA, 8, 11); warm(&f, DATA + 4096, 8, 22);
    const AVZThreadedPrototype *p = cached(&f, CODE);
    AVZNativeCPU c = cpu(); c.x[10] = DEVICE; c.x[11] = DATA;
    f.action = REMAP;
    AVZNativeBlockResult r = avz_tp_run_with_memory(p, 3, &c, f.path[0]);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 1 && c.x[1] == 0);
    p = cached(&f, CODE + 4);
    r = avz_tp_run_with_memory(p, 2, &c, f.path[0]);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 1 && c.x[1] == 22);
    c.pc = CODE + 4; c.x[1] = 0;
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
    r = avz_tp_run_with_memory(p, 2, &c, f.path[0]);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 0 && c.x[1] == 0);
    avz_native_memory_fast_path_synchronize_translations(f.path[0]);
    p = cached(&f, CODE + 4);
    r = avz_tp_run_with_memory(p, 2, &c, f.path[0]);
    CHECK(r.steps == 1 && c.x[1] == 22);
    finish(&f);
    puts("PASS hot-VA remapping and pending shared TLBI before entry");
}

static void observations_and_faults(void) {
    uint32_t words[] = {0xf9000140, 0x91000421, 0x17fffffe};
    for (unsigned mode = 0; mode < 5; mode++) {
        Fixture f; init(&f, words, 3);
        uint64_t address = DATA + (mode == 2 ? 1 : mode == 3 ? 4093 : 0);
        warm(&f, address, 8, 7);
        uint64_t value = 0, generation = 0;
        if (mode == 0) CHECK(avz_guest_memory_exclusive_read(f.ram, DATA, 8, &value, &generation));
        if (mode == 1) CHECK(avz_guest_memory_register_host_range(f.ram, DATA, 8));
        if (mode == 4) {
            /* Retained bulk-reader flag is the same gate used by the reference hot helper. */
            atomic_store(&f.ram->page_observation_flags[DATA >> 12], AVZ_GUEST_PAGE_OBSERVATION_BULK_READER);
        }
        const AVZThreadedPrototype *p = cached(&f, CODE);
        AVZNativeCPU c = cpu(); c.x[10] = address; c.x[0] = 7; /* Same-value store must break exclusives. */
        AVZNativeBlockResult r = avz_tp_run_with_memory(p, 3, &c, f.path[0]);
        CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
        CHECK(!c.exclusive_valid && !c.exclusive_generation);
        if (mode == 0) CHECK(!avz_guest_memory_exclusive_write(f.ram, DATA, 8, 9, generation));
        finish(&f);
    }
    for (unsigned store = 0; store < 2; store++) {
        words[0] = store ? 0xf9000140 : 0xf9400140;
        Fixture f; init(&f, words, 3);
        AVZThreadedPrototype *p = avz_tp_create(words, 3, CODE);
        AVZNativeStage1TranslationState s = {.sctlr_el1 = 1, .tcr_el1 = 16, .ttbr0_el1 = 0x8000, .current_el = 1};
        avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
        f.action = CLEAR;
        AVZNativeCPU c = cpu(), before = c;
        AVZNativeBlockResult r = avz_tp_run_with_memory(p, 3, &c, f.path[0]);
        CHECK(r.status == AVZ_TP_STATUS_MEMORY_FAULT && !r.steps && f.faults == 1 && !f.calls);
        CHECK(memcmp(&c, &before, sizeof(c)) == 0);
        avz_tp_destroy(p); finish(&f);
    }
    puts("PASS exclusive/host/bulk observation, unaligned/cross-page stores, precise translation faults");
}

typedef struct {
    Fixture *f;
    const AVZThreadedPrototype *program;
    AVZNativeCPU cpu;
    AVZNativeBlockResult result;
    uint64_t code_epoch, shared_epoch;
    _Atomic int done;
} Worker;

static void *run_worker(void *opaque) {
    Worker *w = opaque;
    w->result = avz_tp_run_guarded(w->program, UINT64_C(1000000000), &w->cpu,
        w->f->path[0], w->f->cache[0], w->code_epoch, w->shared_epoch);
    atomic_store(&w->done, 1);
    return NULL;
}

static void concurrent_shootdown_case(unsigned register_tail) {
    uint32_t words[] = {0xf9400140, 0xf9000160, 0x17fffffe};
    if (register_tail) {
        /* Publish entry once, then execute only ADD/B. No memory helper can
         * observe the peer's shootdown; the dispatch guard must stop the tail. */
        words[0] = 0xf9000160; // str x0, [x11]
        words[1] = 0x91000400; // add x0, x0, #1
        words[2] = 0x17ffffff; // b #-4
    }
    for (unsigned kind = 0; kind < 5; kind++) {
        Fixture f; init(&f, words, 3);
        warm(&f, DATA, 8, 1); warm(&f, DATA + 4096, 8, 0);
        Worker w = {.f = &f, .program = cached(&f, CODE), .cpu = cpu(),
            .code_epoch = avz_native_block_cache_code_mutation_epoch(f.cache[0]),
            .shared_epoch = avz_native_block_cache_shared_code_mutation_epoch(f.cache[0])};
        if (register_tail) w.cpu.x[0] = 1;
        pthread_t thread;
        CHECK(!pthread_create(&thread, NULL, run_worker, &w));
        uint64_t *signal = (uint64_t *)(avz_guest_memory_bytes(f.ram) + DATA + 4096);
        while (!__atomic_load_n(signal, __ATOMIC_ACQUIRE) && !atomic_load(&w.done)) sched_yield();
        CHECK(!atomic_load(&w.done));
        if (!kind) {
            CHECK(avz_native_fast_memory_write(f.path[1], CODE, 4, 0xd503201f));
        } else {
            AVZNativeTLBI tlbi = {.kind = kind - 1, .broadcast = 1, .virtual_address = DATA};
            avz_native_memory_fast_path_apply_tlbi(f.path[1], tlbi);
            avz_guest_memory_publish_tlbi(f.ram, tlbi);
        }
        CHECK(!pthread_join(thread, NULL));
        CHECK(w.result.status == AVZ_TP_STATUS_REVALIDATE && w.result.steps < UINT64_C(1000000000));
        CHECK(w.result.steps >= (register_tail ? 1u : 2u));
        finish(&f);
    }
}

static void concurrent_shootdowns(void) {
    concurrent_shootdown_case(0);
    concurrent_shootdown_case(1);
    puts("PASS parallel two-vCPU code publication and all four shared TLBI scopes, including register-only tails");
}

typedef struct { uint64_t limit, calls, last_total; } Checkpoint;
static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Checkpoint *c = opaque;
    (void)blocks; (void)pc; (void)pstate; (void)remaining;
    CHECK(steps <= c->limit && total - c->last_total == steps);
    c->last_total = total; c->calls++;
    return c->limit;
}

static void chain_deadlines(void) {
    uint32_t words[] = {0xf9400140, 0x91000400, 0xf9000140, 0x17fffffd};
    for (unsigned deadline = 1; deadline < 13; deadline++) {
        Fixture f; init(&f, words, 4); warm(&f, DATA, 8, 0);
        AVZNativeExecutionContext *ctx = avz_native_execution_context_create();
        CHECK(ctx);
        ctx->cpu = cpu();
        avz_native_execution_context_set_threaded_prototype(ctx, 1);
        avz_native_execution_context_set_threaded_memory(ctx, 1);
        AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 1,
            .cntp_ctl_el0 = 1, .cntp_cval_el0 = deadline};
        avz_native_memory_fast_path_set_architectural_state(f.path[0], &state);
        AVZNativeBlockKey key = {.current_el = 1};
        Checkpoint cp = {.limit = deadline};
        AVZNativeChainResult r = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
            ctx, f.cache[0], &key, deadline, 100, 100, 100,
            checkpoint, &cp, avz_native_fast_fetch_instruction, f.path[0],
            avz_native_fast_memory_read, avz_native_fast_memory_write,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f.path[0]);
        CHECK(r.steps == deadline && r.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(cp.calls == 1 && cp.last_total == deadline);
        AVZNativeThreadedPrototypeStatistics stats = avz_native_execution_context_threaded_statistics(ctx);
#if AVZ_TEST_ASSEMBLY
        /* Eligible assembly blocks can become established C superblocks.
         * Retirement and the exact timer boundary are checked above. */
        CHECK(stats.steps > 0 && stats.steps <= deadline && stats.memory_boundaries == 0);
        if (stats.steps < deadline) CHECK(r.superblock_dispatches > 0);
#else
        CHECK(stats.steps == deadline && stats.memory_boundaries == 0);
#endif
        avz_native_execution_context_destroy(ctx); finish(&f);
    }
    puts("PASS exact native timer/checkpoint budgets at all 12 instruction boundaries");
}

static void entry_precedence(void) {
    const uint32_t words[] = {0x91000400, 0x17ffffff};
    const uint64_t pcs[] = {CODE, CODE + 1, CODE + 8, CODE - 4};
    unsigned cases = 0;
    for (unsigned stale = 0; stale < 2; stale++) {
        Fixture f; init(&f, words, 2);
        const AVZThreadedPrototype *p = cached(&f, CODE);
        uint64_t local = avz_native_block_cache_code_mutation_epoch(f.cache[0]);
        uint64_t shared = avz_native_block_cache_shared_code_mutation_epoch(f.cache[0]);
        if (stale) avz_native_block_cache_invalidate_translation_mappings(f.cache[0]);
        for (unsigned halted = 0; halted < 2; halted++)
        for (unsigned budget = 0; budget < 2; budget++)
        for (unsigned i = 0; i < sizeof(pcs) / sizeof(pcs[0]); i++) {
            AVZNativeCPU c = cpu(); c.pc = pcs[i]; c.halted = halted;
            AVZNativeCPU expected = c;
            uint32_t status = !budget ? AVZ_NATIVE_STATUS_MAX_STEPS :
                halted ? AVZ_NATIVE_STATUS_HALTED :
                stale ? AVZ_TP_STATUS_REVALIDATE :
                i ? AVZ_NATIVE_STATUS_OUTSIDE_BLOCK : AVZ_NATIVE_STATUS_MAX_STEPS;
            uint64_t steps = budget && !halted && !stale && i == 0;
            if (steps) { expected.x[0]++; expected.pc += 4; }
            AVZNativeBlockResult r = avz_tp_run_guarded(p, budget, &c,
                f.path[0], f.cache[0], local, shared);
            CHECK(r.status == status && r.steps == steps && r.generic_dispatches == steps);
            CHECK(memcmp(&c, &expected, sizeof(c)) == 0 && !f.calls && !f.faults);
            cases++;
        }
        AVZNativeCPU c = cpu(), before = c;
        CHECK(avz_tp_run(NULL, 0, &c).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
        CHECK(avz_tp_run(p, 0, NULL).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
        CHECK(memcmp(&c, &before, sizeof(c)) == 0);
        finish(&f);
    }
    printf("PASS %u entry precedence/state cases, including stale epochs and misaligned PC\n", cases);
}

typedef struct {
    Fixture *fixture;
    uint64_t allowance, interval, maximum, calls, last_total, stop_after, origin;
    unsigned clear_cache;
} BoundaryCheckpoint;

static uint64_t boundary_checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    BoundaryCheckpoint *c = opaque;
    CHECK(steps > 0 && steps <= c->allowance && blocks > 0 && blocks <= c->interval);
    CHECK(total - c->last_total == steps && remaining == c->maximum - total);
    CHECK(pc == CODE + ((c->origin + total) % 2) * 4 && pstate == 5);
    c->last_total = total;
    c->calls++;
    if (c->clear_cache) avz_native_block_cache_clear(c->fixture->cache[0]);
    if (c->calls == c->stop_after) return 0;
    /* Change the budget on every checkpoint; the next entry must use it. */
    c->allowance = c->calls & 1 ? 1 : 65;
    return c->allowance;
}

static AVZNativeChainResult boundary_run(AVZNativeExecutionContext *ctx,
    BoundaryCheckpoint *cp) {
    AVZNativeBlockKey key = {.current_el = 1};
    Fixture *f = cp->fixture;
    return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        ctx, f->cache[0], &key, cp->allowance, cp->maximum, cp->maximum,
        cp->interval, boundary_checkpoint, cp,
        avz_native_fast_fetch_instruction, f->path[0],
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f->path[0]);
}

static void checkpoint_stop_and_resume(void) {
    const uint32_t words[] = {0x91000400, 0x17ffffff};
    const uint64_t budgets[] = {1, 2, 3, 15, 16, 17, 63, 64, 65, 255, 256, 257, 4095, 4096, 4097};
    const uint64_t intervals[] = {1, 3, 4096};
    unsigned cases = 0;
    for (unsigned clear = 0; clear < 2; clear++)
    for (unsigned b = 0; b < sizeof(budgets) / sizeof(budgets[0]); b++)
    for (unsigned i = 0; i < sizeof(intervals) / sizeof(intervals[0]); i++) {
        Fixture f; init(&f, words, 2);
        AVZNativeExecutionContext *ctx = avz_native_execution_context_create();
        CHECK(ctx); ctx->cpu = cpu();
        AVZNativeCPU expected = ctx->cpu;
        avz_native_execution_context_set_threaded_prototype(ctx, 1);
        BoundaryCheckpoint cp = {.fixture = &f, .allowance = budgets[b],
            .interval = intervals[i], .maximum = 10000, .stop_after = 3, .clear_cache = clear};
        AVZNativeChainResult r = boundary_run(ctx, &cp);
        CHECK(cp.calls == 3 && r.steps == cp.last_total && r.steps < cp.maximum);
        expected.x[0] = (r.steps + 1) / 2; expected.pc = CODE + (r.steps % 2) * 4;
        CHECK(memcmp(&ctx->cpu, &expected, sizeof(expected)) == 0);
        uint64_t prefix = r.steps;
        cp = (BoundaryCheckpoint){.fixture = &f, .allowance = 3, .interval = intervals[i],
            .maximum = 17, .origin = prefix, .clear_cache = clear};
        r = boundary_run(ctx, &cp);
        CHECK(r.steps == 17 && cp.last_total == 17 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        expected.x[0] = (prefix + 18) / 2; expected.pc = CODE + ((prefix + 17) % 2) * 4;
        CHECK(memcmp(&ctx->cpu, &expected, sizeof(expected)) == 0);
        /* A budget can stop at the branch. Its one-instruction cache entry is
         * ineligible for the prototype, so established C handles that entry. */
        uint64_t threaded_steps = avz_native_execution_context_threaded_statistics(ctx).steps;
        CHECK(threaded_steps > 0 && threaded_steps <= prefix + 17);
        CHECK(!f.calls && !f.faults);
        avz_native_execution_context_destroy(ctx); finish(&f); cases++;
    }
    printf("PASS %u changing-budget/block-bound, checkpoint stop/resume and cache-clear cases\n", cases);
}

static void translation_journal_overflow(void) {
    const uint32_t words[] = {0xf9400140, 0x17ffffff};
    const unsigned counts[] = {63, 64, 65, 129};
    for (unsigned i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
        Fixture f; init(&f, words, 2);
        warm(&f, DATA, 8, 11); warm(&f, DATA + 4096, 8, 22);
        const AVZThreadedPrototype *p = cached(&f, CODE);
        f.remapped = 1;
        avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
        for (unsigned n = 1; n < counts[i]; n++) {
            avz_guest_memory_publish_tlbi(f.ram,
                (AVZNativeTLBI){.kind = AVZ_TLBI_VA_ALL_ASIDS, .broadcast = 1, .virtual_address = 0x30000});
        }
        AVZNativeCPU c = cpu(), before = c;
        AVZNativeBlockResult r = avz_tp_run_with_memory(p, 2, &c, f.path[0]);
        CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 0);
        CHECK(memcmp(&c, &before, sizeof(c)) == 0);
        avz_native_memory_fast_path_synchronize_translations(f.path[0]);
        uint64_t value = 0;
        CHECK(avz_native_fast_memory_read(f.path[0], DATA, 8, &value) && value == 22);
        p = cached(&f, CODE);
        r = avz_tp_run_with_memory(p, 1, &c, f.path[0]);
        CHECK(r.steps == 1 && c.x[0] == 22 && c.pc == CODE + 4);
        finish(&f);
    }
    puts("PASS TLBI journal catch-up/overflow at 63, 64, 65 and 129 publications");
}

#if AVZ_TEST_ASSEMBLY
static void assembly_negative_cache_does_not_evict_hot_program(void) {
    const uint32_t words[] = {0x91000400, 0x17ffffff};
    Fixture f; init(&f, words, 2);
    const AGProgram *hot = cached(&f, CODE);
    /* Keep the object readable even if the cache incorrectly retires it. */
    ((AGProgram *)hot)->active_runs++;
    for (unsigned i = 0; i < 600; i++) {
        uint64_t pc = 0x10000 + i * 16;
        const uint32_t unsupported[] = {0x9b007c02, 0x14000001}; // MUL stays native C.
        memcpy(avz_guest_memory_bytes(f.ram) + pc, unsupported, sizeof(unsupported));
        AVZNativeBlockKey key = {.pc = pc, .current_el = 1};
        uint32_t status, raw;
        const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
            f.cache[0], &key, avz_native_fast_fetch_instruction, f.path[0], &status, &raw);
        CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
        CHECK(!avz_assembly_cache_program(f.cache[0], block, 1));
        CHECK(!avz_assembly_cache_program(f.cache[0], block, 1));
    }
    CHECK(!hot->retired && cached(&f, CODE) == hot);
    ((AGProgram *)hot)->active_runs--;
    finish(&f);
    puts("PASS 600 negative eligibility entries preserve the hot assembly snapshot");
}
static void assembly_preserves_native_plt_acceleration(void) {
    const uint32_t words[] = {0x90000010, 0xf9408211, 0x91040210, 0xd61f0220};
    Fixture f; init(&f, words, 4);
    warm(&f, CODE + 0x100, 8, CODE + 0x200);
    AGProgram *supported = ag_create(words, 4, CODE);
    CHECK(ag_program_capabilities(supported) == 2);
    ag_destroy(supported);
    AVZNativeExecutionContext *ctx = avz_native_execution_context_create();
    CHECK(ctx); ctx->cpu = cpu();
    avz_native_execution_context_set_assembly_executor(ctx, 1);
    AVZNativeBlockKey key = {.current_el = 1};
    Checkpoint cp = {.limit = 4};
    AVZNativeChainResult r = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        ctx, f.cache[0], &key, 4, 4, 4, 4, checkpoint, &cp,
        avz_native_fast_fetch_instruction, f.path[0],
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f.path[0]);
    CHECK(r.steps == 4 && r.fast_path_hits == 1 && r.fast_path_steps == 4);
    CHECK(ctx->cpu.pc == CODE + 0x200 && ctx->cpu.x[16] == CODE + 0x100);
    CHECK(avz_native_execution_context_assembly_statistics(ctx).steps == 0);
    avz_native_execution_context_destroy(ctx); finish(&f);
    puts("PASS assembly selection preserves the native C ELF PLT accelerator");
}
#endif

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    hot_differential();
    callbacks();
    code_writes_and_entry_races();
    remap_and_pending_tlbi();
    observations_and_faults();
    concurrent_shootdowns();
    chain_deadlines();
    entry_precedence();
    checkpoint_stop_and_resume();
    translation_journal_overflow();
#if AVZ_TEST_ASSEMBLY
    assembly_negative_cache_does_not_evict_hot_program();
    assembly_preserves_native_plt_acceleration();
#endif
    return 0;
}
