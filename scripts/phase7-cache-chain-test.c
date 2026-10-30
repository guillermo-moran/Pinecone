/* Production cache/decoder/service runtime, with white-box ownership assertions.
 * No substitute graph, synthetic epoch storage, speculative fetch or benchmark. */
#include "../Sources/ARM64VizNative/ARM64VizBlockCache.c"
#include <stdio.h>
#include <pthread.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "cache graph line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x1000, NEXT = 0x2000, RAM_SIZE = 0x10000 };
enum { KEEP, CLEAR, EVICT, LOCAL_WRITE, SHARED_WRITE, SHARED_DISCARD, TLBI, REENTER,
    CHANGE_COUNT, CHANGE_BINDING };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *memory;
    const AVZNativeDecodedBlock *root, *next;
    AGServiceChain *chain;
    AGGuards proof;
    AVZNativeBlockKey key;
    uint64_t serial, charged;
    unsigned fetches, action;
    unsigned peer_kind, tlbi_kind, journal_count, ready, published;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
} Fixture;

static uint32_t branch(uint64_t from, uint64_t to) {
    return 0x14000000u | ((uint32_t)(((int64_t)to - (int64_t)from) / 4) & 0x3ffffffu);
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    (void)opaque; (void)write;
    if (address > RAM_SIZE - width) return 0;
    *physical = address; return 1;
}
static int fetch(void *opaque, uint64_t address, uint64_t *physical, uint32_t *word) {
    Fixture *f = opaque;
    f->fetches++;
    return avz_native_fast_fetch_instruction(f->memory, address, physical, word);
}
static void put(Fixture *f, uint64_t pc, uint32_t word) {
    memcpy(avz_guest_memory_bytes(f->ram) + pc, &word, sizeof(word));
}
static void capture(Fixture *f) {
    avz_native_memory_fast_path_synchronize_translations(f->memory);
    f->proof = (AGGuards){.local = avz_native_block_cache_code_mutation_epoch_token(f->cache),
        .shared = {&f->ram->code_mutation_epoch, &f->ram->translation_epoch}};
    f->proof.expected[0] = *f->proof.local;
    f->proof.expected[1] = atomic_load(f->proof.shared[0]);
    f->proof.expected[2] = atomic_load(f->proof.shared[1]);
}
static const AVZNativeDecodedBlock *decode(Fixture *f, uint64_t pc) {
    AVZNativeBlockKey key = f->key;
    key.pc = pc;
    uint32_t status = 0;
    const AVZNativeDecodedBlock *b = avz_native_block_cache_get_or_decode(
        f->cache, &key, fetch, f, &status, NULL);
    CHECK(b && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    return b;
}
static void edge(Fixture *f, const AVZNativeDecodedBlock *a, const AVZNativeDecodedBlock *b) {
    avz_native_decoded_block_record_successor(f->cache, a,
        avz_native_decoded_block_serial(f->cache, a), b,
        avz_native_decoded_block_serial(f->cache, b));
}
static void warm(Fixture *f) {
    capture(f);
    f->root = decode(f, BASE);
    f->next = decode(f, NEXT);
    f->serial = avz_native_decoded_block_serial(f->cache, f->root);
    edge(f, f->root, f->next);
    edge(f, f->next, f->root);
    CHECK(avz_assembly_cache_program(f->cache, f->root, 1));
    CHECK(avz_assembly_cache_program(f->cache, f->next, 1));
}
static void init(Fixture *f) {
    memset(f, 0, sizeof(*f));
    f->key = (AVZNativeBlockKey){.pc = BASE, .current_el = 1};
    f->ram = avz_guest_memory_create(RAM_SIZE);
    f->cache = avz_native_block_cache_create();
    CHECK(f->ram && f->cache);
    uint8_t *bytes = avz_guest_memory_bytes(f->ram);
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache, bytes, 0, RAM_SIZE));
    f->memory = avz_native_memory_fast_path_create(bytes, 0, RAM_SIZE, f->cache,
        f, translate, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->memory && avz_native_memory_fast_path_set_guest_memory(f->memory, f->ram));
    avz_native_memory_fast_path_set_instruction_translator(f->memory, translate);
    f->cache->batch_prefetch_limit = 0;
    put(f, BASE, 0x91000400); put(f, BASE + 4, branch(BASE + 4, NEXT));
    put(f, NEXT, 0x91000421); put(f, NEXT + 4, branch(NEXT + 4, BASE));
    warm(f);
}
static AGServiceChain *admit(Fixture *f) {
    unsigned before = f->fetches;
    AGServiceChain *c = avz_assembly_cache_service_chain(f->cache, f->root,
        &f->key, f->memory, &f->proof);
    CHECK(before == f->fetches);
    return c;
}
static void finish(Fixture *f) {
    avz_assembly_cache_service_chain_retire(f->cache);
    avz_native_memory_fast_path_destroy(f->memory);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->ram);
}
static AGServiceLimits limits(uint64_t n) {
    return (AGServiceLimits){n, n, n, n, NULL};
}
static int collision_fetch(void *opaque, uint64_t pc, uint64_t *physical, uint32_t *word) {
    (void)opaque;
    *physical = 0x6000; *word = branch(pc, pc); return 1;
}
static void evict_root(Fixture *f) {
    size_t target = avz_block_set_index(avz_block_key_hash(f->cache, &f->key));
    uint64_t previous = f->serial;
    unsigned filled = 0;
    for (uint64_t pc = 0x100000; filled < 4; pc += 4) {
        AVZNativeBlockKey key = f->key; key.pc = pc;
        if (avz_block_set_index(avz_block_key_hash(f->cache, &key)) != target) continue;
        CHECK(avz_native_block_cache_get_or_decode(f->cache, &key,
            collision_fetch, NULL, NULL, NULL));
        filled++;
    }
    CHECK(avz_native_decoded_block_serial(f->cache, f->root) != previous);
    CHECK(f->cache->statistics.evictions > 0);
    CHECK(!f->cache->service_chain.chain);
}
static AGServiceDecision service(void *opaque, const AGServiceBoundary *b,
    const AVZNativeCPU *cpu) {
    Fixture *f = opaque;
    CHECK(f->charged + b->retired_delta == b->total_steps);
    f->charged += b->retired_delta;
    if (!b->initial && f->peer_kind) {
        CHECK(!pthread_mutex_lock(&f->mutex));
        f->ready = 1;
        CHECK(!pthread_cond_signal(&f->condition));
        while (!f->published) CHECK(!pthread_cond_wait(&f->condition, &f->mutex));
        CHECK(!pthread_mutex_unlock(&f->mutex));
    }
    avz_native_memory_fast_path_advance_time(f->memory, b->retired_delta, cpu->pstate);
    CHECK(avz_assembly_cache_service_chain_info(f->cache).active);
    if (!b->initial && f->action) {
        unsigned action = f->action; f->action = KEEP;
        switch (action) {
        case CLEAR:
            avz_native_block_cache_clear(f->cache);
            CHECK(!avz_native_decoded_block_serial(f->cache, f->root));
            CHECK(!f->cache->code_page_refcounts[BASE >> 12]);
            warm(f);
            CHECK(f->serial != f->cache->service_chain.members[0].serial);
            break;
        case EVICT: evict_root(f); break;
        case CHANGE_COUNT:
            ((AVZNativeDecodedBlock *)f->next)->instruction_count++;
            break;
        case CHANGE_BINDING:
            f->memory->translation_state.ttbr0_el1 ^= UINT64_C(1) << 48;
            break;
        case LOCAL_WRITE:
            CHECK(avz_native_fast_memory_write(f->memory, NEXT, 4, 0x91000821));
            break;
        case SHARED_WRITE:
            avz_guest_memory_note_write(f->ram, NEXT, 4); break;
        case SHARED_DISCARD: {
            uint64_t serial = avz_native_decoded_block_serial(f->cache, f->next);
            avz_guest_memory_note_write(f->ram, NEXT, 4);
            f->next = decode(f, NEXT);
            CHECK(avz_native_decoded_block_serial(f->cache, f->next) != serial);
            CHECK(!f->cache->service_chain.chain);
            break;
        }
        case TLBI:
            avz_guest_memory_publish_tlbi(f->ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL});
            avz_native_memory_fast_path_advance_time(f->memory, 0, cpu->pstate);
            break;
        case REENTER: {
            AVZNativeCPU other = {.pc = BASE};
            AGServiceResult r = avz_assembly_cache_service_chain_run(f->cache, f->chain,
                limits(2), &other, service, f);
            CHECK(r.stop == AG_SERVICE_STOP_INVALID);
            break;
        }
        default: CHECK(0);
        }
        /* Retirement cannot reclaim the active service pin or permit rebuilding. */
        CHECK(ag_service_chain_bytes(f->chain) > 0);
        CHECK(!admit(f));
        if (action == CLEAR || action == EVICT || action == LOCAL_WRITE || action == TLBI) {
            CHECK(!f->cache->service_chain.chain);
            avz_assembly_cache_service_chain_retire(f->cache);
            CHECK(ag_service_chain_bytes(f->chain) > 0);
        }
    }
    return (AGServiceDecision){.next_steps = 100, .action = AG_SERVICE_CONTINUE};
}
static AGServiceResult run(Fixture *f, uint64_t steps) {
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 4};
    f->charged = 0;
    AGServiceResult r = avz_assembly_cache_service_chain_run(f->cache, f->chain,
        limits(steps), &cpu, service, f);
    CHECK(r.timer_accounted_steps == f->charged);
    CHECK(r.architectural.steps == f->charged);
    if (r.architectural.steps == 2) CHECK(cpu.x[1] == 0);
    return r;
}

static void ownership(void) {
    for (unsigned action = KEEP; action <= REENTER; action++) {
        Fixture f; init(&f);
        f.chain = admit(&f); CHECK(f.chain);
        AVZAssemblyChainInfo info = avz_assembly_cache_service_chain_info(f.cache);
        CHECK(info.members == 2 && info.instructions == 4 && info.bytes <= 32768);
        CHECK(admit(&f) == f.chain);
        CHECK(avz_assembly_cache_service_chain_contains(f.cache, f.root, f.serial));
        CHECK(!avz_assembly_cache_service_chain_contains(f.cache, f.root, f.serial + 1));
        /* Auxiliary program eviction alone must not retire graph-owned copies. */
        avz_assembly_release(f.cache, (AVZBlockCacheEntry *)avz_entry_for_block(f.cache, f.root));
        CHECK(admit(&f) == f.chain);
        f.action = action;
        AGServiceResult r = run(&f, 8);
        if (action == KEEP || action == REENTER) {
            CHECK(r.architectural.steps == 8 && r.visits == 4);
            CHECK(f.cache->service_chain.chain == f.chain);
        } else {
            CHECK(r.architectural.steps == 2 && r.visits == 1);
            CHECK(r.architectural.status == AVZ_TP_STATUS_REVALIDATE);
            CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
            warm(&f); f.chain = admit(&f); CHECK(f.chain);
            CHECK(run(&f, 4).visits == 2);
        }
        finish(&f);
    }
}

static void admission(void) {
    Fixture f; init(&f);
    AVZNativeDecodedBlock *root = (AVZNativeDecodedBlock *)f.root;
    AVZNativeDecodedBlock *next = (AVZNativeDecodedBlock *)f.next;
    for (unsigned kind = 0; kind < 4; kind++) {
        uint8_t *flag = kind == 0 ? &next->semantic_candidates[0] :
            kind == 1 ? &next->trace_semantic_candidates[0] :
            kind == 2 ? &next->chain_barrier : &next->requires_host_checkpoint;
        *flag = 1; CHECK(!admit(&f));
        /* Full-member exclusion holds for entry through an interior suffix. */
        const AVZNativeDecodedBlock *saved = f.root;
        f.root = next; f.key.pc = NEXT + 4;
        CHECK(!admit(&f));
        f.root = saved; f.key.pc = BASE; *flag = 0;
    }
    const uint16_t barriers[] = {AVZ_NATIVE_OP_SYSTEM_REGISTER_READ,
        AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE, AVZ_NATIVE_OP_SYSTEM_INSTRUCTION,
        AVZ_NATIVE_OP_EXCEPTION_RETURN, AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION,
        AVZ_NATIVE_OP_PSTATE_IMMEDIATE, AVZ_NATIVE_OP_WAIT, AVZ_NATIVE_OP_HALT,
        AVZ_NATIVE_OP_BARRIER};
    uint16_t saved_kind = next->instructions[0].kind;
    for (size_t i = 0; i < sizeof(barriers) / sizeof(barriers[0]); i++) {
        next->instructions[0].kind = barriers[i]; CHECK(!admit(&f));
    }
    next->instructions[0].kind = saved_kind;
    root->semantic_candidates[1] = 1; CHECK(!admit(&f)); root->semantic_candidates[1] = 0;
    /* No metadata means no speculative target lookup or one-off allocation. */
    memset(root->successors, 0, sizeof(root->successors));
    CHECK(!admit(&f));
    edge(&f, root, root);
    f.chain = admit(&f); CHECK(f.chain);
    CHECK(avz_assembly_cache_service_chain_info(f.cache).members == 1);
    avz_assembly_cache_service_chain_retire(f.cache);
    edge(&f, root, next);
    AGGuards saved = f.proof;
    f.proof.expected[0]--; CHECK(!admit(&f)); f.proof = saved;
    f.proof.expected[1]--; CHECK(!admit(&f)); f.proof = saved;
    f.proof.expected[2]--; CHECK(!admit(&f)); f.proof = saved;
    uint64_t fake = *saved.local;
    f.proof.local = &fake; CHECK(!admit(&f)); f.proof = saved;
    f.proof.shared[1] = f.proof.shared[0]; CHECK(!admit(&f)); f.proof = saved;
    finish(&f);
}

static void self_loop(void) {
    Fixture f; init(&f);
    avz_native_block_cache_clear(f.cache);
    put(&f, BASE + 4, branch(BASE + 4, BASE));
    capture(&f); f.root = decode(&f, BASE);
    CHECK(avz_assembly_cache_program(f.cache, f.root, 1));
    CHECK(!admit(&f));
    edge(&f, f.root, f.root);
    f.chain = admit(&f); CHECK(f.chain);
    AGServiceResult r = run(&f, 10);
    CHECK(r.architectural.steps == 10 && r.visits == 5);
    finish(&f);
}

static void bounds_and_binding(void) {
    Fixture f; init(&f);
    avz_native_block_cache_clear(f.cache);
    const AVZNativeDecodedBlock *members[9];
    for (size_t i = 0; i < 9; i++) {
        uint64_t pc = BASE + i * 256;
        for (unsigned j = 0; j < 15; j++) put(&f, pc + j * 4, 0x91000400);
        put(&f, pc + 60, branch(pc + 60, i == 8 ? BASE : pc + 256));
    }
    capture(&f);
    for (size_t i = 0; i < 9; i++) {
        members[i] = decode(&f, BASE + i * 256);
        CHECK(avz_assembly_cache_program(f.cache, members[i], 1));
    }
    for (size_t i = 0; i < 9; i++) edge(&f, members[i], members[(i + 1) % 9]);
    f.root = members[0]; CHECK(avz_assembly_cache_program(f.cache, f.root, 1));
    f.chain = admit(&f); CHECK(f.chain);
    AVZAssemblyChainInfo info = avz_assembly_cache_service_chain_info(f.cache);
    CHECK(info.members == 8 && info.instructions == 128 && info.bytes <= 32768);
    CHECK(run(&f, 200).architectural.steps == 128);
    /* A full fast-path TTBR/ASID change cannot hide behind canonical key masking. */
    f.memory->translation_state.ttbr0_el1 ^= UINT64_C(1) << 48;
    CHECK(run(&f, 2).architectural.steps == 0);
    CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
    finish(&f);
}

static void diagnostics_and_cold_roots(void) {
    Fixture f; init(&f);
    f.chain = admit(&f); CHECK(f.chain);
    AVZAssemblyChainDiagnostics d = avz_assembly_cache_service_chain_diagnostics(f.cache);
    CHECK(d.builds == 1 && d.reuses == 0 && d.retirements == 0);
    CHECK(d.bytes > 0 && d.peak_bytes == d.bytes);
    CHECK(admit(&f) == f.chain);
    const AVZNativeDecodedBlock *saved_root = f.root;
    for (unsigned i = 0; i < 30; i++) {
        uint64_t pc = 0x4000 + i * 64;
        put(&f, pc, 0x91000400); put(&f, pc + 4, branch(pc + 4, pc));
        f.root = decode(&f, pc); f.key.pc = pc;
        /* Exercise both cold and fully retained/repeated unrelated roots. */
        if (i & 1) {
            CHECK(avz_assembly_cache_program(f.cache, f.root, 1));
            edge(&f, f.root, f.root);
        }
        CHECK(!admit(&f));
        CHECK(f.cache->service_chain.chain == f.chain);
    }
    f.root = saved_root; f.key.pc = BASE;
    d = avz_assembly_cache_service_chain_diagnostics(f.cache);
    CHECK(d.builds == 1 && d.reuses == 1 && d.retirements == 0 && !d.failed_builds);
    CHECK(d.retained_graph_misses == 30);
    avz_native_block_cache_clear(f.cache);
    d = avz_assembly_cache_service_chain_diagnostics(f.cache);
    CHECK(d.builds == 1 && d.retirements == 1 && d.bytes == 0 && d.peak_bytes > 0);
    avz_assembly_cache_service_chain_retire(f.cache);
    CHECK(avz_assembly_cache_service_chain_diagnostics(f.cache).retirements == 1);
    finish(&f);
}

static void page_and_mapping_rejection(void) {
    Fixture f; init(&f);
    AVZNativeDecodedBlock *next = (AVZNativeDecodedBlock *)f.next;
    uint64_t original = next->physical_addresses[1];
    next->physical_addresses[1] = 0x3000;
    CHECK(!admit(&f)); next->physical_addresses[1] = original;
    next->code_page_count = 2; CHECK(!admit(&f)); next->code_page_count = 1;
    AVZBlockCacheEntry *e = (AVZBlockCacheEntry *)avz_entry_for_block(f.cache, f.next);
    uint64_t translation = e->validated_translation_epoch;
    e->validated_translation_epoch--;
    CHECK(!admit(&f));
    CHECK(e->validated_translation_epoch != translation); /* No lazy revalidation. */
    e->validated_translation_epoch = translation;
    f.chain = admit(&f); CHECK(f.chain);
    f.memory->ram_base = 4096;
    CHECK(run(&f, 2).architectural.steps == 0);
    CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
    f.memory->ram_base = 0;
    f.chain = admit(&f); CHECK(f.chain);
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ASID, .asid = 3});
    CHECK(!admit(&f)); /* Pending translation cannot be blessed by a newer snapshot. */
    CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
    finish(&f);
}

static int translate_remapped_instruction(void *opaque, uint64_t address,
    uint8_t width, uint8_t write, uint64_t *physical) {
    if (!translate(opaque, address, width, write, physical)) return 0;
    if ((address & ~UINT64_C(0xfff)) == NEXT) *physical += 0x1000;
    return 1;
}

static AGServiceDecision remap_instruction_service(void *opaque,
    const AGServiceBoundary *b, const AVZNativeCPU *cpu) {
    Fixture *f = opaque;
    AGServiceDecision decision = service(opaque, b, cpu);
    if (!b->initial && b->visits == 1) {
        CHECK(f->cache->service_chain.chain == f->chain);
        avz_native_memory_fast_path_set_instruction_translator(
            f->memory, translate_remapped_instruction);
    }
    return decision;
}

static void instruction_translator_replacement(void) {
    Fixture f; init(&f);
    put(&f, 0x3000, 0x91001c21); /* add x1, x1, #7 at remapped NEXT. */
    put(&f, 0x3004, branch(NEXT + 4, BASE));
    f.chain = admit(&f); CHECK(f.chain);
    uint64_t next_serial = avz_native_decoded_block_serial(f.cache, f.next);
    uint64_t translation_epoch = f.cache->translation_epoch;
    uint64_t code_epoch = f.cache->code_mutation_epoch;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 4};
    AGServiceResult r = avz_assembly_cache_service_chain_run(f.cache, f.chain,
        limits(4), &cpu, service, &f);
    CHECK(r.architectural.steps == 4 && cpu.x[0] == 1 && cpu.x[1] == 1);
    CHECK(f.cache->service_chain.chain == f.chain);

    cpu = (AVZNativeCPU){.pc = BASE, .pstate = 4};
    f.charged = 0;
    r = avz_assembly_cache_service_chain_run(f.cache, f.chain,
        limits(4), &cpu, remap_instruction_service, &f);
    CHECK(cpu.x[1] == 0); /* The old NEXT must not execute after replacement. */
    CHECK(cpu.x[0] == 1 && cpu.pc == NEXT);
    CHECK(r.architectural.steps == 2 && r.visits == 1);
    CHECK(r.architectural.status == AVZ_TP_STATUS_REVALIDATE);
    CHECK(r.stop == AG_SERVICE_STOP_PROOF);
    CHECK(r.timer_accounted_steps == 2 && f.charged == 2);
    CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
    CHECK(f.cache->translation_epoch != translation_epoch);
    CHECK(f.cache->code_mutation_epoch != code_epoch);
    /* Invalidation is lazy: resident decoded entries must reject their old mapping. */
    CHECK(avz_native_decoded_block_serial(f.cache, f.next) == next_serial);
    unsigned fetches = f.fetches;
    warm(&f);
    CHECK(f.fetches > fetches);
    CHECK(avz_native_decoded_block_serial(f.cache, f.next) != next_serial);
    CHECK(f.next->physical_addresses[0] == 0x3000);
    CHECK(f.next->instructions[0].raw == 0x91001c21);
    f.chain = admit(&f); CHECK(f.chain);
    f.charged = 0;
    r = avz_assembly_cache_service_chain_run(f.cache, f.chain,
        limits(2), &cpu, service, &f);
    CHECK(r.architectural.steps == 2 && r.visits == 1);
    CHECK(r.timer_accounted_steps == 2 && f.charged == 2);
    CHECK(cpu.x[0] == 1 && cpu.x[1] == 7 && cpu.pc == BASE);
    finish(&f);
}

static void *publish_peer(void *opaque) {
    Fixture *f = opaque;
    CHECK(!pthread_mutex_lock(&f->mutex));
    while (!f->ready) CHECK(!pthread_cond_wait(&f->condition, &f->mutex));
    if (f->peer_kind == 1) {
        __atomic_store_n((uint32_t *)(avz_guest_memory_bytes(f->ram) + NEXT),
            0x91000821, __ATOMIC_RELAXED);
        avz_guest_memory_note_write(f->ram, NEXT, 4);
    } else {
        for (unsigned i = 0; i < f->journal_count; i++)
            avz_guest_memory_publish_tlbi(f->ram, (AVZNativeTLBI){
                .kind = (uint8_t)f->tlbi_kind, .virtual_address = NEXT, .asid = 7});
    }
    f->published = 1;
    CHECK(!pthread_cond_signal(&f->condition));
    CHECK(!pthread_mutex_unlock(&f->mutex));
    return NULL;
}
static void peer_publications(void) {
    for (unsigned test = 0; test < 6; test++) {
        Fixture f; init(&f);
        CHECK(!pthread_mutex_init(&f.mutex, NULL));
        CHECK(!pthread_cond_init(&f.condition, NULL));
        f.peer_kind = test ? 2 : 1;
        f.tlbi_kind = test ? (test - 1) % 4 : 0;
        f.journal_count = test == 5 ? 65 : 1;
        f.chain = admit(&f); CHECK(f.chain);
        pthread_t thread;
        CHECK(!pthread_create(&thread, NULL, publish_peer, &f));
        AGServiceResult r = run(&f, 8);
        CHECK(!pthread_join(thread, NULL));
        CHECK(r.architectural.steps == 2 && r.visits == 1);
        CHECK(r.architectural.status == AVZ_TP_STATUS_REVALIDATE);
        CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
        CHECK(!pthread_cond_destroy(&f.condition));
        CHECK(!pthread_mutex_destroy(&f.mutex));
        finish(&f);
    }
}

static void bulk_validation_after_service(void) {
    /* Deliberately corrupt owner metadata without publishing a generation.
     * Even unchanged epoch tokens must not waive binding/member validation. */
    for (unsigned action = CHANGE_COUNT; action <= CHANGE_BINDING; action++) {
        Fixture f; init(&f);
        f.chain = admit(&f); CHECK(f.chain);
        f.action = action;
        AGServiceResult r = run(&f, 8);
        CHECK(r.architectural.steps == 2 && r.visits == 1);
        CHECK(r.stop == AG_SERVICE_STOP_PROOF);
        CHECK(!avz_assembly_cache_service_chain_info(f.cache).bytes);
        if (action == CHANGE_COUNT)
            ((AVZNativeDecodedBlock *)f.next)->instruction_count--;
        else f.memory->translation_state.ttbr0_el1 ^= UINT64_C(1) << 48;
        finish(&f);
    }
}

int main(void) {
    CHECK(ag_available());
    ownership(); admission(); self_loop(); bounds_and_binding();
    diagnostics_and_cold_roots(); page_and_mapping_rejection();
    instruction_translator_replacement();
    peer_publications(); bulk_validation_after_service();
    puts("production cache graph ownership/admission: PASS");
    return 0;
}
