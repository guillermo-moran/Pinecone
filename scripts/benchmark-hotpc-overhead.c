#define _POSIX_C_SOURCE 200809L
#include "ARM64VizNative.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int fetch(void *unused, uint64_t pc, uint64_t *physical, uint32_t *raw) {
    if (unused) {
        static const uint32_t dispatch[] = {
            0x91000400, 0x92401401, 0x100007c2, 0x8b011042, 0xd61f0040
        };
        if (pc >= 0x8000 && pc < 0x8014 && !(pc & 3)) {
            *physical = pc; *raw = dispatch[(pc - 0x8000) / 4]; return 1;
        }
        if (pc >= 0x8100 && pc < 0x8500 && (pc & 15) <= 4 && !(pc & 3)) {
            *physical = pc;
            *raw = (pc & 15) == 0 ? 0x91000463
                : 0x14000000u | ((uint32_t)((0x8000 - (int64_t)pc) >> 2) & 0x03ffffffu);
            return 1;
        }
        return 0;
    }
    static const uint32_t code[] = {0x91000400, 0xf100001f, 0x54ffffc1};
    if (pc < 0x8000 || pc >= 0x800c || (pc & 3)) return 0;
    *physical = pc; *raw = code[(pc - 0x8000) / 4]; return 1;
}
static uint64_t checkpoint(void *unused, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    (void)unused; (void)steps; (void)blocks; (void)total; (void)pc; (void)pstate;
    return remaining < 4096 ? remaining : 4096;
}
static double seconds(void) {
    struct timespec ts; assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
int main(int argc, char **argv) {
    int profile = argc >= 2 ? atoi(argv[1]) : 0;
    int branchy = argc >= 3 ? atoi(argv[2]) : 0;
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    assert(cache && context);
    avz_native_execution_context_set_hot_pc_profiling(context, profile);
    AVZNativeBlockKey key = {.current_el = 1};
    for (unsigned run = 0; run < 9; ++run) {
        uint64_t x[31] = {0};
        avz_native_execution_context_load(context, x, NULL, NULL,
            0, 0x8000, 5, 0, 0, 0, 0, 0, 0);
        double start = seconds();
        AVZNativeChainResult r = avz_native_execution_context_run_cached_chain_checkpointed(
            context, cache, &key, 4096, 6000000, 6000000, 64,
            checkpoint, NULL, fetch, branchy ? (void *)(uintptr_t)1 : NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        double elapsed = seconds() - start;
        assert(r.steps == 6000000 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        uint64_t sp, pc, pstate;
        uint8_t halted;
        avz_native_execution_context_store(context, x, NULL, NULL, &sp, &pc,
            &pstate, NULL, NULL, NULL, NULL, NULL, &halted);
        if (x[0] != (branchy ? 857143u : 2000000u))
            fprintf(stderr, "unexpected x0=%llu x3=%llu pc=%llx steps=%llu\n",
                (unsigned long long)x[0], (unsigned long long)x[3],
                (unsigned long long)avz_native_execution_context_pc(context),
                (unsigned long long)r.steps);
        assert(x[0] == (branchy ? 857143u : 2000000u));
        if (branchy) assert(x[3] == 857143u);
        printf("profile=%d run=%u steps=%llu seconds=%.9f mips=%.3f pattern=%s\n",
            profile, run, (unsigned long long)r.steps, elapsed, r.steps / elapsed / 1e6,
            branchy ? "indirect" : "loop");
    }
    AVZNativeHotPC samples[8];
    size_t count = avz_native_execution_context_copy_hot_pcs(context, samples, 8);
    assert(profile ? count > 0 : count == 0);
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(cache);
    return 0;
}
