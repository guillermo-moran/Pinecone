#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static size_t cases;
static uint64_t random_bits(uint64_t *seed) {
    *seed ^= *seed << 13; *seed ^= *seed >> 7; *seed ^= *seed << 17; return *seed;
}
static AVZNativeCPU initial_cpu(uint64_t seed) {
    AVZNativeCPU cpu = {.pc = 0x8000, .pstate = 0xa00003c5,
        .fpcr = 0x3c00000, .fpsr = 0x0800009f};
    for (unsigned i = 0; i < 32; i++) {
        cpu.v[i].low = random_bits(&seed);
        cpu.v[i].high = random_bits(&seed);
    }
    return cpu;
}
static void check(const uint32_t *words, size_t count, uint64_t seed) {
    AGProgram *p = ag_create(words, count, 0x8000);
    CHECK(p && ag_program_capabilities(p) == 1);
    AVZNativeInstruction decoded[32];
    CHECK(count <= 32);
    for (size_t i = 0; i < count; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
    for (unsigned entry = 0; entry < count; entry++)
    for (unsigned budget = 0; budget <= count + 1; budget++)
    for (unsigned stale = 0; stale < 2; stale++) {
        AVZNativeCPU actual = initial_cpu(seed);
        actual.pc += entry * 4;
        AVZNativeCPU expected = actual;
        uint64_t epoch = stale;
        AGGuards guards = {.local = &epoch};
        uint64_t before_fpcr, before_fpsr, after_fpcr, after_fpsr;
        __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(before_fpcr), "=r"(before_fpsr));
        AVZNativeBlockResult result = ag_run(p, budget, &actual, &guards);
        __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(after_fpcr), "=r"(after_fpsr));
        CHECK(before_fpcr == after_fpcr && before_fpsr == after_fpsr);
        uint64_t steps = 0;
        while (!stale && steps < budget && expected.pc < 0x8000 + count * 4) {
            CHECK(execute_decoded_instruction(&decoded[(expected.pc - 0x8000) / 4], &expected,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL));
            steps++;
        }
        CHECK(result.steps == steps && !memcmp(&actual, &expected, sizeof(actual)));
        cases++;
    }
    ag_destroy(p);
}
static uint32_t benchmark_code[16];
static int fetch(void *unused, uint64_t pc, uint64_t *physical, uint32_t *word) {
    (void)unused;
    if (pc < 0x8000 || pc >= 0x8040 || (pc & 3)) return 0;
    *physical = pc; *word = benchmark_code[(pc - 0x8000) / 4]; return 1;
}
static uint64_t checkpoint(void *unused, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    (void)unused; (void)steps; (void)blocks; (void)total; (void)pc; (void)pstate;
    return remaining < 4096 ? remaining : 4096;
}
static void benchmark(void) {
    AVZNativeExecutionContext *contexts[2];
    AVZNativeBlockCache *caches[2];
    AVZNativeBlockKey key = {.current_el = 1};
    for (unsigned i = 0; i < 15; i++) benchmark_code[i] = 0x6e201c00 | (2 << 16) | (1 << 5);
    benchmark_code[15] = 0x17fffff1; // branch to first EOR
    for (unsigned enabled = 0; enabled < 2; enabled++) {
        contexts[enabled] = avz_native_execution_context_create();
        caches[enabled] = avz_native_block_cache_create();
        CHECK(contexts[enabled] && caches[enabled]);
        avz_native_execution_context_set_assembly_executor(contexts[enabled], enabled);
    }
    for (unsigned mode = 0; mode < 2; mode++)
    for (unsigned run = 0; run < 10; run++)
    for (unsigned order = 0; order < 2; order++) {
        unsigned enabled = order ^ (run & 1);
        AVZNativeExecutionContext *context = contexts[enabled];
        context->cpu = initial_cpu(0x123456789);
        uint64_t assembly_before = avz_native_execution_context_assembly_statistics(context).steps;
        struct timespec before, after;
        clock_gettime(CLOCK_MONOTONIC, &before);
        AVZNativeChainResult result = {0};
        if (!mode) result = avz_native_execution_context_run_cached_chain_checkpointed(context,
                caches[enabled], &key, 4096, 6000000, 6000000, 64, checkpoint, NULL, fetch, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        else for (unsigned slice = 0; slice < 375000; slice++) {
            AVZNativeChainResult part = avz_native_execution_context_run_cached_chain(context,
                caches[enabled], &key, 16, 1, fetch, NULL,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            CHECK(part.steps == 16 && part.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            result.steps += part.steps; result.status = part.status;
        }
        clock_gettime(CLOCK_MONOTONIC, &after);
        if (result.steps != 6000000 || result.status != AVZ_NATIVE_STATUS_MAX_STEPS)
            fprintf(stderr, "assembly=%u steps=%llu status=%u pc=%llx\n", enabled,
                (unsigned long long)result.steps, result.status, (unsigned long long)context->cpu.pc);
        CHECK(result.steps == 6000000 && result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        AVZNativeCPU initial = initial_cpu(0x123456789);
        CHECK(context->cpu.v[0].low == (initial.v[1].low ^ initial.v[2].low));
        AVZNativeAssemblyStatistics statistics = avz_native_execution_context_assembly_statistics(context);
        CHECK(enabled ? statistics.steps > 0 : statistics.steps == 0);
        if (mode) CHECK(statistics.steps - assembly_before == (enabled ? 6000000 : 0));
        double seconds = after.tv_sec - before.tv_sec + (after.tv_nsec - before.tv_nsec) * 1e-9;
        printf("mode=%s assembly=%u run=%u seconds=%.9f steps=%llu assemblySteps=%llu superblockDispatches=%llu\n",
            mode ? "short" : "checkpointed", enabled, run, seconds, (unsigned long long)result.steps,
            (unsigned long long)(statistics.steps - assembly_before),
            (unsigned long long)result.superblock_dispatches);
    }
    for (unsigned i = 0; i < 2; i++) {
        avz_native_execution_context_destroy(contexts[i]); avz_native_block_cache_destroy(caches[i]);
    }
}
int main(void) {
    const uint32_t operations[] = {0x0ea01c00, 0x2e201c00, 0x2e601c00, 0x2ea01c00,
        0x2ee01c00, 0x0e201c00, 0x0e601c00, 0x0ee01c00, 0x2e205800};
    const unsigned regs[] = {0, 1, 31};
    for (unsigned q = 0; q < 2; q++)
    for (unsigned operation = 0; operation < 9; operation++)
    for (unsigned rd = 0; rd < 3; rd++)
    for (unsigned rn = 0; rn < 3; rn++)
    for (unsigned rm = 0; rm < (operation == 8 ? 1u : 3u); rm++)
    for (unsigned seed = 0; seed < 16; seed++) {
        uint32_t word = operations[operation] | (q << 30) | regs[rd] | (regs[rn] << 5) |
            (operation == 8 ? 0 : regs[rm] << 16);
        check(&word, 1, seed * UINT64_C(0x9e3779b97f4a7c15));
    }
    uint32_t mixed[9];
    for (unsigned i = 0; i < 9; i++) mixed[i] = operations[i] | ((i & 1) << 30) |
        (i % 3) | (((i + 1) % 3) << 5) | (i == 8 ? 0 : ((i + 2) % 3) << 16);
    check(mixed, 9, UINT64_C(0x12345678));
    printf("assembly SIMD logic: %zu differential cases passed; host FPCR/FPSR preserved\n", cases);
    if (getenv("PINECONE_BENCHMARK_SIMD")) benchmark();
    return 0;
}
