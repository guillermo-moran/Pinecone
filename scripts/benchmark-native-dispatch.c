#define _POSIX_C_SOURCE 200809L
#include "ARM64VizNative.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int simd_workload;

static int fetch(void *unused, uint64_t pc, uint64_t *physical, uint32_t *raw)
{
    (void)unused;
    static const uint32_t code[] = {0x91000400, 0xf100001f, 0x54ffffc1};
    static const uint32_t simd_code[] = {0x4e010c00, 0x91000400, 0x17fffffe};
    if (pc < 0x8000 || pc >= 0x800c || (pc & 3)) return 0;
    *raw = (simd_workload ? simd_code : code)[(pc - 0x8000) / 4];
    *physical = pc;
    return 1;
}

static double seconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "broadcasts") != 0)) {
        fprintf(stderr, "usage: %s [broadcasts]\n", argv[0]);
        return EXIT_FAILURE;
    }
    simd_workload = argc > 1;
    AVZNativeBlockCache *cache = avz_native_block_cache_create();
    AVZNativeExecutionContext *context = avz_native_execution_context_create();
    if (!cache || !context) {
        fputs("native context allocation failed\n", stderr);
        if (context) avz_native_execution_context_destroy(context);
        if (cache) avz_native_block_cache_destroy(cache);
        return EXIT_FAILURE;
    }
    AVZNativeBlockKey key = {.current_el = 1};
    for (unsigned run = 0; run < 5; run++) {
        uint64_t x[31] = {0};
        avz_native_execution_context_load(context, x, NULL, NULL,
                                         0, 0x8000, 5, 0, 0, 0, 0, 0, 0);
        double start = seconds();
        AVZNativeChainResult result = avz_native_execution_context_run_cached_chain(
            context, cache, &key, 30000000, 10000000, fetch, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        double elapsed = seconds() - start;
        if (result.steps != 30000000) {
            fprintf(stderr, "incomplete execution: steps=%" PRIu64 "\n", result.steps);
            avz_native_execution_context_destroy(context);
            avz_native_block_cache_destroy(cache);
            return EXIT_FAILURE;
        }
        printf("run=%u steps=%" PRIu64 " seconds=%.6f mips=%.3f\n",
               run, result.steps, elapsed, result.steps / elapsed / 1e6);
    }
    avz_native_execution_context_destroy(context);
    avz_native_block_cache_destroy(cache);
    return 0;
}
