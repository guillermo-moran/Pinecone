#include "gadget_internal.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "chain line %d: %s\n", __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x8000, MAX_BLOCKS = 256 };
typedef struct {
    uint32_t words[MAX_BLOCKS][16];
    AGBlock blocks[MAX_BLOCKS];
    AGProgram *programs[MAX_BLOCKS];
    _Atomic uint64_t pages[MAX_BLOCKS], shared[3], events;
    uint64_t local;
    AGGuards guards;
    AGChainStats stats;
    AGChain *chain;
    size_t count, length;
} Fixture;
static uint64_t cases;
static uint64_t now(clockid_t clock) {
    struct timespec t; CHECK(!clock_gettime(clock, &t));
    return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}
static uint32_t branch(uint64_t from, uint64_t to) {
    return UINT32_C(0x14000000) | ((uint32_t)((int64_t)(to - from) / 4) & UINT32_C(0x3ffffff));
}
static AVZNativeCPU initial(void) {
    AVZNativeCPU c = {.pc = BASE, .pstate = 5, .sp = 0x4000};
    c.x[3] = UINT64_MAX;
    for (size_t i = 0; i < sizeof(c.v); i++) ((unsigned char *)c.v)[i] = (unsigned char)(i * 7);
    return c;
}
static void compile(Fixture *f) {
    f->chain = ag_chain_create(f->blocks, f->count, &f->guards, &f->stats); CHECK(f->chain);
    for (size_t i = 0; i < f->count; i++) {
        f->programs[i] = ag_create(f->words[i], f->length, f->blocks[i].base);
        CHECK(f->programs[i]);
    }
}
static void init(Fixture *f, size_t count, size_t length) {
    memset(f, 0, sizeof(*f)); f->count = count; f->length = length; f->local = 1;
    for (unsigned i = 0; i < 3; i++) atomic_init(&f->shared[i], 1);
    atomic_init(&f->events, 0);
    f->guards = (AGGuards){.local = &f->local,
        .shared = {&f->shared[0], &f->shared[1], &f->shared[2]}, .expected = {1, 1, 1, 1}};
    for (size_t i = 0; i < count; i++) {
        atomic_init(&f->pages[i], 1);
        uint64_t base = BASE + i * 4096;
        for (size_t j = 0; j < length; j++) f->words[i][j] = 0x91000400; // add x0, x0, #1
        f->words[i][length - 1] = branch(base + (length - 1) * 4, BASE + ((i + 1) % count) * 4096);
        f->blocks[i] = (AGBlock){f->words[i], length, base, &f->pages[i], 1};
    }
    compile(f);
}
static void discard_programs(Fixture *f) {
    ag_chain_destroy(f->chain); f->chain = NULL;
    for (size_t i = 0; i < f->count; i++) { ag_destroy(f->programs[i]); f->programs[i] = NULL; }
}
static AVZNativeBlockResult run(Fixture *f, AVZNativeCPU *cpu, uint64_t steps, uint64_t service, uint64_t blocks) {
    return ag_chain_run(f->chain, (AGLimits){steps, service, blocks, &f->events}, cpu, NULL);
}
static void reference(Fixture *f, AVZNativeCPU *c, uint64_t steps) {
    for (uint64_t n = 0; n < steps; n++) {
        size_t i = 0;
        while (i < f->count && !(c->pc >= f->blocks[i].base && c->pc - f->blocks[i].base < f->length * 4)) i++;
        CHECK(i < f->count);
        AVZNativeInstruction d;
        CHECK(avz_native_decode_instruction(f->words[i][(c->pc - f->blocks[i].base) / 4], &d));
        AVZNativeBlockResult r = ag_reference_cpu(&d, 1, c->pc, 1, c);
        CHECK(r.steps == 1 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    }
}
static void differential(void) {
    for (size_t length = 1; length <= 16; length *= 2) {
        Fixture f; init(&f, 4, length);
        for (size_t offset = 0; offset < length; offset++)
        for (uint64_t budget = 1; budget <= 65; budget++)
        for (uint64_t service = 1; service <= 65; service += 8)
        for (uint64_t blocks = 1; blocks <= 4; blocks++) {
            AVZNativeCPU c = initial(), expected;
            c.pc += offset * 4; expected = c;
            uint64_t limit = budget < service ? budget : service;
            uint64_t block_limit = length - offset + (blocks - 1) * length;
            uint64_t retired = limit < block_limit ? limit : block_limit;
            uint64_t old_entries = f.stats.block_entries;
            AVZNativeBlockResult r = run(&f, &c, budget, service, blocks);
            CHECK(r.steps == retired && r.generic_dispatches == retired);
            CHECK(r.status == ((service <= budget || block_limit < budget) ? AVZ_NATIVE_STATUS_YIELDED : AVZ_NATIVE_STATUS_MAX_STEPS));
            CHECK(f.stats.block_entries - old_entries <= blocks);
            reference(&f, &expected, retired);
            CHECK(!memcmp(&c, &expected, sizeof(c))); cases++;
        }
        CHECK(f.stats.proof_scans == 1 && f.stats.page_checks == 4);
        CHECK(f.stats.proof_hits + 1 == f.stats.entries);
        discard_programs(&f); CHECK(f.stats.retirements == 1 && f.stats.reclamations == 1);
    }
}
static void edge_cases(void) {
    Fixture f; init(&f, 2, 4);
    AVZNativeCPU c = initial(), before = c;
    CHECK(!ag_chain_create(f.blocks, 0, &f.guards, NULL));
    AGBlock invalid = f.blocks[0]; invalid.count = 17;
    CHECK(!ag_chain_create(&invalid, 1, &f.guards, NULL));
    invalid = f.blocks[0]; invalid.base = 0x8ffc;
    CHECK(!ag_chain_create(&invalid, 1, &f.guards, NULL));
    invalid.base = UINT64_MAX - 3;
    CHECK(!ag_chain_create(&invalid, 1, &f.guards, NULL));
    const uint32_t early_branch[] = {0x14000001, 0xd503201f};
    invalid = f.blocks[0]; invalid.words = early_branch; invalid.count = 2;
    CHECK(!ag_chain_create(&invalid, 1, &f.guards, NULL));
    CHECK(run(&f, &c, 0, 1, 1).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(run(&f, &c, 1, 0, 1).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(run(&f, &c, 1, 1, 0).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(!memcmp(&c, &before, sizeof(c)));
    for (uint64_t event = 1; event <= 4; event <<= 1) {
        atomic_store(&f.events, event);
        AVZNativeBlockResult r = run(&f, &c, 64, 64, 16);
        CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED && !r.steps);
        CHECK(!memcmp(&c, &before, sizeof(c)));
    }
    atomic_store(&f.events, 0);
    CHECK(run(&f, &c, 64, 65, 16).steps == 64);
    uint64_t scans = f.stats.proof_scans;
    atomic_fetch_add(&f.shared[0], 1); // unrelated executable page
    CHECK(run(&f, &c, 64, 65, 16).steps == 64);
    CHECK(f.stats.proof_scans == scans + 1);
    atomic_fetch_add(&f.pages[1], 1); atomic_fetch_add(&f.shared[0], 1);
    before = c;
    AVZNativeBlockResult r = run(&f, &c, 64, 64, 16);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && !r.steps && !memcmp(&c, &before, sizeof(c)));
    discard_programs(&f);
    for (unsigned guard = 0; guard < 3; guard++) {
        init(&f, 2, 4); c = initial();
        if (!guard) f.local++; else atomic_fetch_add(&f.shared[guard], 1);
        r = run(&f, &c, 64, 64, 16);
        CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && !r.steps);
        discard_programs(&f);
    }
    // Fallthrough, target into the middle, out-of-chain branch, and precise unsupported exit.
    for (unsigned mode = 0; mode < 5; mode++) {
        init(&f, 2, 4); discard_programs(&f);
        f.blocks[1].base = BASE + 16;
        f.words[0][3] = mode == 0 ? 0xd503201f :
            mode == 1 ? branch(BASE + 12, BASE + 20) :
            mode == 2 ? branch(BASE + 12, BASE + 4096) :
            mode == 3 ? 0x91000400 : 0xffffffff;
        f.words[1][3] = mode == 3 ? 0xd503201f : branch(BASE + 28, BASE);
        compile(&f); c = initial(); before = c;
        r = run(&f, &c, 64, 65, 64);
        CHECK(r.status == (mode == 4 ? AVZ_NATIVE_STATUS_UNSUPPORTED :
            mode == 2 || mode == 3 ? AVZ_NATIVE_STATUS_OUTSIDE_BLOCK : AVZ_NATIVE_STATUS_MAX_STEPS));
        CHECK(r.steps == (mode == 4 ? 3 : mode == 2 ? 4 : mode == 3 ? 8 : 64));
        reference(&f, &before, r.steps); CHECK(!memcmp(&c, &before, sizeof(c)));
        if (mode == 4) CHECK(r.unsupported_instruction == 0xffffffff);
        discard_programs(&f); cases++;
    }
    // Conditional, compare/test and link branches across allocations, including not-taken edges.
    const uint32_t branches[] = {0x54000040, 0xb4000040, 0xb5000040, 0x36000040, 0x37000040, 0x94000002};
    for (size_t b = 0; b < sizeof(branches) / sizeof(branches[0]); b++)
    for (unsigned flags = 0; flags < 16; flags++) {
        init(&f, 2, 4); discard_programs(&f);
        f.blocks[1].base = BASE + 16;
        f.words[0][0] = f.words[0][1] = f.words[0][2] = 0xd503201f;
        f.words[0][3] = branches[b];
        f.words[1][3] = branch(BASE + 28, BASE);
        compile(&f); c = initial(); c.pstate |= (uint64_t)flags << 28; c.x[0] = flags & 1;
        before = c; r = run(&f, &c, 65, 66, 65);
        CHECK(r.steps == 65 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        reference(&f, &before, 65); CHECK(!memcmp(&c, &before, sizeof(c)));
        discard_programs(&f); cases++;
    }
}
typedef struct { Fixture *f; unsigned calls, fail, retire; } Callback;
static void *invalidate_retiring_chain(void *opaque) {
    Fixture *f = opaque;
    for (unsigned i = 0; i < 300; i++) atomic_fetch_add_explicit(&f->shared[1], 1, memory_order_release);
    return NULL;
}
static int no_ram(void *opaque, uint64_t address, uint8_t width, uint8_t write, uint64_t *physical) {
    (void)opaque; (void)address; (void)width; (void)write; (void)physical;
    return 0;
}
static int mmio(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Callback *cb = opaque; CHECK(address == 0x100000 && width == 8);
    cb->calls++; *value = 73;
    if (cb->retire) {
        // Reentrancy cannot mutate cached proofs while the outer run is pinned.
        AVZNativeCPU other = initial();
        CHECK(run(cb->f, &other, 8, 8, 8).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
        pthread_t peer; CHECK(!pthread_create(&peer, NULL, invalidate_retiring_chain, cb->f));
        ag_chain_destroy(cb->f->chain); cb->f->chain = NULL;
        CHECK(cb->f->stats.reclamations == 0);
        for (unsigned i = 0; i < 300; i++) {
            AGChain *replacement = ag_chain_create(cb->f->blocks, cb->f->count, &cb->f->guards, NULL);
            CHECK(replacement); ag_chain_destroy(replacement);
        }
        CHECK(!pthread_join(peer, NULL));
        CHECK(cb->f->stats.reclamations == 0);
    }
    atomic_fetch_add(&cb->f->shared[1], 1);
    atomic_store(&cb->f->events, 1);
    return !cb->fail;
}
static void callback_tests(void) {
    for (unsigned indirect = 0; indirect < 2; indirect++)
    for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned retire = 0; retire < 2; retire++)
    for (unsigned budget = 6; budget <= 8; budget++) {
        Fixture f; init(&f, 2, 4); discard_programs(&f);
        memset(&f.stats, 0, sizeof(f.stats));
        f.words[1][1] = 0xf9400140; // ldr x0, [x10]
        if (indirect) f.words[0][3] = 0xd61f0160; // br x11 into the callback block
        compile(&f);
        Callback cb = {&f, 0, fail, retire};
        uint8_t ram[4096] = {0};
        AVZNativeMemoryFastPath *path = avz_native_memory_fast_path_create(ram, 0, sizeof(ram), NULL,
            &cb, no_ram, mmio, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(path);
        AVZNativeCPU c = initial(); c.x[10] = 0x100000; c.x[11] = BASE + 4096;
        AVZNativeBlockResult r = ag_chain_run(f.chain, (AGLimits){budget, budget, 8, &f.events}, &c, path);
        CHECK(cb.calls == 1 && r.steps == (fail ? 5 : 6));
        CHECK(r.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(c.pc == BASE + 4096 + (fail ? 4 : 8) && c.x[0] == (fail ? 4 : 73));
        if (retire) CHECK(f.stats.reclamations == 1 && f.stats.retirements == 1);
        avz_native_memory_fast_path_destroy(path);
        discard_programs(&f); cases++;
    }
}
typedef struct {
    Fixture *fixture;
    unsigned kind;
    _Atomic uint64_t ready;
    uint64_t published;
} Publisher;
static void *publish(void *opaque) {
    Publisher *p = opaque;
    while (!atomic_load_explicit(&p->ready, memory_order_acquire)) { }
    struct timespec delay = {.tv_nsec = 100000}; nanosleep(&delay, NULL);
    p->published = now(CLOCK_MONOTONIC);
    if (!p->kind) {
        atomic_fetch_add(&p->fixture->pages[1], 1);
        atomic_fetch_add(&p->fixture->shared[0], 1);
    } else if (p->kind == 1) atomic_fetch_add(&p->fixture->shared[1], 1);
    else atomic_store_explicit(&p->fixture->events, UINT64_C(1) << (p->kind - 2), memory_order_release);
    return NULL;
}
static void concurrent_tests(void) {
    uint64_t maximum = 0;
    for (unsigned kind = 0; kind < 5; kind++)
    for (unsigned trial = 0; trial < 20; trial++) {
        Fixture f; init(&f, 8, 16);
        Publisher p = {.fixture = &f, .kind = kind}; atomic_init(&p.ready, 0);
        pthread_t thread; CHECK(!pthread_create(&thread, NULL, publish, &p));
        AVZNativeCPU c = initial(), expected = c;
        atomic_store_explicit(&p.ready, 1, memory_order_release);
        AVZNativeBlockResult r = run(&f, &c, UINT64_C(100000000), UINT64_C(100000000), UINT64_MAX);
        uint64_t returned = now(CLOCK_MONOTONIC);
        CHECK(!pthread_join(thread, NULL));
        CHECK(r.status == (kind < 2 ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_YIELDED));
        CHECK(r.steps < UINT64_C(100000000));
        if (kind >= 2) CHECK(r.steps % 16 == 0);
        reference(&f, &expected, r.steps); CHECK(!memcmp(&c, &expected, sizeof(c)));
        uint64_t elapsed = returned - p.published; if (elapsed > maximum) maximum = elapsed;
        discard_programs(&f); CHECK(f.stats.reclamations == 1); cases++;
    }
    printf("phase5 concurrent publication-to-return diagnostic max=%" PRIu64 " ns (host scheduling included)\n", maximum);
}
static void hot_chains(int conditional) {
    Fixture f; init(&f, 2, 4); discard_programs(&f);
    const uint32_t operations[2][3] = {
        {0x0b0d15ad, 0xaa4414c4, 0x8a230042},
        {0x121c08a6, 0x927ef426, 0x9279e13f}};
    const uint32_t conditions[2][3] = {
        {0x9a820020, 0x1a9f1463, 0xda9fb0a4},
        {0xda88a4e6, 0xfa421025, 0x3a5f086a}};
    for (unsigned i = 0; i < 2; i++)
        for (unsigned j = 0; j < 3; j++) f.words[i][j] = conditional ? conditions[i][j] : operations[i][j];
    compile(&f);
    unsigned checked = 0;
    for (unsigned offset = 0; offset < 4; offset++)
    for (uint64_t budget = 1; budget <= 65; budget++)
    for (uint64_t service = 1; service <= 17; service += 4)
    for (uint64_t blocks = 1; blocks <= 4; blocks++) {
        AVZNativeCPU c = initial();
        c.pc += offset * 4; c.x[4] = UINT64_MAX; c.x[9] = 0xabcdef; c.x[13] = 123;
        AVZNativeCPU expected = c;
        uint64_t limit = budget < service ? budget : service;
        uint64_t block_limit = 4 - offset + (blocks - 1) * 4;
        uint64_t retired = limit < block_limit ? limit : block_limit;
        AVZNativeBlockResult r = run(&f, &c, budget, service, blocks);
        CHECK(r.steps == retired && r.generic_dispatches == retired);
        CHECK(r.status == ((service <= budget || block_limit < budget) ?
            AVZ_NATIVE_STATUS_YIELDED : AVZ_NATIVE_STATUS_MAX_STEPS));
        reference(&f, &expected, retired); CHECK(!memcmp(&c, &expected, sizeof(c))); checked++;
    }
    AVZNativeCPU c = initial(), before = c;
    atomic_fetch_add(&f.pages[1], 1); atomic_fetch_add(&f.shared[0], 1);
    AVZNativeBlockResult r = run(&f, &c, 65, 65, 32);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && !r.steps && !memcmp(&c, &before, sizeof(c)));
    discard_programs(&f);
    printf("PASS phase6: %u %s cross-block budget/service/state comparisons and stale-page rejection\n",
        checked, conditional ? "conditional" : "hot-form");
}
static void indirect_chains(void) {
    unsigned checked = 0;
    const unsigned counts[] = {1, 2, 8, 128, 256};
    for (unsigned n = 0; n < 5; n++) {
        Fixture f; init(&f, counts[n], 2); discard_programs(&f);
        for (size_t i = 0; i < f.count; i++) {
            const uint32_t forms[] = {0xd61f0140, 0xd63f0140, 0xd65f0140};
            f.words[i][1] = forms[i % 3]; // BR/BLR/RET x10, always a block terminator.
        }
        compile(&f);
        for (unsigned target = 0; target < f.count; target++)
        for (unsigned offset = 0; offset < 2; offset++)
        for (unsigned budget = 1; budget <= 17; budget += 2)
        for (unsigned blocks = 1; blocks <= 4; blocks++) {
            AVZNativeCPU c = initial(); c.x[10] = f.blocks[target].base + offset * 4;
            AVZNativeCPU expected = c;
            uint64_t service = budget / 2 + 1;
            uint64_t bound = 2 + (blocks - 1) * (2 - offset);
            uint64_t retired = service < bound ? service : bound;
            uint64_t old_entries = f.stats.block_entries;
            AVZNativeBlockResult r = run(&f, &c, budget, service, blocks);
            CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED && r.steps == retired);
            CHECK(f.stats.block_entries - old_entries <= blocks);
            reference(&f, &expected, retired);
            CHECK(!memcmp(&c, &expected, sizeof(c))); checked++;
        }
        const uint64_t misses[] = {0, BASE - 4, BASE + 1, BASE + 8, BASE + 4092, UINT64_MAX};
        for (unsigned i = 0; i < 6; i++) {
            AVZNativeCPU c = initial(); c.x[10] = misses[i];
            AVZNativeBlockResult r = run(&f, &c, 9, 9, 9);
            CHECK(r.steps == 2 && r.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK && c.pc == misses[i]);
            checked++;
        }
        AVZNativeCPU c = initial(), before = c;
        atomic_store(&f.events, 1);
        CHECK(run(&f, &c, 9, 9, 9).steps == 0 && !memcmp(&c, &before, sizeof(c)));
        atomic_store(&f.events, 0);
        atomic_fetch_add(&f.pages[f.count - 1], 1); atomic_fetch_add(&f.shared[0], 1);
        CHECK(run(&f, &c, 9, 9, 9).status == AVZ_TP_STATUS_REVALIDATE && !memcmp(&c, &before, sizeof(c)));
        discard_programs(&f);
    }
    for (unsigned kind = 0; kind < 5; kind++) {
        Fixture f; init(&f, 2, 2); discard_programs(&f);
        f.words[0][1] = 0xd61f0140; f.words[1][1] = 0xd65f0140; compile(&f);
        Publisher p = {.fixture = &f, .kind = kind}; atomic_init(&p.ready, 0);
        pthread_t thread; CHECK(!pthread_create(&thread, NULL, publish, &p));
        AVZNativeCPU c = initial(); c.x[10] = BASE; AVZNativeCPU expected = c;
        atomic_store_explicit(&p.ready, 1, memory_order_release);
        AVZNativeBlockResult r = run(&f, &c, 100000000, 100000000, UINT64_MAX);
        CHECK(!pthread_join(thread, NULL));
        CHECK(r.status == (kind < 2 ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_YIELDED));
        CHECK(r.steps < 100000000);
        if (kind >= 2) CHECK(r.steps % 2 == 0);
        reference(&f, &expected, r.steps); CHECK(!memcmp(&c, &expected, sizeof(c)));
        discard_programs(&f); checked++;
    }
    const uint32_t early[] = {0xd61f0140, 0xd503201f};
    Fixture f; init(&f, 1, 2); discard_programs(&f); f.blocks[0].words = early;
    CHECK(!ag_chain_create(f.blocks, 1, &f.guards, NULL));
    printf("PASS phase6 indirect chains: %u range/interior/gap/service/peer-publication cases; early branch rejection\n", checked);
}
void ag_chain_tests(void) {
    differential(); edge_cases(); callback_tests(); concurrent_tests();
    printf("PASS phase5: %" PRIu64 " chain differential/lifetime/event cases; precise budgets, page-proof reuse, owner reclamation\n", cases);
    hot_chains(0); hot_chains(1); indirect_chains();
}

static void benchmark_run(Fixture *f, AVZNativeCPU *c, uint64_t total, unsigned window, unsigned mode) {
    for (uint64_t done = 0; done < total; done += window) {
        if (mode) {
            AVZNativeBlockResult r = run(f, c, window, window, window / 4);
            CHECK(r.steps == window && r.status == AVZ_NATIVE_STATUS_YIELDED);
        } else {
            for (unsigned n = 0; n < window; n += 4) {
                CHECK(!atomic_load_explicit(&f->events, memory_order_acquire));
                size_t i = (c->pc - BASE) / 4096;
                CHECK(i < f->count);
                AVZNativeBlockResult r = ag_run(f->programs[i], 4, c, &f->guards);
                CHECK(r.steps == 4 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            }
        }
    }
}
static void event_benchmark(void) {
    for (unsigned length = 4; length <= 16; length *= 4) {
        Fixture f; init(&f, 8, length);
        for (unsigned round = 0; round < 101; round++)
        for (unsigned slot = 0; slot < 2; slot++) {
            unsigned mode = (slot + round) % 2;
            atomic_store(&f.events, 0);
            Publisher p = {.fixture = &f, .kind = 2}; atomic_init(&p.ready, 0);
            pthread_t thread; CHECK(!pthread_create(&thread, NULL, publish, &p));
            AVZNativeCPU c = initial(); uint64_t steps = 0;
            atomic_store_explicit(&p.ready, 1, memory_order_release);
            if (mode) {
                AVZNativeBlockResult r = run(&f, &c, 100000000, 100000000, UINT64_MAX);
                CHECK(r.status == AVZ_NATIVE_STATUS_YIELDED); steps = r.steps;
            } else {
                while (!atomic_load_explicit(&f.events, memory_order_acquire)) {
                    size_t i = (c.pc - BASE) / 4096; CHECK(i < f.count);
                    AVZNativeBlockResult r = ag_run(f.programs[i], length, &c, &f.guards);
                    CHECK(r.steps == length && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
                    steps += r.steps; CHECK(steps < 100000000);
                }
            }
            uint64_t returned = now(CLOCK_MONOTONIC); CHECK(!pthread_join(thread, NULL));
            CHECK(steps % length == 0);
            fprintf(stderr, "EVENT,%u,%u,%u,%" PRIu64 ",%" PRIu64 "\n",
                length, round, mode, steps, returned - p.published);
        }
        discard_programs(&f);
    }
}
void ag_chain_benchmark(void) {
    puts("workload,window,round,mode,steps,wall_ns,cpu_ns,prepare_ns,bytes");
    const unsigned counts[] = {2, 8, 32, 128}, windows[] = {4, 64, 256, 4096};
    for (unsigned size = 0; size < 4; size++) {
        Fixture f; init(&f, counts[size], 4); discard_programs(&f);
        for (size_t i = 0; i < f.count; i++) {
            f.words[i][1] = 0x91000c21; // add x1, x1, #3
            f.words[i][2] = 0xca030042; // eor x2, x2, x3
        }
        uint64_t prepare = now(CLOCK_MONOTONIC); compile(&f); prepare = now(CLOCK_MONOTONIC) - prepare;
        size_t bytes[2] = {0, ag_chain_bytes(f.chain)};
        for (size_t i = 0; i < f.count; i++) bytes[0] += ag_program_bytes(f.programs[i]);
        // Disable optional diagnostics in the throughput cohort, identically to the baseline.
        ag_chain_destroy(f.chain); f.chain = ag_chain_create(f.blocks, f.count, &f.guards, NULL); CHECK(f.chain);
        AVZNativeCPU expected = initial();
        expected.x[0] = 1048576 / 4; expected.x[1] = 1048576 / 4 * 3;
        for (unsigned w = 0; w < 4; w++)
        for (unsigned round = 0; round < 15; round++)
        for (unsigned slot = 0; slot < 2; slot++) {
            unsigned mode = (slot + round) % 2;
            AVZNativeCPU c = initial(); benchmark_run(&f, &c, 8192, windows[w], mode);
            c = initial();
            uint64_t ct = now(CLOCK_THREAD_CPUTIME_ID), wt = now(CLOCK_MONOTONIC);
            benchmark_run(&f, &c, 1048576, windows[w], mode);
            wt = now(CLOCK_MONOTONIC) - wt; ct = now(CLOCK_THREAD_CPUTIME_ID) - ct;
            CHECK(!memcmp(&c, &expected, sizeof(c)));
            printf("ring%u,%u,%u,%u,1048576,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%zu\n",
                counts[size], windows[w], round, mode, wt, ct, prepare, bytes[mode]);
        }
        discard_programs(&f);
    }
    event_benchmark();
}
