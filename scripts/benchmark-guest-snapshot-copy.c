/* Build for aarch64 Linux and run inside Pinecone. This isolates copy overhead,
 * not texture allocation, fences, full Phosh responsiveness or host Metal. */
#define _POSIX_C_SOURCE 200809L
#include "rootfs/pinecone-pixel-copy.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static __attribute__((noinline)) size_t copy_rows(int bulk, void *dst, size_t pitch,
    const void *src, size_t stride, size_t bytes, size_t rows)
{
    if (bulk) return pinecone_copy_pixel_rows(dst, pitch, src, stride, bytes, rows);
    for (size_t y = 0; y < rows; ++y)
        memcpy((uint8_t *)dst + y * pitch, (const uint8_t *)src + y * stride, bytes);
    return bytes && rows ? rows : 0;
}

int main(void) {
    const struct { size_t width, height, spad, dpad; } cases[] = {
        {512, 960, 0, 0}, {480, 800, 0, 32}, {64, 64, 0, 0}, {4, 8, 32, 16}
    };
    const int order[] = {0, 1, 1, 0};
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
        size_t bytes = cases[c].width * 4, rows = cases[c].height;
        size_t stride = bytes + cases[c].spad, pitch = bytes + cases[c].dpad;
        uint8_t *src = malloc(stride * rows + 32), *dst = malloc(pitch * rows + 32);
        if (!src || !dst) return 2;
        for (size_t i = 0; i < stride * rows + 32; ++i) src[i] = (uint8_t)(i * 37u + 1u);
        for (unsigned run = 0; run < 4; ++run) {
            memset(dst, 0xa5, pitch * rows + 32);
            uint64_t calls = 0, start = now();
            for (unsigned repeat = 0; repeat < 8; ++repeat)
                calls += copy_rows(order[run], dst + 16, pitch, src + 16, stride, bytes, rows);
            uint64_t elapsed = now() - start;
            unsigned ok = 1;
            for (size_t y = 0; y < rows; ++y) {
                if (memcmp(dst + 16 + y * pitch, src + 16 + y * stride, bytes)) ok = 0;
                for (size_t x = bytes; x < pitch; ++x)
                    if (dst[16 + y * pitch + x] != 0xa5) ok = 0;
            }
            for (unsigned i = 0; i < 16; ++i)
                if (dst[i] != 0xa5 || dst[16 + pitch * rows + i] != 0xa5) ok = 0;
            printf("PINECONE_COPY_BENCH case=%zu run=%u bulk=%d repeats=8 bytes=%zu calls=%llu elapsed_ns=%llu verified=%u\n",
                c, run, order[run], bytes * rows, (unsigned long long)calls,
                (unsigned long long)elapsed, ok);
            fflush(stdout);
            if (!ok) return 3;
        }
        free(dst);
        free(src);
    }
    return 0;
}
