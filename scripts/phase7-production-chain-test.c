/* Production dispatcher contracts. No offline graph, Swift VM, or timing loop. */
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include "../Sources/ARM64VizNative/ARM64VizGuestMemoryInternal.h"

static int test_advance_time(AVZNativeMemoryFastPath *, uint64_t, uint64_t);
/* Interpose only the production dispatcher's service calls, not GuestMemory. */
#define avz_native_memory_fast_path_advance_time test_advance_time
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#undef avz_native_memory_fast_path_advance_time
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "production chain line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x1000, NEXT = 0x2000, RAM_SIZE = 0x6000,
    ALIAS = 0x10000, DEVICE = 0x100000 };
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned arrivals, published, kind;
    uint64_t code_epoch;
} Rendezvous;
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *memory;
    AVZNativeExecutionContext *context;
    Rendezvous *rendezvous;
    AVZNativeChainResult result;
    uint64_t charged, service_calls, positive_calls;
    uint64_t checkpoints, checkpoint_steps, checkpoint_blocks, allowance;
    uint64_t device_calls, old_serial, new_serial;
    uint64_t service_deltas[64], writes[2], access_calls;
    unsigned owns_ram, stop, rewrite_checkpoint, clear_service, stale_initial;
    unsigned fail_device, irq_device, clear_device, owner, rendezvoused, benchmark, remap_next;
    unsigned helper_rendezvous, fail_at, deny_access;
    unsigned entry_rendezvous, audit_helper_time;
    uint64_t expected_helper_ticks;
} Fixture;
static _Thread_local Fixture *current;
static unsigned bounded_mode;
static void rendezvous(Fixture *f);
#if defined(AG_PRODUCTION_TEST_HOOKS) && AG_PRODUCTION_TEST_HOOKS
static unsigned fail_service_allocation, rejected_allocations;
void *test_service_malloc(size_t size) {
    if (fail_service_allocation) { rejected_allocations++; return NULL; }
    return malloc(size);
}
#endif

static uint32_t branch(uint64_t from, uint64_t to) {
    return 0x14000000u | ((uint32_t)(((int64_t)to - (int64_t)from) / 4) & 0x3ffffffu);
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque;
    (void)write;
    if (address >= ALIAS && address < ALIAS + 0x1000)
        address = NEXT + address - ALIAS;
    if (f->remap_next && address >= NEXT && address < NEXT + 0x1000)
        address += 0x2000;
    if (!width || address > RAM_SIZE - width) return 0;
    *physical = address;
    return 1;
}
static const AVZNativeDecodedBlock *decode(Fixture *f, uint64_t pc) {
    AVZNativeBlockKey key = {.pc = pc, .current_el = 1};
    uint32_t status = 0, unsupported = 0;
    const AVZNativeDecodedBlock *b = avz_native_block_cache_get_or_decode(
        f->cache, &key, avz_native_fast_fetch_instruction, f->memory, &status, &unsupported);
    CHECK(b && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    return b;
}
static void train(Fixture *f, uint64_t barrier_pc) {
    const AVZNativeDecodedBlock *a = decode(f, BASE), *b = decode(f, NEXT);
    const AVZNativeDecodedBlock *barrier = decode(f, barrier_pc);
    CHECK(avz_assembly_cache_program(f->cache, a, 1));
    CHECK(avz_assembly_cache_program(f->cache, b, 1));
    uint64_t serial = avz_native_decoded_block_serial(f->cache, a);
    avz_native_decoded_block_record_successor(f->cache, a, serial, b,
        avz_native_decoded_block_serial(f->cache, b));
    avz_native_decoded_block_record_successor(f->cache, a, serial, barrier,
        avz_native_decoded_block_serial(f->cache, barrier));
}
static void publish_word(Fixture *f, uint64_t address, uint32_t word) {
    avz_guest_memory_lock_range(f->ram, address, 4);
    memcpy(avz_guest_memory_bytes(f->ram) + address, &word, 4);
    avz_guest_memory_note_write(f->ram, address, 4);
    avz_guest_memory_unlock_range(f->ram, address, 4);
}
static int device_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    CHECK((address == DEVICE || address == DEVICE + 8) && width == 8);
    f->device_calls++;
    if (f->audit_helper_time)
        CHECK(f->memory->architectural_state.counter_ticks == f->expected_helper_ticks);
    if (f->helper_rendezvous && !f->rendezvoused) {
        CHECK(avz_assembly_cache_service_chain_info(f->cache).active == 1);
        f->rendezvoused = 1;
        rendezvous(f);
    }
    if (f->irq_device) f->memory->architectural_state.pending_irq = 1;
    if (f->clear_device) avz_native_block_cache_clear(f->cache);
    *value = 73;
    return !f->fail_device && f->device_calls != f->fail_at;
}
static int device_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    uint64_t ignored;
    int ok = device_read(opaque, address, width, &ignored);
    if (ok) f->writes[(address - DEVICE) / 8] = value;
    return ok;
}
static int device_access(void *opaque, uint64_t address, uint8_t width, uint8_t write) {
    Fixture *f = opaque;
    (void)write;
    f->access_calls++;
    return !f->deny_access && width == 8 && (address == DEVICE || address == DEVICE + 8);
}
static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Fixture *f = opaque;
    (void)pc; (void)pstate; (void)remaining;
    if (f->benchmark) return f->allowance;
    f->checkpoints++;
    f->checkpoint_steps += steps;
    f->checkpoint_blocks += blocks;
    CHECK(total == f->checkpoint_steps);
    if (f->rewrite_checkpoint) {
        f->rewrite_checkpoint = 0;
        avz_native_block_cache_clear(f->cache);
        publish_word(f, NEXT, 0x91000821); /* add x1, x1, #2 */
    }
    return f->stop ? 0 : f->allowance;
}
static void rendezvous(Fixture *f) {
    Rendezvous *r = f->rendezvous;
    CHECK(!pthread_mutex_lock(&r->mutex));
    r->arrivals++;
    CHECK(!pthread_cond_broadcast(&r->condition));
    while (r->arrivals != 2) CHECK(!pthread_cond_wait(&r->condition, &r->mutex));
    if (f->owner == 0) {
        if (r->kind == 0) {
            /* Guest write through an alias, using only this owner's fast path. */
            CHECK(avz_native_fast_memory_write(f->memory, ALIAS, 4, 0x91000821));
        } else if (r->kind == 1) {
            publish_word(f, NEXT, 0x91000821); /* device-style publication */
        } else if (r->kind == 7) {
            /* Split publication: model the released per-page generation while
             * the publishing owner has not yet advanced the global epoch. */
            r->code_epoch = avz_guest_memory_code_mutation_epoch(f->ram);
            atomic_fetch_add_explicit(&f->ram->page_write_generations[NEXT >> AVZ_FAST_PAGE_SHIFT],
                1, memory_order_release);
        } else {
            unsigned count = r->kind == 6 ? 65 : 1;
            for (unsigned i = 0; i < count; i++) {
                AVZNativeTLBI tlbi = {.kind = r->kind == 6 ? 0 : r->kind - 2,
                    .broadcast = 1, .virtual_address = NEXT, .asid = 7};
                avz_guest_memory_publish_tlbi(f->ram, tlbi);
            }
        }
        r->published = 1;
        CHECK(!pthread_cond_broadcast(&r->condition));
    }
    while (!r->published) CHECK(!pthread_cond_wait(&r->condition, &r->mutex));
    CHECK(!pthread_mutex_unlock(&r->mutex));
}
#if defined(AG_PRODUCTION_TEST_HOOKS) && AG_PRODUCTION_TEST_HOOKS
/* Only service_chain.o calls this wrapper, after its last C validation.
 * Benchmark/profile builds use the unmodified ag_enter symbol. */
void test_service_enter(AGRun *run) {
    Fixture *f = current;
    if (f && f->entry_rendezvous && !f->rendezvoused) {
        CHECK(avz_assembly_cache_service_chain_info(f->cache).active == 1);
        f->rendezvoused = 1;
        rendezvous(f);
    }
    ag_enter(run);
}
#endif
static int test_advance_time(AVZNativeMemoryFastPath *memory, uint64_t steps, uint64_t pstate) {
    Fixture *f = current;
    if (f && f->benchmark)
        return avz_native_memory_fast_path_advance_time(memory, steps, pstate);
    CHECK(f && f->memory == memory);
    if (bounded_mode && memory->counter_clock.frequency && steps) {
        CHECK(memory->counter_refresh_instructions < 1024);
        CHECK(steps <= 1024 - memory->counter_refresh_instructions);
    }
    f->charged += steps;
    f->service_calls++;
    if (steps) {
        if (f->positive_calls < 64) f->service_deltas[f->positive_calls] = steps;
        f->positive_calls++;
    }
    if (f->stale_initial && !steps) {
        f->stale_initial = 0;
        publish_word(f, BASE, 0x91000800);
    }
    if (steps && f->clear_service) {
        f->clear_service = 0;
        CHECK(avz_assembly_cache_service_chain_info(f->cache).active == 1);
        const AVZNativeDecodedBlock *b = decode(f, NEXT);
        f->old_serial = avz_native_decoded_block_serial(f->cache, b);
        avz_native_block_cache_clear(f->cache);
        CHECK(avz_assembly_cache_service_chain_info(f->cache).active == 1);
        CHECK(avz_assembly_cache_service_chain_info(f->cache).bytes > 0);
        publish_word(f, NEXT, 0x91000821);
        b = decode(f, NEXT);
        f->new_serial = avz_native_decoded_block_serial(f->cache, b);
        CHECK(f->old_serial != f->new_serial);
        CHECK(avz_assembly_cache_service_chain_info(f->cache).active == 1);
    }
    if (steps && f->rendezvous && !f->helper_rendezvous && !f->rendezvoused) {
        AVZAssemblyChainInfo info = avz_assembly_cache_service_chain_info(f->cache);
        CHECK(info.active == 1 && info.members == 2);
        f->rendezvoused = 1;
        rendezvous(f);
    }
    return avz_native_memory_fast_path_advance_time(memory, steps, pstate);
}
static void init(Fixture *f, AVZGuestMemory *shared) {
    memset(f, 0, sizeof(*f));
    f->ram = shared ? shared : avz_guest_memory_create(RAM_SIZE);
    f->owns_ram = shared == NULL;
    f->cache = avz_native_block_cache_create();
    f->context = avz_native_execution_context_create();
    CHECK(f->ram && f->cache && f->context);
    uint8_t *bytes = avz_guest_memory_bytes(f->ram);
    if (!shared) {
        const uint32_t first[] = {0x91000400,
            0x54000000u | (((NEXT - BASE - 4) / 4) << 5), 0xd503207f};
        const uint32_t second[] = {0x91000421, branch(NEXT + 4, BASE)};
        memcpy(bytes + BASE, first, sizeof(first));
        memcpy(bytes + NEXT, second, sizeof(second));
    }
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache, bytes, 0, RAM_SIZE));
    f->memory = avz_native_memory_fast_path_create(bytes, 0, RAM_SIZE, f->cache,
        f, translate, device_read, device_write, device_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->memory && avz_native_memory_fast_path_set_guest_memory(f->memory, f->ram));
    avz_native_memory_fast_path_set_instruction_translator(f->memory, translate);
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->memory, 0);
    f->memory->architectural_state.timer_cycles_per_instruction = 1;
    f->context->cpu = (AVZNativeCPU){.pc = BASE, .pstate = UINT64_C(0x40000005)};
    f->context->cpu.x[10] = DEVICE;
    f->allowance = 64;
    CHECK(!avz_native_execution_context_assembly_chain_statistics(f->context).enabled);
    CHECK(!avz_native_execution_context_assembly_chain_statistics(f->context).bounded_enabled);
    avz_native_execution_context_set_assembly_executor(f->context, 1);
    avz_native_execution_context_set_assembly_chaining(f->context, 1);
    avz_native_execution_context_set_assembly_bounded(f->context, bounded_mode);
    /* A previously taken conditional edge, then a newer not-taken WAIT edge.
     * C composition declines its most recent barrier; graph admission can use
     * the older eligible edge without overriding a valid C superblock. */
    train(f, BASE + 8);
}
static void finish(Fixture *f) {
    avz_native_execution_context_destroy(f->context);
    avz_native_memory_fast_path_destroy(f->memory);
    avz_native_block_cache_destroy(f->cache);
    if (f->owns_ram) avz_guest_memory_destroy(f->ram);
    current = NULL;
}
static AVZNativeChainResult production(Fixture *f, uint64_t allowance, uint64_t steps,
    uint64_t blocks, uint64_t interval) {
    AVZNativeBlockKey key = {.current_el = 1};
    return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        f->context, f->cache, &key, allowance, steps, blocks, interval, checkpoint, f,
        avz_native_fast_fetch_instruction, f->memory,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f->memory);
}
static AVZNativeChainResult run(Fixture *f, uint64_t allowance, uint64_t steps,
    uint64_t blocks, uint64_t interval) {
    current = f;
    f->charged = f->service_calls = f->positive_calls = 0;
    f->checkpoints = f->checkpoint_steps = f->checkpoint_blocks = 0;
    AVZNativeChainResult result = production(f, allowance, steps, blocks, interval);
    CHECK(f->charged == result.steps);
    CHECK(f->checkpoint_steps == result.steps && f->checkpoint_blocks == result.blocks);
    AVZAssemblyChainDiagnostics diagnostics = avz_assembly_cache_service_chain_diagnostics(f->cache);
    CHECK(diagnostics.bytes <= 32768 && diagnostics.peak_bytes <= 32768);
    CHECK(!avz_assembly_cache_service_chain_info(f->cache).active);
    AVZNativeAssemblyChainStatistics stats = avz_native_execution_context_assembly_chain_statistics(f->context);
    CHECK(stats.bounded_runs <= stats.runs && stats.bounded_steps <= stats.steps &&
        stats.bounded_visits <= stats.visits);
    if (!bounded_mode) CHECK(!stats.bounded_runs && !stats.bounded_steps && !stats.bounded_visits);
    return result;
}
static void budgets(void) {
    const struct { uint64_t allowance, steps, blocks, interval, retired, visits; } cases[] = {
        {64, 1, 64, 64, 1, 1}, {64, 3, 64, 64, 3, 2},
        {64, 9, 64, 64, 9, 5}, {64, 64, 3, 64, 6, 3},
        {3, 64, 64, 64, 3, 2}, {64, 64, 64, 1, 2, 1},
        {UINT64_MAX, UINT64_MAX, 1, UINT64_MAX, 2, 1}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        Fixture f; init(&f, NULL); f.stop = 1;
        AVZNativeChainResult r = run(&f, cases[i].allowance, cases[i].steps,
            cases[i].blocks, cases[i].interval);
        CHECK(r.steps == cases[i].retired && r.blocks == cases[i].visits);
        AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
        if (!s.enabled || s.runs != 1 || s.steps != r.steps || s.visits != r.blocks)
            fprintf(stderr, "budget case %zu: result=%llu/%llu chain=%llu/%llu/%llu enabled=%llu\n",
                i, (unsigned long long)r.steps, (unsigned long long)r.blocks,
                (unsigned long long)s.runs, (unsigned long long)s.visits,
                (unsigned long long)s.steps, (unsigned long long)s.enabled);
        CHECK(s.enabled && s.runs == 1 && s.steps == r.steps && s.visits == r.blocks);
        CHECK(f.positive_calls == (bounded_mode ? 1 : r.blocks));
        if (bounded_mode) CHECK(s.bounded_enabled && s.bounded_runs == 1 &&
            s.bounded_steps == r.steps && s.bounded_visits == r.blocks);
        CHECK(f.memory->architectural_state.counter_ticks == r.steps);
        CHECK(f.context->cpu.x[0] == (r.steps + 3) / 4);
        CHECK(f.context->cpu.x[1] == (r.steps + 1) / 4);
        finish(&f);
    }
    Fixture f; init(&f, NULL); f.allowance = 4;
    AVZNativeChainResult r = run(&f, 4, 12, 64, 2);
    CHECK(r.steps == 12 && r.blocks == 6 && f.checkpoints == 3);
    CHECK(r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    finish(&f);
    init(&f, NULL); f.stop = 1;
    r = run(&f, 3, 64, 64, 64);
    CHECK(r.steps == 3 && f.context->cpu.pc == NEXT + 4);
    f.stop = 0;
    r = run(&f, 3, 3, 64, 64);
    CHECK(r.steps == 3 && !f.context->cpu.halted && f.context->cpu.pc == NEXT);
    finish(&f);
    init(&f, NULL);
    avz_native_block_cache_clear(f.cache);
    uint32_t back = branch(BASE + 4, BASE);
    memcpy(avz_guest_memory_bytes(f.ram) + BASE + 4, &back, 4);
    const AVZNativeDecodedBlock *self = decode(&f, BASE);
    uint64_t serial = avz_native_decoded_block_serial(f.cache, self);
    avz_native_decoded_block_record_successor(f.cache, self, serial, self, serial);
    r = run(&f, 11, 11, 64, 64);
    AVZNativeAssemblyChainStatistics stats = avz_native_execution_context_assembly_chain_statistics(f.context);
    CHECK(r.steps == 11 && r.blocks == 6 && f.positive_calls == (bounded_mode ? 1 : 6));
    CHECK(stats.runs == 1 && stats.visits == 6 && stats.steps == 11);
    CHECK(f.context->cpu.x[0] == 6 && f.context->cpu.pc == BASE + 4);
    finish(&f);
    puts("PASS production exact limits, partial visits, checkpoint continuation and fresh resume");
}
static void timers(void) {
    for (unsigned kind = 0; kind < 9; kind++) {
        Fixture f; init(&f, NULL);
        AVZNativeArchitecturalState *s = &f.memory->architectural_state;
        s->timer_cycles_per_instruction = 2;
        if (kind == 0) s->pending_irq = 1;
        if (kind == 1 || kind == 3 || kind == 5 || kind == 7) {
            s->cntp_ctl_el0 = 1; s->cntp_cval_el0 = kind == 1 ? 0 : 1;
        }
        if (kind == 2 || kind == 4) {
            s->cntv_ctl_el0 = 1; s->cntv_cval_el0 = kind == 2 ? 0 : 3;
        }
        if (kind == 5) s->cntp_ctl_el0 = 3;
        if (kind == 6) { s->pending_irq = 1; f.context->cpu.pstate |= 0x80; }
        if (kind == 7) s->timer_cycles_per_instruction = 0;
        if (kind == 8) {
            s->cntp_ctl_el0 = s->cntv_ctl_el0 = 1;
            s->cntp_cval_el0 = UINT64_MAX; s->cntv_cval_el0 = 3;
        }
        AVZNativeChainResult r = run(&f, 8, 8, 64, 64);
        uint64_t expected = kind < 3 ? 0 : kind == 3 ? 1 : kind == 4 || kind == 8 ? 2 : 8;
        if (r.steps != expected) fprintf(stderr, "timer case %u: retired %llu, expected %llu\n",
            kind, (unsigned long long)r.steps, (unsigned long long)expected);
        CHECK(r.steps == expected);
        CHECK(r.blocks == (expected + 1) / 2);
        CHECK((r.status == AVZ_NATIVE_STATUS_YIELDED) == (kind < 5 || kind == 8));
        CHECK(s->counter_ticks == expected * s->timer_cycles_per_instruction);
        CHECK(avz_native_execution_context_assembly_chain_statistics(f.context).runs > 0);
        finish(&f);
    }
    Fixture f; init(&f, NULL);
    AVZNativeCounterClock clock;
    CHECK(avz_native_counter_clock_initialize(&clock, 100, 1000000));
    avz_native_memory_fast_path_set_counter_clock(f.memory, &clock);
    f.memory->counter_refresh_instructions = 1023;
    AVZNativeChainResult r = run(&f, 6, 6, 64, 64);
    CHECK(r.steps == 6 && f.memory->counter_refresh_instructions == (bounded_mode ? 5 : 4));
    CHECK(f.memory->architectural_state.counter_ticks >= 100);
    finish(&f);
    puts("PASS production initial IRQ, both timer deadlines, masking, zero cycles and host refresh boundary");
}
static void invalidation(void) {
    Fixture f; init(&f, NULL); f.stop = 1; f.stale_initial = 1;
    AVZNativeChainResult r = run(&f, 8, 8, 64, 64);
    CHECK(r.steps == 0 && r.blocks == 0 && f.context->cpu.x[0] == 0);
    CHECK(f.context->cpu.pc == BASE);
    r = run(&f, 1, 1, 64, 64);
    CHECK(r.steps == 1 && f.context->cpu.x[0] == 2);
    finish(&f);
    init(&f, NULL); f.stop = 1; f.clear_service = 1;
    r = run(&f, 8, 8, 64, 64);
    CHECK(r.steps == 2 && r.blocks == 1 && f.context->cpu.x[1] == 0);
    CHECK(f.old_serial && f.new_serial && f.old_serial != f.new_serial);
    r = run(&f, 1, 1, 64, 64);
    CHECK(r.steps == 1 && f.context->cpu.x[1] == 2);
    finish(&f);
    init(&f, NULL); f.rewrite_checkpoint = 1; f.allowance = 2;
    r = run(&f, 2, 4, 64, 1);
    CHECK(r.steps == 4 && r.blocks == 2 && f.context->cpu.x[1] == 2);
    finish(&f);
    puts("PASS entry stale proof, pinned cache clear/serial replacement, checkpoint mutation/reselection");
}
static void entry_translation(void) {
    Fixture f; init(&f, NULL); f.stop = 1;
    AVZNativeChainResult r = run(&f, 2, 2, 64, 64);
    CHECK(r.steps == 2 && f.context->cpu.pc == NEXT);
    uint32_t replacement[] = {0x91000c21, branch(NEXT + 4, BASE)};
    memcpy(avz_guest_memory_bytes(f.ram) + 0x4000, replacement, sizeof(replacement));
    f.remap_next = 1;
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
    r = run(&f, 1, 1, 64, 64);
    if (r.steps != 1 || f.context->cpu.x[1] != 3)
        fprintf(stderr, "entry TLBI: steps=%llu x1=%llu (expected 1/3) pc=%llx\n",
            (unsigned long long)r.steps, (unsigned long long)f.context->cpu.x[1],
            (unsigned long long)f.context->cpu.pc);
    CHECK(r.steps == 1 && f.context->cpu.x[1] == 3);
    CHECK(f.memory->observed_shared_translation_epoch == avz_guest_memory_translation_epoch(f.ram));
    finish(&f);
    puts("PASS already-published entry TLBI remaps before any retired instruction");
}
static void helpers(void) {
    for (unsigned fail = 0; fail < 2; fail++) {
        Fixture f; init(&f, NULL);
        avz_native_block_cache_clear(f.cache);
        const uint32_t words[] = {0x91000400, 0xf9400142,
            0x54000000u | (((NEXT - BASE - 8) / 4) << 5), 0xd503207f};
        memcpy(avz_guest_memory_bytes(f.ram) + BASE, words, sizeof(words));
        train(&f, BASE + 12);
        f.fail_device = fail; f.irq_device = f.clear_device = f.stop = 1;
        f.audit_helper_time = bounded_mode; f.expected_helper_ticks = 1;
        AVZNativeChainResult r = run(&f, 2, 8, 64, 64);
        CHECK(f.device_calls == 1 && r.blocks == 1 && r.steps == (fail ? 1 : 2));
        CHECK(r.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_NATIVE_STATUS_YIELDED));
        CHECK(f.context->cpu.pc == BASE + (fail ? 4 : 8));
        CHECK(f.context->cpu.x[2] == (fail ? 0 : 73) && !f.context->cpu.x[1]);
        CHECK(avz_native_execution_context_assembly_chain_statistics(f.context).runs == 1);
        if (bounded_mode) {
            AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
            CHECK(s.bounded_runs == 1 && s.bounded_steps == r.steps && s.bounded_visits == 1);
        }
        finish(&f);
    }
    Fixture f; init(&f, NULL);
    avz_native_block_cache_clear(f.cache);
    uint32_t load = 0xf9400142;
    memcpy(avz_guest_memory_bytes(f.ram) + BASE, &load, 4);
    train(&f, BASE + 8);
    f.fail_device = f.irq_device = f.clear_device = f.stop = 1;
    f.audit_helper_time = bounded_mode; f.expected_helper_ticks = 0;
    AVZNativeChainResult r = run(&f, 2, 8, 64, 64);
    CHECK(r.steps == 0 && r.blocks == 1 && f.checkpoint_blocks == 1);
    CHECK(r.status == AVZ_TP_STATUS_MEMORY_FAULT && f.device_calls == 1);
    CHECK(f.context->cpu.pc == BASE && !f.context->cpu.x[2]);
    AVZNativeAssemblyChainStatistics stats = avz_native_execution_context_assembly_chain_statistics(f.context);
    CHECK(stats.runs == 1 && stats.visits == 1 && stats.steps == 0);
    if (bounded_mode) CHECK(stats.bounded_runs == 1 && stats.bounded_visits == 1 && !stats.bounded_steps);
    finish(&f);
    puts("PASS successful final-budget helper and fault prefix: IRQ precedence, cache retirement, no replay");
}
static void selection(void) {
    for (unsigned mode = 0; mode < 3; mode++) {
        Fixture f; init(&f, NULL);
        if (mode == 0) avz_native_execution_context_set_assembly_chaining(f.context, 0);
        if (mode == 1) avz_native_execution_context_set_assembly_executor(f.context, 0);
        if (mode == 2) {
            const AVZNativeDecodedBlock *a = decode(&f, BASE), *b = decode(&f, NEXT);
            uint64_t as = avz_native_decoded_block_serial(f.cache, a);
            uint64_t bs = avz_native_decoded_block_serial(f.cache, b);
            avz_native_decoded_block_record_successor(f.cache, a, as, b, bs);
            avz_native_decoded_block_record_successor(f.cache, b, bs, a, as);
        }
        AVZNativeChainResult r = run(&f, 4, 4, 64, 64);
        CHECK(r.steps == 4);
        AVZNativeAssemblyChainStatistics stats = avz_native_execution_context_assembly_chain_statistics(f.context);
        CHECK(mode == 2 ? stats.runs > 0 && stats.steps == 4 : stats.runs == 0);
        if (bounded_mode) CHECK(mode == 2 ? stats.bounded_runs > 0 && stats.bounded_steps == 4 :
            !stats.bounded_runs && !stats.bounded_steps && !stats.bounded_visits);
        if (mode == 0) CHECK(avz_native_execution_context_assembly_statistics(f.context).steps > 0);
        if (mode == 1) CHECK(!avz_native_execution_context_assembly_statistics(f.context).steps);
        if (mode == 2) {
            CHECK(!r.superblock_dispatches);
            r = run(&f, 4, 4, 64, 64);
            AVZNativeAssemblyChainStatistics after = avz_native_execution_context_assembly_chain_statistics(f.context);
            CHECK(r.steps == 4 && r.superblock_hits > 0 && !r.superblock_dispatches);
            CHECK(after.runs > stats.runs && after.steps - stats.steps == 4);
        }
        finish(&f);
    }
    Fixture f; init(&f, NULL);
    avz_native_block_cache_clear(f.cache);
    const uint32_t plt[] = {0x90000010, 0xf9408211, 0x91040210, 0xd61f0220};
    enum { PLT = 0x3000 };
    uint64_t target = PLT + 0x200;
    uint32_t to_plt = branch(NEXT + 4, PLT);
    memcpy(avz_guest_memory_bytes(f.ram) + NEXT + 4, &to_plt, 4);
    memcpy(avz_guest_memory_bytes(f.ram) + PLT, plt, sizeof(plt));
    memcpy(avz_guest_memory_bytes(f.ram) + PLT + 0x100, &target, sizeof(target));
    train(&f, BASE + 8);
    const AVZNativeDecodedBlock *b = decode(&f, NEXT), *p = decode(&f, PLT);
    avz_native_decoded_block_record_successor(f.cache, b,
        avz_native_decoded_block_serial(f.cache, b), p, avz_native_decoded_block_serial(f.cache, p));
    uint64_t value;
    CHECK(avz_native_fast_memory_read(f.memory, PLT + 0x100, 8, &value));
    AVZNativeChainResult r = run(&f, 8, 8, 64, 64);
    CHECK(r.steps == 8 && r.fast_path_hits == 1 && r.fast_path_steps == 4);
    CHECK(f.context->cpu.pc == target);
    CHECK(avz_native_execution_context_assembly_chain_statistics(f.context).steps == 4);
    finish(&f);
    puts("PASS independent opt-outs, ordinary-superblock opt-in takeover and assembly-to-C semantic successor");
}
static void semantic_superblock(void) {
    Fixture f; init(&f, NULL);
    avz_native_execution_context_set_assembly_chaining(f.context, 0);
    avz_native_block_cache_clear(f.cache);
    const uint32_t plt[] = {0x90000010, 0xf9408211, 0x91040210, 0xd61f0220};
    uint64_t target = BASE, value;
    memcpy(avz_guest_memory_bytes(f.ram) + NEXT, plt, sizeof(plt));
    memcpy(avz_guest_memory_bytes(f.ram) + NEXT + 0x100, &target, sizeof(target));
    const AVZNativeDecodedBlock *a = decode(&f, BASE), *b = decode(&f, NEXT);
    uint64_t as = avz_native_decoded_block_serial(f.cache, a);
    uint64_t bs = avz_native_decoded_block_serial(f.cache, b);
    avz_native_decoded_block_record_successor(f.cache, a, as, b, bs);
    avz_native_decoded_block_record_successor(f.cache, b, bs, a, as);
    CHECK(avz_native_fast_memory_read(f.memory, NEXT + 0x100, 8, &value));
    AVZNativeChainResult r = run(&f, 6, 6, 64, 64);
    CHECK(r.steps == 6 && r.superblock_dispatches && r.fast_path_steps == 4 && r.fast_path_hits == 1);
    CHECK(f.context->cpu.pc == BASE);
    avz_native_execution_context_set_assembly_chaining(f.context, 1);
    r = run(&f, 12, 12, 64, 64);
    CHECK(r.steps == 12 && r.superblock_hits && r.superblock_dispatches);
    CHECK(r.fast_path_steps == 8 && r.fast_path_hits == 2);
    CHECK(f.context->cpu.pc == BASE && f.context->cpu.x[0] == 3);
    CHECK(!avz_native_execution_context_assembly_chain_statistics(f.context).runs);
    CHECK(!avz_native_execution_context_assembly_chain_statistics(f.context).bounded_runs);
    CHECK(!avz_native_execution_context_assembly_statistics(f.context).steps);
    finish(&f);
    puts("PASS warmed mixed semantic C superblock preserves PLT work and has zero chain theft");
}
static void legacy_apis(void) {
    for (unsigned checkpointed = 0; checkpointed < 2; checkpointed++) {
        Fixture f; init(&f, NULL); current = &f;
        AVZNativeBlockKey key = {.current_el = 1};
        AVZNativeChainResult r;
        if (checkpointed) {
            r = avz_native_execution_context_run_cached_chain_checkpointed(
                f.context, f.cache, &key, 4, 4, 64, 64, checkpoint, &f,
                avz_native_fast_fetch_instruction, f.memory,
                avz_native_fast_memory_read, avz_native_fast_memory_write,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f.memory);
        } else {
            r = avz_native_execution_context_run_cached_chain(f.context, f.cache, &key, 4, 64,
                avz_native_fast_fetch_instruction, f.memory,
                avz_native_fast_memory_read, avz_native_fast_memory_write,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f.memory);
        }
        uint64_t expected = checkpointed ? 4 : 2;
        if (r.steps != expected || avz_native_execution_context_assembly_chain_statistics(f.context).runs)
            fprintf(stderr, "legacy checkpointed=%u steps=%llu status=%u chain_runs=%llu pc=%llx\n",
                checkpointed, (unsigned long long)r.steps, r.status,
                (unsigned long long)avz_native_execution_context_assembly_chain_statistics(f.context).runs,
                (unsigned long long)f.context->cpu.pc);
        CHECK(r.steps == expected && !avz_native_execution_context_assembly_chain_statistics(f.context).runs);
        CHECK(!avz_native_execution_context_assembly_chain_statistics(f.context).bounded_runs);
        CHECK(avz_native_execution_context_assembly_statistics(f.context).steps > 0);
        finish(&f);
    }
    puts("PASS generic checkpoint and non-checkpoint APIs retain independently selected short assembly");
}
static void *owner_run(void *opaque) {
    Fixture *f = opaque;
    f->result = run(f, 8, 8, 64, 64);
    return NULL;
}
static void two_owners(void) {
    for (unsigned kind = 0; kind <= 6; kind++) {
        Fixture f[2]; init(&f[0], NULL); init(&f[1], f[0].ram);
        Rendezvous r = {.mutex = PTHREAD_MUTEX_INITIALIZER,
            .condition = PTHREAD_COND_INITIALIZER, .kind = kind};
        pthread_t threads[2];
        for (unsigned i = 0; i < 2; i++) {
            f[i].owner = i; f[i].rendezvous = &r; f[i].stop = 1;
            CHECK(!pthread_create(&threads[i], NULL, owner_run, &f[i]));
        }
        for (unsigned i = 0; i < 2; i++) CHECK(!pthread_join(threads[i], NULL));
        CHECK(r.published && r.arrivals == 2);
        for (unsigned i = 0; i < 2; i++) {
            CHECK(f[i].result.steps == 2 && f[i].result.blocks == 1);
            CHECK(f[i].context->cpu.pc == NEXT && f[i].context->cpu.x[1] == 0);
            CHECK(avz_native_execution_context_assembly_chain_statistics(f[i].context).runs == 1);
            CHECK(f[i].memory->observed_shared_translation_epoch ==
                avz_guest_memory_translation_epoch(f[i].ram));
            f[i].rendezvous = NULL;
            AVZNativeChainResult resumed = run(&f[i], 1, 1, 64, 64);
            CHECK(resumed.steps == 1 && f[i].context->cpu.x[1] == (kind < 2 ? 2 : 1));
        }
        finish(&f[1]); finish(&f[0]);
        CHECK(!pthread_cond_destroy(&r.condition));
        CHECK(!pthread_mutex_destroy(&r.mutex));
    }
    puts("PASS two production owners: aliased guest/device writes, four TLBI scopes and 65-publication overflow");
}
static void bounded_budgets(void) {
    bounded_mode = 1;
    budgets();
    Fixture f; init(&f, NULL);
    AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
    AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
    CHECK(r.steps == 64 && r.blocks == 32 && f.checkpoints == 1);
    CHECK(s.bounded_runs == 1 && s.bounded_steps == 64 && s.bounded_visits == 32);
    CHECK(f.positive_calls == 1 && f.service_deltas[0] == 64);
    finish(&f);
    bounded_mode = 0;
    puts("PASS bounded budgets: one accumulated service charge across 32 visits");
}
static void bounded_timers(void) {
    bounded_mode = 1;
    timers();
    for (unsigned timer = 0; timer < 2; timer++) {
        for (uint64_t cycles = 1; cycles <= 7; cycles += 3) {
            for (uint64_t distance = 0; distance <= 33; distance++) {
                Fixture f; init(&f, NULL);
                AVZNativeArchitecturalState *s = &f.memory->architectural_state;
                s->counter_ticks = 11; s->timer_cycles_per_instruction = cycles;
                if (timer) { s->cntv_ctl_el0 = 1; s->cntv_cval_el0 = 11 + distance; }
                else { s->cntp_ctl_el0 = 1; s->cntp_cval_el0 = 11 + distance; }
                uint64_t expected = (distance + cycles - 1) / cycles;
                AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
                CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED && r.steps == expected);
                CHECK(r.blocks == (expected + 1) / 2);
                CHECK(s->counter_ticks == 11 + expected * cycles);
                CHECK(f.context->cpu.x[0] == (expected + 3) / 4);
                CHECK(f.context->cpu.x[1] == (expected + 1) / 4);
                const uint64_t pcs[] = {BASE, BASE + 4, NEXT, NEXT + 4};
                CHECK(f.context->cpu.pc == pcs[expected % 4]);
                AVZNativeAssemblyChainStatistics stats = avz_native_execution_context_assembly_chain_statistics(f.context);
                CHECK(stats.bounded_runs && stats.bounded_steps == expected && stats.bounded_visits == r.blocks);
                finish(&f);
            }
        }
    }
    for (unsigned mask = 0; mask < 2; mask++) {
        Fixture f; init(&f, NULL);
        f.memory->architectural_state.cntv_ctl_el0 = mask ? 1 : 3;
        f.memory->architectural_state.cntv_cval_el0 = 1;
        if (mask) f.context->cpu.pstate |= 0x80;
        AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
        CHECK(r.steps == 64 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(f.positive_calls == 1);
        finish(&f);
    }
    const unsigned refresh[] = {0, 1, 511, 1023};
    for (size_t i = 0; i < sizeof(refresh) / sizeof(refresh[0]); i++) {
        Fixture f; init(&f, NULL); f.allowance = 4096;
        AVZNativeCounterClock clock;
        CHECK(avz_native_counter_clock_initialize(&clock, 100, 1000000));
        avz_native_memory_fast_path_set_counter_clock(f.memory, &clock);
        f.memory->counter_refresh_instructions = refresh[i];
        AVZNativeChainResult r = run(&f, 4096, 2053, 4096, 4096);
        CHECK(r.steps == 2053 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        /* Odd windows may finish an interior suffix in ordinary dispatch.
         * Every charge is still checked against the remaining window above. */
        CHECK(f.positive_calls < r.blocks);
        CHECK(f.service_deltas[0] == 1024 - refresh[i]);
        if (!refresh[i]) CHECK(f.positive_calls == 3 && f.service_deltas[1] == 1024);
        CHECK(f.memory->counter_refresh_instructions == (2053 + refresh[i]) % 1024);
        AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
        CHECK(s.bounded_runs && s.bounded_steps >= 1024 && s.bounded_steps <= 2053);
        CHECK(s.bounded_visits > 0 && s.bounded_visits <= r.blocks);
        finish(&f);
    }
    bounded_mode = 0;
    puts("PASS bounded exact physical/virtual deadlines, IRQ masks and remaining host-refresh windows");
}
static void bounded_helpers(void) {
    bounded_mode = 1;
    helpers();
    for (unsigned load = 0; load < 2; load++) {
        for (unsigned failure = 0; failure < 4; failure++) {
            Fixture f; init(&f, NULL);
            avz_native_block_cache_clear(f.cache);
            const uint32_t words[] = {0x91000400,
                load ? 0xa8c10540 : 0xa8810540, /* LDP/STP x0,x1,[x10],#16 */
                0x54000000u | (((NEXT - BASE - 8) / 4) << 5), 0xd503207f};
            memcpy(avz_guest_memory_bytes(f.ram) + BASE, words, sizeof(words));
            train(&f, BASE + 12);
            f.context->cpu.x[0] = 8; f.context->cpu.x[1] = 17;
            f.fail_at = failure < 3 ? failure : 0;
            f.deny_access = failure == 3;
            f.irq_device = f.clear_device = f.stop = 1;
            f.audit_helper_time = 1; f.expected_helper_ticks = 1;
            AVZNativeChainResult r = run(&f, 2, 8, 64, 64);
            CHECK(r.steps == (failure ? 1 : 2) && r.blocks == 1);
            CHECK(r.status == (failure ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_NATIVE_STATUS_YIELDED));
            CHECK(f.context->cpu.pc == BASE + (failure ? 4 : 8));
            CHECK(f.context->cpu.x[10] == DEVICE + (failure ? 0 : 16));
            CHECK(f.device_calls == (failure == 3 ? 0 : failure == 1 ? 1 : 2));
            CHECK(f.access_calls == (failure == 3 ? 1 : 2));
            CHECK(f.context->cpu.x[0] == (load && !failure ? 73 : 9));
            CHECK(f.context->cpu.x[1] == (load && !failure ? 73 : 17));
            CHECK(f.writes[0] == (!load && (failure == 0 || failure == 2) ? 9 : 0));
            CHECK(f.writes[1] == (!load && !failure ? 17 : 0));
            AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
            CHECK(s.bounded_runs == 1 && s.bounded_steps == r.steps && s.bounded_visits == 1);
            CHECK(f.positive_calls == (failure ? 1 : 2) && f.service_deltas[0] == 1);
            if (!failure) CHECK(f.service_deltas[1] == 1);
            finish(&f);
        }
    }
    bounded_mode = 0;
    puts("PASS bounded helpers: exactly-once callbacks, partial pair stores, atomic load registers and suppressed fault writeback");
}
static void bounded_helper_timers(void) {
    bounded_mode = 1;
    for (unsigned timer = 0; timer < 2; timer++) {
        for (unsigned deadline = 2; deadline <= 4; deadline++) {
            Fixture f; init(&f, NULL);
            avz_native_block_cache_clear(f.cache);
            const uint32_t words[] = {0x91000400, 0xf9400142,
                0x54000000u | (((0x100 - 8) / 4) << 5),
                0xd503207f};
            memcpy(avz_guest_memory_bytes(f.ram) + NEXT, words, sizeof(words));
            train(&f, BASE + 8);
            f.stop = f.audit_helper_time = 1; f.expected_helper_ticks = 3;
            if (timer) {
                f.memory->architectural_state.cntv_ctl_el0 = 1;
                f.memory->architectural_state.cntv_cval_el0 = deadline;
            } else {
                f.memory->architectural_state.cntp_ctl_el0 = 1;
                f.memory->architectural_state.cntp_cval_el0 = deadline;
            }
            AVZNativeChainResult r = run(&f, 8, 8, 64, 64);
            CHECK(r.steps == deadline && r.blocks == (deadline == 2 ? 1 : 2));
            CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED);
            CHECK(f.device_calls == (deadline == 4 ? 1 : 0));
            CHECK(f.context->cpu.x[2] == (deadline == 4 ? 73 : 0));
            CHECK(f.context->cpu.pc == NEXT + (deadline - 2) * 4);
            CHECK(f.memory->architectural_state.counter_ticks == deadline);
            AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
            CHECK(s.bounded_runs == 1 && s.bounded_steps == deadline && s.bounded_visits == r.blocks);
            if (deadline == 4) CHECK(f.positive_calls == 2 && f.service_deltas[0] == 3 && f.service_deltas[1] == 1);
            finish(&f);
        }
    }
    bounded_mode = 0;
    puts("PASS bounded helper settlement: prior visits charged before callback, exact pre/post-helper timer deadlines");
}
static void bounded_invalidation(void) {
    bounded_mode = 1;
    Fixture f; init(&f, NULL); f.stop = f.stale_initial = 1;
    AVZNativeChainResult r = run(&f, 8, 8, 64, 64);
    CHECK(!r.steps && !r.blocks && !f.context->cpu.x[0] && f.context->cpu.pc == BASE);
    CHECK(avz_native_execution_context_assembly_chain_statistics(f.context).bounded_runs == 1);
    r = run(&f, 1, 1, 64, 64);
    CHECK(r.steps == 1 && f.context->cpu.x[0] == 2);
    finish(&f);
    init(&f, NULL); f.rewrite_checkpoint = 1; f.allowance = 2;
    r = run(&f, 2, 4, 64, 1);
    CHECK(r.steps == 4 && r.blocks == 2 && f.context->cpu.x[1] == 2);
    CHECK(avz_native_execution_context_assembly_chain_statistics(f.context).bounded_steps > 0);
    finish(&f);
    entry_translation();
    bounded_mode = 0;
    puts("PASS bounded stale entry, checkpoint rewrite and already-published TLBI remapping");
}
static void bounded_two_owners(void) {
    bounded_mode = 1;
    for (unsigned kind = 0; kind <= 6; kind++) {
        Fixture f[2]; init(&f[0], NULL);
        avz_native_block_cache_clear(f[0].cache);
        const uint32_t words[] = {0x91000400, 0xf9400142,
            0x54000000u | (((NEXT - BASE - 8) / 4) << 5), 0xd503207f};
        memcpy(avz_guest_memory_bytes(f[0].ram) + BASE, words, sizeof(words));
        train(&f[0], BASE + 12);
        init(&f[1], f[0].ram);
        avz_native_block_cache_clear(f[1].cache);
        train(&f[1], BASE + 12);
        Rendezvous r = {.mutex = PTHREAD_MUTEX_INITIALIZER,
            .condition = PTHREAD_COND_INITIALIZER, .kind = kind};
        pthread_t threads[2];
        for (unsigned i = 0; i < 2; i++) {
            f[i].owner = i; f[i].rendezvous = &r;
            f[i].stop = f[i].helper_rendezvous = 1;
            CHECK(!pthread_create(&threads[i], NULL, owner_run, &f[i]));
        }
        for (unsigned i = 0; i < 2; i++) CHECK(!pthread_join(threads[i], NULL));
        CHECK(r.published && r.arrivals == 2);
        for (unsigned i = 0; i < 2; i++) {
            CHECK(f[i].rendezvoused && f[i].device_calls == 1);
            CHECK(f[i].result.steps == 2 && f[i].result.blocks == 1);
            CHECK(f[i].context->cpu.pc == BASE + 8 && !f[i].context->cpu.x[1]);
            AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f[i].context);
            CHECK(s.bounded_runs == 1 && s.bounded_steps == 2 && s.bounded_visits == 1);
            CHECK(f[i].memory->observed_shared_translation_epoch == avz_guest_memory_translation_epoch(f[i].ram));
            f[i].rendezvous = NULL; f[i].helper_rendezvous = 0;
            AVZNativeChainResult resumed = run(&f[i], 2, 2, 64, 64);
            CHECK(resumed.steps == 2 && f[i].context->cpu.x[1] == (kind < 2 ? 2 : 1));
            CHECK(f[i].device_calls == 1);
        }
        finish(&f[1]); finish(&f[0]);
        CHECK(!pthread_cond_destroy(&r.condition));
        CHECK(!pthread_mutex_destroy(&r.mutex));
    }
    bounded_mode = 0;
    puts("PASS bounded two-owner helper publication: alias/device code, four TLBI scopes, overflow, no replay");
}
static void bounded_selection(void) {
    bounded_mode = 1;
    selection();
    semantic_superblock();
    legacy_apis();
    bounded_mode = 0;
    puts("PASS bounded opt-outs, semantic ownership and legacy API isolation");
}
static void bounded_allocation_failure(void) {
#if defined(AG_PRODUCTION_TEST_HOOKS) && AG_PRODUCTION_TEST_HOOKS
    bounded_mode = 1;
    Fixture f; init(&f, NULL);
    fail_service_allocation = 1;
    AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
    fail_service_allocation = 0;
    CHECK(rejected_allocations && r.steps == 64 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(f.context->cpu.x[0] == 16 && f.context->cpu.x[1] == 16);
    CHECK(f.memory->architectural_state.counter_ticks == 64);
    AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f.context);
    CHECK(!s.runs && !s.bounded_runs && !s.bounded_steps);
    size_t before = avz_assembly_cache_service_chain_info(f.cache).bytes;
    r = run(&f, 64, 64, 64, 64);
    s = avz_native_execution_context_assembly_chain_statistics(f.context);
    CHECK(r.steps == 64 && s.bounded_steps == 64);
    CHECK(avz_assembly_cache_service_chain_info(f.cache).bytes > before);
    CHECK(f.context->cpu.x[0] == 32 && f.context->cpu.x[1] == 32);
    finish(&f);
    Fixture retired; init(&retired, NULL);
    avz_native_execution_context_set_assembly_bounded(retired.context, 0);
    (void)run(&retired, 4, 4, 64, 64);
    before = avz_assembly_cache_service_chain_info(retired.cache).bytes;
    CHECK(before);
    avz_native_execution_context_set_assembly_bounded(retired.context, 1);
    retired.clear_service = retired.stop = 1;
    (void)run(&retired, 4, 4, 64, 64);
    CHECK(avz_assembly_cache_service_chain_diagnostics(retired.cache).peak_bytes > before);
    finish(&retired); bounded_mode = 0;
    puts("PASS optional allocation failure makes native progress without false bounded counts; retry updates byte accounting");
#else
    CHECK(!"allocation failure requires correctness-build allocation hook");
#endif
}
static void bounded_page_publication(void) {
#if defined(AG_PRODUCTION_TEST_HOOKS) && AG_PRODUCTION_TEST_HOOKS
    bounded_mode = 1;
    Fixture f[2]; init(&f[0], NULL); init(&f[1], f[0].ram);
    Rendezvous r = {.mutex = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER, .kind = 7};
    pthread_t threads[2];
    for (unsigned i = 0; i < 2; i++) {
        f[i].owner = i; f[i].rendezvous = &r;
        f[i].stop = f[i].entry_rendezvous = 1;
        CHECK(!pthread_create(&threads[i], NULL, owner_run, &f[i]));
    }
    for (unsigned i = 0; i < 2; i++) CHECK(!pthread_join(threads[i], NULL));
    CHECK(r.published && r.arrivals == 2);
    CHECK(avz_guest_memory_code_mutation_epoch(f[0].ram) == r.code_epoch);
    for (unsigned i = 0; i < 2; i++) {
        CHECK(f[i].rendezvoused && !f[i].result.steps && !f[i].result.blocks);
        CHECK(!f[i].context->cpu.x[0] && !f[i].context->cpu.x[1] && f[i].context->cpu.pc == BASE);
        AVZNativeAssemblyChainStatistics s = avz_native_execution_context_assembly_chain_statistics(f[i].context);
        CHECK(s.bounded_runs == 1 && !s.bounded_steps && !s.bounded_visits);
    }
    finish(&f[1]); finish(&f[0]);
    CHECK(!pthread_cond_destroy(&r.condition));
    CHECK(!pthread_mutex_destroy(&r.mutex));
    bounded_mode = 0;
    puts("PASS bounded assembly entry rejects non-current member page publication before global code epoch");
#else
    CHECK(!"page publication requires correctness-build entry hook");
#endif
}
static uint64_t thread_nanoseconds(void) {
    struct timespec ts;
    CHECK(!clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts));
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}
static void benchmark(void) {
    enum { ROUNDS = 6, SLICES = 128, STEPS = 4096, WARMUP = 64 };
    puts("SYNTHETIC native cached-loop only; not VM/interaction or production speedup evidence");
#if defined(AG_BOUNDARY_PROFILE) && AG_BOUNDARY_PROFILE
    mach_timebase_info_data_t calibration_timebase;
    CHECK(mach_timebase_info(&calibration_timebase) == KERN_SUCCESS);
    uint64_t calibration_ticks = 0;
    for (unsigned i = 0; i < 10000; i++) {
        uint64_t begin = mach_absolute_time();
        calibration_ticks += mach_absolute_time() - begin;
    }
    printf("CLOCK_PAIR_NS,%.3f (reference only; no subtraction from raw samples)\n",
        (double)calibration_ticks * calibration_timebase.numer /
        calibration_timebase.denom / 10000);
    puts("PROFILED timings include instrumentation; never use these throughput numbers as a promotion gate");
#endif
    /* Keep the original CSV prefix. chain: 0 ordinary, 1 service, 2 bounded. */
    puts("block_length,round,chain,thread_ns,steps,blocks,chain_runs,chain_visits,chain_steps,c_superblock_dispatches,graph_builds,graph_reuses,graph_bytes,bounded_runs,bounded_visits,bounded_steps");
    for (unsigned length = 2; length <= 16; length *= 2) {
    for (unsigned round = 0; round < ROUNDS; round++) {
        for (unsigned order = 0; order < 3; order++) {
            unsigned enabled = (round + (round < 3 ? order : 2 - order)) % 3;
            Fixture f; init(&f, NULL); current = &f;
            avz_native_block_cache_clear(f.cache);
            for (unsigned i = 0; i < length; i++) {
                publish_word(&f, BASE + i * 4,
                    i + 1 == length
                        ? 0x54000000u | (((NEXT - BASE - i * 4) / 4) << 5)
                        : 0x91000400);
                publish_word(&f, NEXT + i * 4,
                    i + 1 == length ? branch(NEXT + i * 4, BASE) : 0x91000421);
            }
            publish_word(&f, BASE + length * 4, 0xd503207f); // non-taken WAIT edge
            const AVZNativeDecodedBlock *a = decode(&f, BASE), *b = decode(&f, NEXT);
            /* Graph admission requires retained positive programs for every
             * member; prewarm equally in all modes, outside timed work. */
            CHECK(avz_assembly_cache_program(f.cache, a, 1));
            CHECK(avz_assembly_cache_program(f.cache, b, 1));
            uint64_t a_serial = avz_native_decoded_block_serial(f.cache, a);
            uint64_t b_serial = avz_native_decoded_block_serial(f.cache, b);
            avz_native_decoded_block_record_successor(f.cache, a, a_serial, b, b_serial);
            avz_native_decoded_block_record_successor(f.cache, b, b_serial, a, a_serial);
            avz_native_execution_context_set_assembly_chaining(f.context, enabled != 0);
            avz_native_execution_context_set_assembly_bounded(f.context, enabled == 2);
            f.benchmark = 1; f.allowance = STEPS;
            AVZNativeChainResult warmup = production(&f, WARMUP, WARMUP, STEPS, STEPS);
            CHECK(warmup.steps == WARMUP);
            AVZNativeAssemblyChainStatistics before =
                avz_native_execution_context_assembly_chain_statistics(f.context);
            AVZAssemblyChainDiagnostics cache_before = avz_assembly_cache_service_chain_diagnostics(f.cache);
            AVZNativeChainResult results[SLICES];
#if defined(AG_BOUNDARY_PROFILE) && AG_BOUNDARY_PROFILE
            ag_boundary_profile = (AGBoundaryProfile){0};
#endif
            uint64_t start = thread_nanoseconds();
            for (unsigned i = 0; i < SLICES; i++)
                results[i] = production(&f, STEPS, STEPS, STEPS, STEPS);
            uint64_t elapsed = thread_nanoseconds() - start;
            uint64_t retired = 0, visits = 0, superblocks = 0;
            for (unsigned i = 0; i < SLICES; i++) {
                CHECK(results[i].steps == STEPS && results[i].status == AVZ_NATIVE_STATUS_MAX_STEPS);
                CHECK(results[i].blocks == STEPS / length);
                retired += results[i].steps; visits += results[i].blocks;
                superblocks += results[i].superblock_dispatches;
            }
            CHECK(f.context->cpu.pc == BASE && !f.context->cpu.halted);
            CHECK(f.context->cpu.x[0] == (WARMUP + retired) / (2 * length) * (length - 1));
            CHECK(f.context->cpu.x[1] == f.context->cpu.x[0]);
            CHECK(f.memory->architectural_state.counter_ticks == WARMUP + retired);
            AVZNativeAssemblyChainStatistics after =
                avz_native_execution_context_assembly_chain_statistics(f.context);
            AVZAssemblyChainDiagnostics cache_after = avz_assembly_cache_service_chain_diagnostics(f.cache);
            uint64_t runs = after.runs - before.runs;
            uint64_t chain_visits = after.visits - before.visits;
            uint64_t chain_steps = after.steps - before.steps;
            uint64_t bounded_runs = after.bounded_runs - before.bounded_runs;
            uint64_t bounded_visits = after.bounded_visits - before.bounded_visits;
            uint64_t bounded_steps = after.bounded_steps - before.bounded_steps;
            if (enabled && (!runs || chain_steps != retired || chain_visits != visits))
                fprintf(stderr, "density %u coverage: runs=%llu chain=%llu/%llu actual=%llu/%llu superblocks=%llu\n",
                    length, (unsigned long long)runs, (unsigned long long)chain_steps,
                    (unsigned long long)chain_visits, (unsigned long long)retired,
                    (unsigned long long)visits, (unsigned long long)superblocks);
            CHECK(enabled ? runs > 0 && chain_steps == retired && chain_visits == visits : runs == 0);
            CHECK(enabled == 2 ? bounded_runs > 0 && bounded_steps == retired && bounded_visits == visits :
                !bounded_runs && !bounded_steps && !bounded_visits);
            CHECK(cache_after.bytes <= 32768 && !avz_assembly_cache_service_chain_info(f.cache).active);
            printf("%u,%u,%u,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%zu,%llu,%llu,%llu\n", length, round, enabled,
                (unsigned long long)elapsed, (unsigned long long)retired,
                (unsigned long long)visits, (unsigned long long)runs,
                (unsigned long long)chain_visits, (unsigned long long)chain_steps,
                (unsigned long long)superblocks,
                (unsigned long long)(cache_after.builds - cache_before.builds),
                (unsigned long long)(cache_after.reuses - cache_before.reuses), cache_after.bytes,
                (unsigned long long)bounded_runs, (unsigned long long)bounded_visits,
                (unsigned long long)bounded_steps);
#if defined(AG_BOUNDARY_PROFILE) && AG_BOUNDARY_PROFILE
            if (enabled) {
                static const char *names[] = {"accounting", "tlbi-sync", "timer-irq",
                    "advance-time-return", "allowance",
                    "callback-return", "validation", "selection", "memory-prepare"};
                mach_timebase_info_data_t timebase;
                CHECK(mach_timebase_info(&timebase) == KERN_SUCCESS);
                printf("PROFILE,%u,%u,boundaries,%llu,samples,%llu,mode,%u\n", length, round,
                    (unsigned long long)ag_boundary_profile.boundaries,
                    (unsigned long long)ag_boundary_profile.samples, enabled);
                for (unsigned i = 0; i < AG_PROFILE_STAGE_COUNT; i++)
                    printf("STAGE,%u,%u,%s,%llu,%.3f,mode,%u\n", length, round, names[i],
                        (unsigned long long)ag_boundary_profile.counts[i],
                        (double)ag_boundary_profile.ticks[i] * timebase.numer / timebase.denom, enabled);
            }
#endif
            finish(&f);
        }
    }
    }
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    fputs("START production chain main\n", stderr);
    CHECK(ag_available());
    if (argc == 2 && !strcmp(argv[1], "--benchmark")) { benchmark(); return 0; }
    const struct { const char *name; void (*test)(void); } cases[] = {
        {"budgets", budgets}, {"invalidation", invalidation}, {"helpers", helpers},
        {"selection", selection}, {"semantic-superblock", semantic_superblock},
        {"legacy", legacy_apis}, {"two-owners", two_owners},
        {"timers", timers}, {"entry-translation", entry_translation},
        {"bounded-budgets", bounded_budgets}, {"bounded-timers", bounded_timers},
        {"bounded-helpers", bounded_helpers}, {"bounded-invalidation", bounded_invalidation},
        {"bounded-two-owners", bounded_two_owners}, {"bounded-selection", bounded_selection},
        {"bounded-helper-timers", bounded_helper_timers}, {"bounded-page-publication", bounded_page_publication},
        {"bounded-allocation-failure", bounded_allocation_failure}
    };
    CHECK(argc == 1 || (argc == 2 && !strncmp(argv[1], "--case=", 7)));
    unsigned executed = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (argc == 2 && strcmp(argv[1] + 7, cases[i].name)) continue;
        printf("RUN %s\n", cases[i].name);
        cases[i].test(); executed++;
    }
    CHECK(executed);
    puts("PASS production chaining contracts (native only; not performance or Swift VM evidence)");
    return 0;
}
