/* Readiness tests, not a production multi-block adapter or a benchmark. */
#include <stdio.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "chain contract line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x1000, NEXT = 0x2000, RAM_SIZE = 0x4000 };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *memory;
    AVZNativeExecutionContext *context;
    _Atomic uint64_t generation[2], epochs[2], events;
    AGGuards proof;
    AGBlock blocks[2];
    AGChainStats stats;
    AGChain *graph;
    uint64_t checkpoint_calls, checkpoint_steps, checkpoint_blocks, stop;
} Fixture;

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
static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    Fixture *f = opaque;
    (void)pc; (void)pstate; (void)remaining;
    f->checkpoint_calls++;
    f->checkpoint_steps += steps;
    f->checkpoint_blocks += blocks;
    CHECK(total == f->checkpoint_steps);
    return f->stop ? 0 : 64;
}
static void init(Fixture *f, int semantic_target) {
    memset(f, 0, sizeof(*f));
    f->ram = avz_guest_memory_create(RAM_SIZE);
    f->cache = avz_native_block_cache_create();
    f->context = avz_native_execution_context_create();
    CHECK(f->ram && f->cache && f->context);
    uint8_t *bytes = avz_guest_memory_bytes(f->ram);
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache, bytes, 0, RAM_SIZE));
    f->memory = avz_native_memory_fast_path_create(bytes, 0, RAM_SIZE,
        f->cache, f, translate, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->memory && avz_native_memory_fast_path_set_guest_memory(f->memory, f->ram));
    avz_native_memory_fast_path_set_instruction_translator(f->memory, translate);
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->memory, 0);
    const uint32_t first[] = {0x91000400, branch(BASE + 4, NEXT)};
    const uint32_t second[] = {0x91000421, branch(NEXT + 4, BASE)};
    const uint32_t plt[] = {0x90000010, 0xf9408211, 0x91040210, 0xd61f0220};
    memcpy(bytes + BASE, first, sizeof(first));
    memcpy(bytes + NEXT, semantic_target ? plt : second,
        semantic_target ? sizeof(plt) : sizeof(second));
    uint64_t destination = NEXT + 0x200;
    memcpy(bytes + NEXT + 0x100, &destination, sizeof(destination));
    for (unsigned i = 0; i < 2; i++) {
        atomic_init(&f->generation[i], 1);
        atomic_init(&f->epochs[i], 1);
    }
    atomic_init(&f->events, 0);
    /* Synthetic proof tokens intentionally do NOT claim cache enrollment. */
    f->proof = (AGGuards){.shared = {&f->epochs[0], &f->epochs[1]},
        .expected = {0, 1, 1, 0}};
    f->blocks[0] = (AGBlock){(const uint32_t *)(bytes + BASE), 2, BASE, &f->generation[0], 1};
    f->blocks[1] = (AGBlock){(const uint32_t *)(bytes + NEXT), semantic_target ? 4 : 2,
        NEXT, &f->generation[1], 1};
    f->graph = ag_chain_create(f->blocks, 2, &f->proof, &f->stats);
    CHECK(f->graph);
    f->context->cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5};
    avz_native_execution_context_set_assembly_executor(f->context, 1);
}
static void finish(Fixture *f) {
    ag_chain_destroy(f->graph);
    CHECK(f->stats.retirements == 1 && f->stats.reclamations == 1);
    avz_native_execution_context_destroy(f->context);
    avz_native_memory_fast_path_destroy(f->memory);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->ram);
}
static AVZNativeChainResult production(Fixture *f, uint64_t allowance,
    uint64_t steps, uint64_t blocks, uint64_t interval) {
    AVZNativeBlockKey key = {.current_el = 1};
    return avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        f->context, f->cache, &key, allowance, steps, blocks, interval,
        checkpoint, f, avz_native_fast_fetch_instruction, f->memory,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, f->memory);
}
static void timer_gap(void) {
    for (unsigned kind = 0; kind < 3; kind++) {
        Fixture f; init(&f, 0);
        AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 1};
        if (kind == 0) { state.cntp_ctl_el0 = 1; state.cntp_cval_el0 = 2; }
        if (kind == 1) { state.cntv_ctl_el0 = 1; state.cntv_cval_el0 = 2; }
        if (kind == 2) state.pending_irq = 1;
        avz_native_memory_fast_path_set_architectural_state(f.memory, &state);
        AVZNativeChainResult current = production(&f, 8, 8, 8, 8);
        CHECK(current.steps == 2 && current.blocks == 1 && current.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(f.checkpoint_calls == 1 && f.checkpoint_steps == 2 && f.checkpoint_blocks == 1);
        CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 2);
        avz_native_memory_fast_path_set_architectural_state(f.memory, &state);
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        AVZNativeBlockResult offline = ag_chain_run(f.graph, (AGLimits){8, 8, 8, &f.events}, &cpu, f.memory);
        CHECK(offline.steps == 8 && offline.status == AVZ_NATIVE_STATUS_YIELDED);
        avz_native_memory_fast_path_get_architectural_state(f.memory, &state);
        CHECK(state.counter_ticks == 0); /* YIELDED alone does not mean timer serviced. */
        CHECK(f.stats.block_entries == 4 && offline.mapped_blocks == 0);
        cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5};
        offline = ag_chain_run(f.graph, (AGLimits){8, 8, 1, &f.events}, &cpu, f.memory);
        CHECK(offline.steps == 2);
        CHECK(avz_native_memory_fast_path_advance_time(f.memory, offline.steps, cpu.pstate));
        finish(&f);
    }
    puts("PASS 3 timer/IRQ gap witnesses: production returns after 2, offline retires 8 without native service; one-visit fence restores service");
}
static void budgets(void) {
    Fixture f; init(&f, 0);
    unsigned cases = 0;
    for (uint64_t steps = 1; steps <= 9; steps++)
    for (uint64_t service = 1; service <= 9; service++)
    for (uint64_t blocks = 1; blocks <= 4; blocks++) {
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        uint64_t expected = steps < service ? steps : service;
        if (expected > blocks * 2) expected = blocks * 2;
        uint64_t before = f.stats.block_entries;
        AVZNativeBlockResult r = ag_chain_run(f.graph, (AGLimits){steps, service, blocks, &f.events}, &cpu, NULL);
        CHECK(r.steps == expected && f.stats.block_entries - before == (expected + 1) / 2);
        CHECK(r.mapped_blocks == 0); /* Missing per-call production accounting. */
        CHECK(r.status == (service <= steps || blocks * 2 < steps ?
            AVZ_NATIVE_STATUS_YIELDED : AVZ_NATIVE_STATUS_MAX_STEPS));
        CHECK(cpu.x[0] == (expected + 3) / 4 && cpu.x[1] == (expected + 1) / 4);
        const uint64_t pcs[] = {BASE, BASE + 4, NEXT, NEXT + 4};
        CHECK(cpu.pc == pcs[expected % 4]);
        cases++;
    }
    for (unsigned zero = 0; zero < 3; zero++) {
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}, before = cpu;
        AGLimits limits = {8, 8, 8, &f.events};
        if (zero == 0) limits.steps = 0;
        if (zero == 1) limits.service_steps = 0;
        if (zero == 2) limits.blocks = 0;
        AVZNativeBlockResult r = ag_chain_run(f.graph, limits, &cpu, NULL);
        CHECK(r.status == AVZ_TP_STATUS_INVALID_ARGUMENT && !r.steps);
        CHECK(!memcmp(&cpu, &before, sizeof(cpu)));
    }
    AVZNativeCPU wide = {.pc = BASE, .pstate = 5};
    AVZNativeBlockResult bounded = ag_chain_run(f.graph,
        (AGLimits){UINT64_MAX, UINT64_MAX, 1, &f.events}, &wide, NULL);
    CHECK(bounded.steps == 2 && bounded.status == AVZ_NATIVE_STATUS_YIELDED && wide.pc == NEXT);
    atomic_store_explicit(&f.events, 1, memory_order_release);
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}, before = cpu;
    uint64_t entries = f.stats.block_entries;
    AVZNativeBlockResult r = ag_chain_run(f.graph, (AGLimits){8, 8, 8, &f.events}, &cpu, NULL);
    CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED && r.steps == 0);
    CHECK(f.stats.block_entries == entries && !memcmp(&cpu, &before, sizeof(cpu)));
    CHECK(atomic_load(&f.events) == 1);
    finish(&f);
    printf("PASS %u offline budget/visit cases, zero/UINT64_MAX limits and unacknowledged zero-step event\n", cases);
    init(&f, 0); f.stop = 1;
    AVZNativeChainResult p = production(&f, 64, 64, 64, 1);
    CHECK(p.steps == 2 && p.blocks == 1 && f.checkpoint_calls == 1);
    f.stop = 0; f.checkpoint_calls = f.checkpoint_steps = f.checkpoint_blocks = 0;
    p = production(&f, 3, 3, 64, 1);
    CHECK(p.steps == 3 && p.blocks == 2 && f.checkpoint_steps == 3);
    finish(&f);
    puts("PASS production checkpoint-zero stop, fresh resume, partial-block accounting");
}
static void semantic_successor(void) {
    Fixture f; init(&f, 1);
    AVZNativeBlockKey key = {.pc = NEXT, .current_el = 1};
    uint32_t status, unsupported;
    const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(
        f.cache, &key, avz_native_fast_fetch_instruction, f.memory, &status, &unsupported);
    CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    CHECK(!avz_assembly_cache_program(f.cache, block, 1));
    /* Raw graph creation above accepted this target: its caller must exclude it. */
    uint64_t value;
    CHECK(avz_native_fast_memory_read(f.memory, NEXT + 0x100, 8, &value));
    AVZNativeChainResult r = production(&f, 6, 6, 8, 8);
    CHECK(r.steps == 6 && r.fast_path_steps == 4 && r.fast_path_hits == 1);
    CHECK(f.context->cpu.pc == NEXT + 0x200 && f.context->cpu.x[16] == NEXT + 0x100);
    CHECK(avz_native_execution_context_assembly_statistics(f.context).steps == 2);
    finish(&f);
    puts("PASS production assembly-to-C PLT successor; offline graph admission does not enforce this policy");
}
int main(void) {
    CHECK(ag_available());
    timer_gap(); budgets(); semantic_successor();
    puts("PASS bounded readiness contracts; no production multi-block or Swift VM integration claimed");
    return 0;
}
