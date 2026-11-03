#include <stdio.h>
#include <time.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/aot_runtime.h"
#include "../Sources/ARM64VizNative/include/ARM64VizAOT.h"
/* Enumerate the exact generated corpus; functions are independently compared
 * against the authoritative decoded C executor, not against the generator. */
#ifndef AG_AOT_GENERATED_INCLUDE
#define AG_AOT_GENERATED_INCLUDE "../Sources/ARM64VizNative/Assembly/aot_generated.inc"
#endif
#include AG_AOT_GENERATED_INCLUDE

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "AOT line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static uint64_t random_state = 0x17beef;
static uint64_t random64(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}
static AVZNativeCPU seed(uint64_t base) {
    AVZNativeCPU c = {.pc = base, .sp = random64(), .pstate = random64(),
        .fpcr = random64(), .fpsr = random64(), .exclusive_valid = 1};
    for (unsigned i = 0; i < 31; i++) c.x[i] = random64();
    for (unsigned i = 0; i < 32; i++) c.v[i] = (AVZNativeVectorRegister){random64(), random64()};
    return c;
}
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
typedef struct {
    AVZGuestMemory *ram;
    unsigned fail;
    AGProgram *retire_on_read;
    unsigned reads;
} PrefixMemory;
static int prefix_device_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    PrefixMemory *m = opaque;
    CHECK(address == 0x10000 && width == 8);
    CHECK(m->retire_on_read && m->retire_on_read->active_runs == 1);
    AGProgram *retired = m->retire_on_read;
    m->retire_on_read = NULL;
    m->reads++;
    ag_destroy(retired);
    *value = 42;
    return 1;
}
static int prefix_translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    PrefixMemory *m = opaque;
    (void)write;
    if (m->fail || address > 4096u - width) return 0;
    *physical = address;
    return 1;
}
static void prefix_memory_cases(void) {
    /* An exact native prefix followed by a RAM load and store must execute in
     * the same pinned program with the remaining budget, preserving all fault
     * and writeback semantics of the original assembly memory continuation. */
    uint32_t words[] = {0x91000400, 0xd503201f, 0xf9400022, 0xf9000422};
    PrefixMemory m = {.ram = avz_guest_memory_create(4096)};
    CHECK(m.ram);
    for (unsigned budget = 0; budget <= 5; budget++)
    for (unsigned failure = 0; failure < 2; failure++) {
        AVZNativeCPU original = seed(0x8000);
        original.x[1] = failure ? 0x10000 : 0x100;
        AVZNativeCPU actual = original, reference = original;
        AVZNativeBlockResult results[2];
        unsigned char final_bytes[2][4096];
        for (unsigned mode = 0; mode < 2; mode++) {
            memset(avz_guest_memory_bytes(m.ram), 0, 4096);
            uint64_t value = UINT64_C(0xabc0123456789def);
            memcpy(avz_guest_memory_bytes(m.ram) + 0x100, &value, 8);
            AVZNativeMemoryFastPath *path = avz_native_memory_fast_path_create(
                avz_guest_memory_bytes(m.ram), 0, 4096, NULL, &m,
                prefix_translate, NULL, NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, NULL, NULL);
            CHECK(path && avz_native_memory_fast_path_set_guest_memory(path, m.ram));
            avz_native_memory_fast_path_set_detailed_statistics_enabled(path, 0);
            AGProgram *p = ag_create(words, 4, 0x8000);
            CHECK(p && p->aot && p->aot->count == 2);
            if (!mode) p->aot = NULL;
            results[mode] = ag_run_memory(p, budget, mode ? &actual : &reference, NULL, path);
            memcpy(final_bytes[mode], avz_guest_memory_bytes(m.ram), 4096);
            ag_destroy(p);
            avz_native_memory_fast_path_destroy(path);
        }
        CHECK(results[0].steps == results[1].steps);
        CHECK(results[0].status == results[1].status);
        CHECK(!memcmp(&actual, &reference, sizeof(actual)));
        CHECK(!memcmp(final_bytes[0], final_bytes[1], 4096));
    }
    /* A slow memory callback can retire the pinned mixed program. It must not
     * free the native/assembly continuation before the terminal helper returns. */
    AVZNativeCPU actual = seed(0x8000), reference = actual;
    actual.x[1] = reference.x[1] = 0x10000;
    AVZNativeBlockResult results[2];
    for (unsigned mode = 0; mode < 2; mode++) {
        AVZNativeMemoryFastPath *path = avz_native_memory_fast_path_create(
            avz_guest_memory_bytes(m.ram), 0, 4096, NULL, &m,
            prefix_translate, prefix_device_read, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL);
        CHECK(path && avz_native_memory_fast_path_set_guest_memory(path, m.ram));
        AGProgram *p = ag_create(words, 4, 0x8000);
        CHECK(p && p->aot);
        if (!mode) p->aot = NULL;
        m.retire_on_read = p;
        results[mode] = ag_run_memory(p, 4, mode ? &actual : &reference, NULL, path);
        CHECK(!m.retire_on_read);
        avz_native_memory_fast_path_destroy(path);
    }
    CHECK(m.reads == 2 && results[0].steps == 3 && results[1].steps == 3);
    CHECK(results[0].status == results[1].status);
    CHECK(!memcmp(&actual, &reference, sizeof(actual)));
    avz_guest_memory_destroy(m.ram);
    puts("AOT native prefix plus assembly memory tail: matched CPU/RAM, budgets and faults");
}
int main(void) {
    CHECK(!setenv("PINECONE_AOT", "1", 1));
    size_t cases = 0, native_only_cases = 0, span_cases = 0;
    for (size_t b = 0; b < AG_AOT_BLOCK_COUNT; b++) {
        const AGAOTBlock *block = &ag_aot_blocks[b];
        CHECK(block->run_span);
        for (unsigned span = 0; span < 2; span++) {
        for (unsigned relocate = 0; relocate < 4; relocate++) {
            uint64_t base = (relocate & 1 ? UINT64_C(0xffff800012340000) : 0x8000) +
                (relocate & 2 ? 4092 : 0);
            AGProgram *p = ag_create(block->words, block->count, base);
            CHECK(p && p->aot);
            int assembly_eligible = ag_program_capabilities(p) == 1;
            for (unsigned sample = 0; sample < 64; sample++)
            for (size_t budget = 0; budget <= block->count + 1; budget++) {
                AVZNativeCPU actual = seed(base);
                const uint64_t edges[] = {0, 1, UINT64_MAX, UINT32_MAX,
                    UINT64_C(0x80000000), UINT64_C(0x7fffffff),
                    UINT64_C(0x8000000000000000), UINT64_C(0x7fffffffffffffff)};
                if (sample < sizeof(edges) / sizeof(*edges)) {
                    actual.sp = edges[sample];
                    for (unsigned i = 0; i < 31; i++) actual.x[i] = edges[sample];
                }
                AVZNativeCPU expected = actual;
                uint64_t expected_steps = budget < block->count ? budget : block->count;
                AVZNativeBlockResult r;
                if (assembly_eligible && !span) r = ag_run(p, budget, &actual, NULL);
                else {
                    /* Test native semantics even for instructions currently
                     * rejected by the assembly VM eligibility gate. These are
                     * not counted as production AOT coverage. */
                    AGRun run = {.cpu = &actual, .budget = budget};
                    (span ? block->run_span : block->run)(&run, base);
                    r = run.result;
                    CHECK(run.budget == budget - r.steps);
                    native_only_cases += !assembly_eligible;
                    span_cases += span;
                }
                for (size_t i = 0; i < expected_steps; i++) {
                    AVZNativeInstruction d;
                    CHECK(avz_native_decode_instruction(block->words[i], &d));
                    CHECK(execute_decoded_instruction(&d, &expected, NULL, NULL, NULL,
                        NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL));
                }
                CHECK(r.steps == expected_steps);
                CHECK(r.generic_dispatches == expected_steps);
                CHECK(!memcmp(&actual, &expected, sizeof(actual)));
                CHECK(r.status == (budget <= block->count ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_OUTSIDE_BLOCK));
                /* Resume a partially executed AOT block through assembly. */
                if (!span && assembly_eligible && budget && budget < block->count) {
                    AGProgram *q = ag_create(block->words, block->count, base);
                    CHECK(q);
                    q->aot = NULL;
                    AVZNativeCPU reference = actual;
                    AVZNativeBlockResult resumed = ag_run(p, block->count - budget, &actual, NULL);
                    AVZNativeBlockResult interpreted = ag_run(q, block->count - budget, &reference, NULL);
                    CHECK(resumed.steps == interpreted.steps && resumed.status == interpreted.status);
                    CHECK(!memcmp(&actual, &reference, sizeof(actual)));
                    ag_destroy(q);
                }
                cases++;
            }
            /* All guard slots reject stale code before any guest mutation. */
            for (unsigned slot = 0; slot < 4; slot++) {
                uint64_t local = 1;
                _Atomic uint64_t shared = 1;
                AGGuards g = {0};
                if (slot == 0) g.local = &local;
                else g.shared[slot - 1] = &shared;
                AVZNativeCPU actual = seed(base), original = actual;
                AVZNativeBlockResult r;
                if (assembly_eligible && !span) r = ag_run(p, 16, &actual, &g);
                else {
                    AGRun run = {.cpu = &actual, .budget = 16, .guards = g};
                    (span ? block->run_span : block->run)(&run, base);
                    r = run.result;
                }
                CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 0);
                CHECK(!memcmp(&actual, &original, sizeof(actual)));
            }
            ag_destroy(p);
        }
        }
    }
    /* Changed bytes must miss even with the same PC and instruction count. */
    uint32_t changed[] = {0xffffffff, 0xd503201f};
    AGProgram *changed_program = ag_create(changed, 2, 0x8000);
    CHECK(changed_program);
    CHECK(!ag_aot_find(changed, 2));
    ag_destroy(changed_program);
    /* Model a coherence token becoming stale during a pure span without a
     * helper/thread timing dependency: ADD writes its own local proof token.
     * The copied-span contract permits finishing that prefix, then must reject
     * even when the final retirement also exhausts the instruction budget. */
    uint32_t span_words[] = {0x91000400, 0xd503201f};
    const AGAOTBlock *span_block = ag_aot_find(span_words, 2);
    CHECK(span_block && span_block->count == 2 && span_block->run_span);
    for (uint64_t budget = 0; budget < 4; budget++) {
        AVZNativeCPU c = {.pc = 0x8000};
        AGRun run = {.cpu = &c, .budget = budget, .guards = {.local = &c.x[0]}};
        span_block->run_span(&run, 0x8000);
        uint64_t retired = budget < 2 ? budget : 2;
        CHECK(run.result.steps == retired && run.budget == budget - retired);
        CHECK(run.result.status == (budget ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS));
        CHECK(c.pc == 0x8000 + retired * 4 && c.x[0] == !!budget);
    }
    prefix_memory_cases();
    CHECK(!setenv("PINECONE_AOT", "0", 1));
    CHECK(!ag_aot_find(ag_aot_blocks[0].words, ag_aot_blocks[0].count));
    CHECK(!setenv("PINECONE_AOT", "1", 1));
    /* Independent memory proofs must be honored even by register-only AOT. */
    AVZGuestMemory *memory = avz_guest_memory_create(4096);
    CHECK(memory);
    for (unsigned slot = 0; slot < 2; slot++) {
        AVZNativeCPU c = seed(0x8000), original = c;
        AGRun run = {.cpu = &c, .budget = 16};
        run.memory.shared = memory;
        run.memory.translation_epoch = atomic_load(&memory->translation_epoch);
        run.memory.code_epoch = atomic_load(&memory->code_mutation_epoch);
        if (slot) run.memory.code_epoch++;
        else run.memory.translation_epoch++;
        ag_aot_blocks[0].run(&run, 0x8000);
        CHECK(run.result.status == AVZ_TP_STATUS_REVALIDATE && !run.result.steps);
        CHECK(!memcmp(&c, &original, sizeof(c)));
    }
    avz_guest_memory_destroy(memory);
    AVZNativeAOTStatistics stats = avz_native_aot_statistics();
    CHECK(stats.compiled_blocks == AG_AOT_BLOCK_COUNT && stats.runs && stats.steps);
    printf("AOT: %zu randomized differential cases passed (%zu without assembly eligibility; %zu direct span-entry cases); relocation, partial budgets, guards, fallback checked\n", cases, native_only_cases, span_cases);

    /* Tiny matched dispatch benchmark; not an Android boot-speed claim. */
    uint32_t words[] = {0x91000400, 0xd503201f};
    AGProgram *p = ag_create(words, 2, 0x8000);
    CHECK(p && p->aot);
    const AGAOTBlock *compiled = p->aot;
    for (unsigned cohort = 0; cohort < 4; cohort++) {
        p->aot = cohort & 1 ? compiled : NULL;
        AVZNativeCPU c = {.pc = 0x8000};
        double start = now();
        for (unsigned i = 0; i < 1000000; i++) {
            c.pc = 0x8000;
            AVZNativeBlockResult r = ag_run(p, 2, &c, NULL);
            CHECK(r.steps == 2);
        }
        printf("%s: %.3f ms, x0=%llu\n", p->aot ? "AOT" : "assembly", (now() - start) * 1000,
            (unsigned long long)c.x[0]);
    }
    ag_destroy(p);
    return 0;
}
