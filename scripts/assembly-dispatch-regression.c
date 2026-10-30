/* Standalone production dispatcher tests. No offline chain or Swift VM. */
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"
static const AGProgram *test_program_lookup(AVZNativeBlockCache *,
    const AVZNativeDecodedBlock *, int);
static AVZNativeBlockResult test_run_memory(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);
#define avz_assembly_cache_program test_program_lookup
#define ag_run_memory test_run_memory
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#undef ag_run_memory
#undef avz_assembly_cache_program

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "dispatch line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x1000, NEXT = 0x2000, RAM_SIZE = 0x4000, DEVICE = 0x100000 };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *memory;
    AVZNativeExecutionContext *context;
    AVZNativeAssemblyStatistics entry_statistics;
    const AGProgram *selected;
    uint64_t lookups, checkpoints, checkpoint_steps, checkpoint_blocks;
    uint64_t calls, observed_pins;
    unsigned publish_code, stop, clear, fail, rewrite;
} Fixture;
static Fixture *current;

static void *peer_write(void *opaque) {
    Fixture *f = opaque;
    uint32_t word = 0x91000800; /* add x0, x0, #2 */
    avz_guest_memory_lock_range(f->ram, BASE, 4);
    memcpy(avz_guest_memory_bytes(f->ram) + BASE, &word, 4);
    avz_guest_memory_note_write(f->ram, BASE, 4);
    avz_guest_memory_unlock_range(f->ram, BASE, 4);
    return NULL;
}
static const AGProgram *test_program_lookup(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, int memory) {
    Fixture *f = current;
    CHECK(f && f->cache == cache);
    f->lookups++;
    const AGProgram *p = avz_assembly_cache_program(cache, block, memory);
    f->selected = p;
    if (p && f->publish_code) {
        f->publish_code = 0;
        uint64_t epoch = avz_guest_memory_code_mutation_epoch(f->ram);
        pthread_t thread;
        CHECK(!pthread_create(&thread, NULL, peer_write, f));
        CHECK(!pthread_join(thread, NULL));
        CHECK(avz_guest_memory_code_mutation_epoch(f->ram) != epoch);
    }
    return p;
}
static uint32_t branch(uint64_t from, uint64_t to) {
    return 0x14000000u | ((uint32_t)(((int64_t)to - (int64_t)from) / 4) & 0x3ffffffu);
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    (void)opaque; (void)write;
    if (address > RAM_SIZE - width) return 0;
    *physical = address;
    return 1;
}
static int device_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    CHECK(address == DEVICE && width == 8);
    f->calls++;
    CHECK(f->selected && f->selected->active_runs == 1);
    f->observed_pins++;
    if (f->clear) {
        avz_native_block_cache_clear(f->cache);
        CHECK(f->selected->retired && f->selected->active_runs == 1);
    }
    *value = 73;
    return !f->fail;
}
static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Fixture *f = opaque;
    (void)total; (void)pc; (void)pstate; (void)remaining;
    f->checkpoints++;
    f->checkpoint_steps += steps;
    f->checkpoint_blocks += blocks;
    /* No per-block publication: the previous slice remains reader-visible. */
    AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f->context);
    CHECK(s.blocks == f->entry_statistics.blocks && s.steps == f->entry_statistics.steps);
    CHECK(s.boundaries == f->entry_statistics.boundaries && s.faults == f->entry_statistics.faults);
    CHECK(s.blocks <= f->context->assembly_owner_blocks);
    CHECK(s.steps <= f->context->assembly_owner_steps);
    if (f->rewrite) {
        f->rewrite = 0;
        avz_native_block_cache_clear(f->cache);
        uint32_t replacement = 0x91000821; /* add x1, x1, #2 */
        CHECK(avz_native_fast_memory_write(f->memory, NEXT, 4, replacement));
    }
    return f->stop ? 0 : 64;
}
static void init(Fixture *f, const uint32_t *words, size_t count) {
    memset(f, 0, sizeof(*f));
    f->ram = avz_guest_memory_create(RAM_SIZE);
    f->cache = avz_native_block_cache_create();
    f->context = avz_native_execution_context_create();
    CHECK(f->ram && f->cache && f->context);
    uint8_t *bytes = avz_guest_memory_bytes(f->ram);
    memcpy(bytes + BASE, words, count * 4);
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache, bytes, 0, RAM_SIZE));
    f->memory = avz_native_memory_fast_path_create(bytes, 0, RAM_SIZE, f->cache,
        f, translate, device_read, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->memory && avz_native_memory_fast_path_set_guest_memory(f->memory, f->ram));
    avz_native_memory_fast_path_set_instruction_translator(f->memory, translate);
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->memory, 0);
    f->context->cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5};
    f->context->cpu.x[10] = DEVICE;
    avz_native_execution_context_set_assembly_executor(f->context, 1);
    current = f;
}
static void finish(Fixture *f) {
    AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f->context);
    CHECK(s.blocks == f->context->assembly_owner_blocks && s.steps == f->context->assembly_owner_steps);
    CHECK(s.boundaries == f->context->assembly_owner_boundaries && s.faults == f->context->assembly_owner_faults);
    avz_native_execution_context_destroy(f->context);
    avz_native_memory_fast_path_destroy(f->memory);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->ram);
    current = NULL;
}
static AVZNativeChainResult run(Fixture *f, uint64_t allowance, uint64_t steps,
    uint64_t blocks, uint64_t interval) {
    AVZNativeBlockKey key = {.current_el = 1};
    f->checkpoint_steps = f->checkpoint_blocks = 0;
    f->entry_statistics = avz_native_execution_context_assembly_statistics(f->context);
    return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        f->context, f->cache, &key, allowance, steps, blocks, interval,
        checkpoint, f, avz_native_fast_fetch_instruction, f->memory,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f->memory);
}
static AVZNativeChainResult plain(Fixture *f, uint64_t steps, uint64_t blocks) {
    AVZNativeBlockKey key = {.current_el = 1};
    return avz_native_execution_context_run_cached_chain(f->context, f->cache, &key,
        steps, blocks, avz_native_fast_fetch_instruction, f->memory,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f->memory);
}
static void composition(void) {
    for (unsigned mixed = 0; mixed < 2; mixed++) {
        const uint32_t code[] = {0x91000400, branch(BASE + 4, NEXT)};
        const uint32_t tail[] = {mixed ? 0x9b007c02 : 0x91000421, branch(NEXT + 4, BASE)};
        Fixture f; init(&f, code, 2);
        memcpy(avz_guest_memory_bytes(f.ram) + NEXT, tail, sizeof(tail));
        AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
        CHECK(r.steps == 64 && r.superblock_dispatches > 0 && r.superblock_blocks > 0);
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f.context);
        CHECK(s.steps > 0 && s.steps < r.steps);
        /* No second lookup on execution, including eligible composition roots. */
        CHECK(f.lookups == s.blocks + mixed);
        CHECK(f.context->cpu.x[0] == 16);
        if (mixed) CHECK(f.context->cpu.x[2] == 256);
        else CHECK(f.context->cpu.x[1] == 16);
        finish(&f);
    }
    puts("PASS C superblock priority for assembly-only and mixed ADD/MUL loops");
}
static void selection_and_early_exits(void) {
    const uint32_t code[] = {0x91000400, branch(BASE + 4, NEXT)};
    for (unsigned checkpointed = 0; checkpointed < 2; checkpointed++) {
        Fixture f; init(&f, code, 2);
        AVZNativeChainResult r = checkpointed ? run(&f, 64, 2, 64, 64) : plain(&f, 2, 64);
        CHECK(r.steps == 2 && f.lookups == 1);
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f.context);
        CHECK(s.blocks == 1 && s.steps == 2 && !s.boundaries && !s.faults);
        /* Following decode failure and an invalid request cannot lose or repeat totals. */
        r = checkpointed ? run(&f, 64, 64, 64, 64) : plain(&f, 64, 64);
        CHECK(!r.steps);
        CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 2);
        r = checkpointed ? run(&f, 64, 0, 64, 64) : plain(&f, 0, 64);
        CHECK(!r.steps && avz_native_execution_context_assembly_statistics(f.context).blocks == 1);
        f.context->cpu.halted = 1;
        r = checkpointed ? run(&f, 64, 64, 64, 64) : plain(&f, 64, 64);
        CHECK(!r.steps && r.status == AVZ_NATIVE_STATUS_HALTED);
        finish(&f);
    }
    Fixture f; init(&f, code, 2);
    const uint32_t tail[] = {0x91000421, branch(NEXT + 4, BASE)};
    memcpy(avz_guest_memory_bytes(f.ram) + NEXT, tail, sizeof(tail));
    f.rewrite = 1;
    AVZNativeChainResult r = run(&f, 2, 4, 64, 1);
    CHECK(r.steps == 4 && f.context->cpu.x[1] == 2 && f.lookups == 2);
    CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 4);
    finish(&f);
    puts("PASS one lookup, checkpoint invalidation/reselection and early-exit totals in both APIs");
}
static void stale_proof_and_pc(void) {
    const uint32_t code[] = {0x91000400, branch(BASE + 4, NEXT)};
    for (unsigned checkpointed = 0; checkpointed < 2; checkpointed++) {
        Fixture f; init(&f, code, 2); f.publish_code = f.stop = 1;
        AVZNativeChainResult r = checkpointed ? run(&f, 64, 64, 64, 64) : plain(&f, 64, 64);
        CHECK(!r.steps && !f.context->cpu.x[0] && f.context->cpu.pc == BASE && f.lookups == 1);
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f.context);
        CHECK(s.blocks == 1 && s.steps == 0 && s.boundaries == 1);
        f.stop = 0;
        r = checkpointed ? run(&f, 2, 2, 1, 1) : plain(&f, 2, 1);
        CHECK(r.steps == 2 && f.context->cpu.x[0] == 2);
        finish(&f);
    }
    Fixture f; init(&f, code, 2);
    AVZNativeBlockKey key = {.pc = BASE, .current_el = 1};
    uint64_t local = avz_native_block_cache_code_mutation_epoch(f.cache);
    uint64_t shared = avz_native_block_cache_shared_code_mutation_epoch(f.cache);
    uint32_t status, raw;
    const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(f.cache,
        &key, avz_native_fast_fetch_instruction, f.memory, &status, &raw);
    CHECK(block);
    AVZNativePreparedAssembly prepared = avz_native_prepare_assembly_block(
        f.cache, block, 1, avz_native_block_cache_code_mutation_epoch_token(f.cache),
        avz_native_block_cache_shared_code_mutation_epoch_token(f.cache), local, shared);
    CHECK(prepared.program);
    f.context->cpu.pc = BASE + 4;
    AVZNativeBlockResult result = avz_native_run_assembly_block(f.context, &prepared, 2, f.memory);
    CHECK(!result.steps && result.status == AVZ_TP_STATUS_REVALIDATE);
    CHECK(!f.context->assembly_owner_blocks && f.context->cpu.pc == BASE + 4);
    finish(&f);
    puts("PASS deterministic peer SMC between preparation and pin, fresh retry and exact PC guard");
}
typedef AVZNativeBlockResult (*MemoryRunner)(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);
static MemoryRunner dispatch_runner = ag_run_memory;
static AVZNativeBlockResult test_run_memory(const AGProgram *program, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory) {
    return dispatch_runner(program, budget, cpu, guards, memory);
}
static void check_guard_run(MemoryRunner runner, const AGProgram *program,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory, int succeeds) {
    AVZNativeCPU cpu, expected;
    memset(&cpu, 0, sizeof(cpu));
    cpu.pc = BASE;
    cpu.pstate = 5;
    cpu.x[0] = 41;
    memcpy(&expected, &cpu, sizeof(expected));
    if (succeeds) {
        expected.x[0]++;
        expected.pc = NEXT;
    }
    AGGuards original;
    if (proof) memcpy(&original, proof, sizeof(original));
    AVZNativeBlockResult r = runner(program, 2, &cpu, proof, memory);
    CHECK(r.status == (succeeds ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_TP_STATUS_REVALIDATE));
    CHECK(r.steps == (succeeds ? 2u : 0u) && r.generic_dispatches == r.steps);
    CHECK(!r.unsupported_instruction && !memcmp(&cpu, &expected, sizeof(cpu)));
    CHECK(!proof || !memcmp(proof, &original, sizeof(original)));
    CHECK(!program->active_runs && !program->retired);
}
static void guard_coalescing(void) {
    const uint32_t code[] = {0x91000400, branch(BASE + 4, NEXT)};
    Fixture f; init(&f, code, 2);
    AGProgram *program = ag_create(code, 2, BASE);
    CHECK(program);
    const _Atomic uint64_t *token = (const _Atomic uint64_t *)
        avz_native_block_cache_shared_code_mutation_epoch_token(f.cache);
    CHECK(token == &f.ram->code_mutation_epoch);
    uint64_t epoch = atomic_load_explicit(token, memory_order_acquire);
    AGGuards base = {
        .local = avz_native_block_cache_code_mutation_epoch_token(f.cache),
        .shared = {token},
        .expected = {avz_native_block_cache_code_mutation_epoch(f.cache), epoch}
    };
    const MemoryRunner runners[] = {
        ag_run_memory, ag_run_memory_coalesced, ag_run_memory_uncoalesced, ag_run_memory_control
    };
    for (size_t i = 0; i < sizeof(runners) / sizeof(runners[0]); i++) {
        MemoryRunner runner = runners[i];
        AGGuards proof = base;
        check_guard_run(runner, program, &proof, f.memory, 1);
        proof.expected[1] = epoch - 1;
        check_guard_run(runner, program, &proof, f.memory, 0);

        /* Equal values at different addresses are not interchangeable proofs. */
        _Atomic uint64_t distinct;
        atomic_init(&distinct, epoch);
        proof = base;
        proof.shared[0] = &distinct;
        check_guard_run(runner, program, &proof, f.memory, 1);
        atomic_store_explicit(&distinct, epoch + 1, memory_order_release);
        check_guard_run(runner, program, &proof, f.memory, 0);

        proof = base;
        check_guard_run(runner, program, &proof, NULL, 1);
        proof.expected[1] = epoch - 1;
        check_guard_run(runner, program, &proof, NULL, 0);
        check_guard_run(runner, program, NULL, f.memory, 1);
        check_guard_run(runner, program, NULL, NULL, 1);

        proof = base;
        proof.expected[0]--;
        check_guard_run(runner, program, &proof, f.memory, 0);
        for (size_t slot = 1; slot <= 2; slot++) {
            proof = base;
            atomic_store_explicit(&distinct, epoch, memory_order_release);
            proof.shared[slot] = &distinct;
            proof.expected[slot + 1] = epoch;
            check_guard_run(runner, program, &proof, f.memory, 1);
            atomic_store_explicit(&distinct, epoch + 1, memory_order_release);
            check_guard_run(runner, program, &proof, f.memory, 0);
        }
    }
    ag_destroy(program);
    finish(&f);
    puts("PASS matching/stale/independent guards, null memory and unchanged proofs across four entries");
}
typedef struct {
    AVZGuestMemory *ram;
    uint64_t *signal;
    _Atomic unsigned owner_done;
    unsigned published;
} GuardPeer;
static void *publish_after_signal(void *opaque) {
    GuardPeer *peer = opaque;
    while (!__atomic_load_n(peer->signal, __ATOMIC_ACQUIRE)) {
        if (atomic_load_explicit(&peer->owner_done, memory_order_acquire)) return NULL;
        sched_yield();
    }
    /* Only shared RAM/publication APIs: never touch the owner's cache, memory
     * fast path, CPU or program (including its non-atomic pin count). */
    const uint32_t replacement = 0xd503201f; /* nop */
    avz_guest_memory_lock_range(peer->ram, BASE + 4, sizeof(replacement));
    memcpy(avz_guest_memory_bytes(peer->ram) + BASE + 4, &replacement, sizeof(replacement));
    avz_guest_memory_note_write(peer->ram, BASE + 4, sizeof(replacement));
    avz_guest_memory_unlock_range(peer->ram, BASE + 4, sizeof(replacement));
    peer->published = 1;
    return NULL;
}
static void concurrent_alias_guard(void) {
    const uint32_t code[] = {
        0xf9000160, /* str x0, [x11]: signal once, then only ADD/B */
        0x91000421, /* add x1, x1, #1 */
        0x17ffffff  /* b #-4 */
    };
    const MemoryRunner runners[] = {
        ag_run_memory, ag_run_memory_coalesced, ag_run_memory_uncoalesced
    };
    const uint64_t budget = UINT64_C(1000000000);
    AVZNativeBlockResult results[sizeof(runners) / sizeof(runners[0])];
    for (size_t i = 0; i < sizeof(runners) / sizeof(runners[0]); i++) {
        Fixture f; init(&f, code, 3);
        AVZNativeBlockKey key = {.pc = BASE, .current_el = 1};
        uint32_t status, raw;
        const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
            f.cache, &key, avz_native_fast_fetch_instruction, f.memory, &status, &raw);
        CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
        const AGProgram *program = avz_assembly_cache_program(f.cache, block, 1);
        CHECK(program && program->targets.count == 3 && ag_program_capabilities(program) == 2);
        uint64_t serial = avz_native_decoded_block_serial(f.cache, block);
        CHECK(serial);
        AGOperation operations[4];
        memcpy(operations, program->operations, sizeof(operations));

        /* NEXT is a separate, non-code page. Warm translation/dirty bookkeeping
         * and prove the signal store reaches the budget exit, not a C helper. */
        CHECK(avz_native_fast_memory_write(f.memory, NEXT, 8, 0));
        AGGuards proof = {
            .local = avz_native_block_cache_code_mutation_epoch_token(f.cache),
            .shared = {(const _Atomic uint64_t *)
                avz_native_block_cache_shared_code_mutation_epoch_token(f.cache)},
            .expected = {avz_native_block_cache_code_mutation_epoch(f.cache),
                avz_native_block_cache_shared_code_mutation_epoch(f.cache)}
        };
        AGMemory view;
        ag_memory_prepare_inline(&view, f.memory);
        CHECK(view.eligible && proof.shared[0] == &view.shared->code_mutation_epoch);
        CHECK(proof.expected[1] == view.code_epoch && !proof.shared[1] && !proof.shared[2]);
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        cpu.x[0] = 1;
        cpu.x[11] = NEXT;
        AVZNativeBlockResult warm = runners[i](program, 1, &cpu, &proof, f.memory);
        CHECK(warm.status == AVZ_NATIVE_STATUS_MAX_STEPS && warm.steps == 1);
        CHECK(cpu.pc == BASE + 4 && !cpu.x[1]);
        GuardPeer peer = {.ram = f.ram,
            .signal = (uint64_t *)(avz_guest_memory_bytes(f.ram) + NEXT)};
        atomic_init(&peer.owner_done, 0);
        CHECK(__atomic_load_n(peer.signal, __ATOMIC_ACQUIRE) == 1);
        __atomic_store_n(peer.signal, 0, __ATOMIC_RELEASE);
        cpu.pc = BASE;
        AGGuards original;
        memcpy(&original, &proof, sizeof(original));
        pthread_t thread;
        CHECK(!pthread_create(&thread, NULL, publish_after_signal, &peer));
        results[i] = runners[i](program, budget, &cpu, &proof, f.memory);
        atomic_store_explicit(&peer.owner_done, 1, memory_order_release);
        CHECK(!pthread_join(thread, NULL));

        CHECK(peer.published && results[i].status == AVZ_TP_STATUS_REVALIDATE);
        CHECK(results[i].steps >= 1 && results[i].steps < budget);
        CHECK(results[i].generic_dispatches == results[i].steps && !results[i].unsupported_instruction);
        CHECK(cpu.x[0] == 1 && cpu.x[11] == NEXT && cpu.pstate == 5);
        CHECK(cpu.x[1] == results[i].steps / 2);
        CHECK(cpu.pc == BASE + (results[i].steps % 2 ? 4 : 8));
        CHECK(avz_guest_memory_code_mutation_epoch(f.ram) != proof.expected[1]);
        CHECK(avz_native_block_cache_code_mutation_epoch(f.cache) == proof.expected[0]);
        CHECK(!memcmp(&proof, &original, sizeof(proof)));
        /* The runtime pin is released, but the cached immutable program is
         * intact; the peer only published invalidation, never reclaimed it. */
        CHECK(!program->active_runs && !program->retired && ag_program_capabilities(program) == 2);
        CHECK(!memcmp(program->operations, operations, sizeof(operations)));
        CHECK(avz_native_decoded_block_serial(f.cache, block) == serial && !f.calls);
        finish(&f);
    }
    /* Exact retirement counts depend on scheduling, not executor semantics. */
    for (size_t i = 1; i < sizeof(runners) / sizeof(runners[0]); i++)
        CHECK(results[0].status == results[i].status);
    puts("PASS concurrent tracked code publication after RAM signal with coalesced and uncoalesced alias proofs");
}
static void helpers_and_deadlines(void) {
    const uint32_t load[] = {0xf9400140, 0x91000421, 0x17fffffe};
    for (unsigned fail = 0; fail < 2; fail++) {
        Fixture f; init(&f, load, 3); f.stop = f.clear = 1; f.fail = fail;
        AVZNativeChainResult r = run(&f, 64, 64, 64, 64);
        CHECK(r.steps == (fail ? 0 : 1) && f.calls == 1 && f.observed_pins == 1);
        CHECK(!f.context->cpu.x[1] && f.context->cpu.pc == BASE + (fail ? 0 : 4));
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f.context);
        CHECK(s.blocks == 1 && s.steps == r.steps && s.faults == fail && s.boundaries == !fail);
        if (fail) CHECK(r.status == AVZ_TP_STATUS_MEMORY_FAULT);
        finish(&f);
    }
    const uint32_t loop[] = {0x91000400, 0x17ffffff};
    for (uint64_t deadline = 1; deadline <= 12; deadline++) {
        Fixture f; init(&f, loop, 2);
        AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 1,
            .cntp_ctl_el0 = 1, .cntp_cval_el0 = deadline};
        avz_native_memory_fast_path_set_architectural_state(f.memory, &state);
        AVZNativeChainResult r = run(&f, deadline, 64, 64, 64);
        CHECK(r.steps == deadline && r.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(f.checkpoint_steps == deadline);
        avz_native_memory_fast_path_get_architectural_state(f.memory, &state);
        CHECK(state.counter_ticks == deadline);
        finish(&f);
    }
    Fixture f; init(&f, loop, 2); f.stop = 1;
    AVZNativeChainResult r = run(&f, 64, 64, 64, 1);
    CHECK(r.steps == 2 && r.blocks == 1 && f.checkpoints == 1);
    CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 2);
    finish(&f);
    puts("PASS pinned callback retirement, fault/success counters, 12 exact timer budgets and checkpoint zero");
}
static void *reader(void *opaque) {
    AVZNativeExecutionContext *context = opaque;
    AVZNativeAssemblyStatistics previous = {0};
    for (unsigned i = 0; i < 100000; i++) {
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(context);
        CHECK(s.blocks >= previous.blocks && s.steps >= previous.steps);
        CHECK(!s.faults && !s.boundaries);
        previous = s;
    }
    return NULL;
}
static void publication(void) {
    const uint32_t code[] = {0x91000400, 0x17ffffff};
    Fixture f; init(&f, code, 2);
    pthread_t thread;
    CHECK(!pthread_create(&thread, NULL, reader, f.context));
    for (unsigned i = 0; i < 256; i++) {
        AVZNativeChainResult r = plain(&f, 2, 1);
        CHECK(r.steps == 2);
        AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(f.context);
        CHECK(s.blocks == i + 1 && s.steps == (i + 1) * 2);
    }
    CHECK(!pthread_join(thread, NULL));
    CHECK(f.lookups == 256);
    avz_native_execution_context_set_assembly_executor(f.context, 0);
    CHECK(plain(&f, 2, 1).steps == 2);
    CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 512);
    finish(&f);
    puts("PASS concurrent atomic reader, exact 256 slice publications and opt-out retention");
}
int main(void) {
    CHECK(ag_available());
    const MemoryRunner runners[] = {ag_run_memory, ag_run_memory_coalesced};
    for (size_t i = 0; i < sizeof(runners) / sizeof(runners[0]); i++) {
        dispatch_runner = runners[i];
        composition(); selection_and_early_exits(); stale_proof_and_pc();
        helpers_and_deadlines(); publication();
        puts(i ? "PASS experimental coalesced dispatcher suite" : "PASS production uncoalesced dispatcher suite");
    }
    guard_coalescing(); concurrent_alias_guard();
    return 0;
}
