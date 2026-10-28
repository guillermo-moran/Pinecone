#include "ARM64VizNative.h"
#include <dlfcn.h>
#include <pixman.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef __typeof__(&avz_framebuffer_bilinear_scale_copy_bgra8) raster_fn;
static unsigned cases;
static uint32_t random_state = 0x61c88647;

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s (case %u)\n", message, cases); exit(1); }
}

static void seed(uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        bytes[i] = (uint8_t)random_state;
    }
}

static raster_fn function(unsigned over) {
    return over ? avz_framebuffer_bilinear_scale_source_over_bgra8
                : avz_framebuffer_bilinear_scale_copy_bgra8;
}

static void differential(raster_fn reference[2]) {
    enum { STRIDE = 336, HEIGHT = 12, BYTES = STRIDE * HEIGHT + 64 };
    uint8_t source[BYTES], actual[BYTES], expected[BYTES], before[BYTES];
    const unsigned widths[] = {1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 65};
    for (unsigned over = 0; over < 2; over++) {
        for (unsigned alpha = 0; alpha < 256; alpha++) {
            for (unsigned i = 0; i < sizeof(widths) / sizeof(widths[0]); i++) {
                const unsigned width = widths[i], alignment = alpha % 16;
                seed(source, BYTES);
                seed(actual, BYTES);
                // Include non-premultiplied channels: saturation must remain exact.
                for (unsigned y = 0; y < 8; y++)
                    for (unsigned x = 0; x < 75; x++)
                        source[alignment + y * STRIDE + x * 4 + 3] = alpha;
                memcpy(before, source, BYTES);
                memcpy(expected, actual, BYTES);
                require(function(over)(source + alignment, STRIDE, 2, 1, width, 4,
                    actual + alignment, STRIDE, 3, 2, width, 4), "identity rejected");
                require(avz_framebuffer_composite_bgra8(source + alignment,
                    STRIDE, 2, 1, width, 4, NULL, 0, 255,
                    expected + alignment, STRIDE, 3, 2, width, 4,
                    0, over ? 3 : 1, 0, 1, 0, 0, 0, 0), "oracle rejected");
                cases++;
                require(!memcmp(actual, expected, BYTES), "identity/canary mismatch");
                require(!memcmp(source, before, BYTES), "source changed");
            }
        }
        // Nonidentity transforms, including a change in only one dimension.
        for (unsigned sw = 1; sw <= 19; sw++) {
            for (unsigned sh = 1; sh <= 7; sh++) {
                seed(source, BYTES); seed(actual, BYTES);
                memcpy(expected, actual, BYTES);
                require(function(over)(source, STRIDE, 1, 1, sw, sh,
                    actual, STRIDE, 2, 2, 13, 5), "scale rejected");
                require(avz_framebuffer_composite_bgra8(source, STRIDE, 1, 1,
                    sw, sh, NULL, 0, 255, expected, STRIDE, 2, 2, 13, 5,
                    0, over ? 3 : 1, 0, 1, 0, 0, 0, 0), "scale oracle rejected");
                cases++;
                require(!memcmp(actual, expected, BYTES), "scaled pixels changed");
            }
        }
        // Forward/backward overlapping spans must retain sequential semantics.
        for (unsigned offset = 0; offset < 32; offset++) {
            for (unsigned reverse = 0; reverse < 2; reverse++) {
                seed(actual, BYTES); memcpy(expected, actual, BYTES);
                unsigned s = reverse ? offset : 0, d = reverse ? 0 : offset;
                require(function(over)(actual + s, STRIDE, 0, 0, 33, 3,
                    actual + d, STRIDE, 0, 0, 33, 3), "alias rejected");
                require(avz_framebuffer_composite_bgra8(expected + s, STRIDE,
                    0, 0, 33, 3, NULL, 0, 255, expected + d, STRIDE,
                    0, 0, 33, 3, 0, over ? 3 : 1, 0, 1, 0, 0, 0, 0), "alias oracle rejected");
                cases++;
                require(!memcmp(actual, expected, BYTES), "alias semantics changed");
            }
        }
        for (unsigned error = 0; error < 5; error++) {
            seed(actual, BYTES); memcpy(expected, actual, BYTES);
            int result = function(over)(error == 0 ? NULL : source,
                STRIDE, error == 1 ? SIZE_MAX : 0, 0, error == 2 ? 0 : 33, 3,
                actual, error == 3 ? 4 : STRIDE, 0,
                error == 4 ? SIZE_MAX : 0, 33, 3);
            cases++;
            require(!result && !memcmp(actual, expected, BYTES), "error modified output");
        }
        if (reference[over]) {
            for (unsigned i = 0; i < 256; i++) {
                seed(source, BYTES); seed(actual, BYTES);
                memcpy(expected, actual, BYTES);
                const unsigned width = 1 + i % 65, sh = 1 + i % 5;
                require(function(over)(source, STRIDE, 1, 1, width, sh,
                    actual, STRIDE, 2, 2, width, 4), "baseline case rejected");
                require(reference[over](source, STRIDE, 1, 1, width, sh,
                    expected, STRIDE, 2, 2, width, 4), "baseline rejected");
                cases++;
                require(!memcmp(actual, expected, BYTES), "captured baseline mismatch");
            }
        }
    }
}

static void pixman_identity(void) {
    enum { W = 67, H = 7, STRIDE = 288, BYTES = STRIDE * H };
    uint32_t source[BYTES / 4], actual[BYTES / 4], expected[BYTES / 4];
    for (unsigned over = 0; over < 2; over++) {
        for (unsigned alpha = 0; alpha < 256; alpha++) {
            for (unsigned i = 0; i < BYTES / 4; i++) {
                source[i] = alpha << 24 | (i % (alpha + 1)) * 0x010101;
                actual[i] = 0xc0804020;
            }
            memcpy(expected, actual, BYTES);
            pixman_image_t *src = pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, source, STRIDE);
            pixman_image_t *dst = pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, expected, STRIDE);
            require(src && dst, "Pixman allocation failed");
            require(pixman_image_set_filter(src, PIXMAN_FILTER_BILINEAR, NULL, 0), "filter failed");
            pixman_image_composite32(over ? PIXMAN_OP_OVER : PIXMAN_OP_SRC,
                src, NULL, dst, 1, 1, 0, 0, 2, 2, 63, 4);
            require(function(over)((uint8_t *)source, STRIDE, 1, 1, 63, 4,
                (uint8_t *)actual, STRIDE, 2, 2, 63, 4), "Pixman case rejected");
            cases++;
            require(!memcmp(actual, expected, BYTES), "Pixman mismatch");
            pixman_image_unref(src); pixman_image_unref(dst);
        }
    }
}

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec * 1e-9;
}

static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void benchmark(raster_fn reference[2]) {
    const unsigned sizes[][2] = {{64, 32}, {128, 128}, {400, 480}, {800, 960}};
    for (unsigned over = 0; over < 2; over++) {
        if (!reference[over]) continue;
        for (unsigned i = 0; i < 4; i++) {
            unsigned w = sizes[i][0], h = sizes[i][1];
            size_t count = (size_t)w * h * 4;
            uint8_t *src = malloc(count), *dst = malloc(count);
            require(src && dst, "benchmark allocation failed");
            seed(src, count); seed(dst, count);
            unsigned iterations = 4000000 / (w * h) + 3;
            double times[2][9];
            raster_fn functions[] = {reference[over], function(over)};
            for (unsigned round = 0; round < 9; round++) {
                for (unsigned order = 0; order < 2; order++) {
                    unsigned version = (order + round) % 2;
                    double start = now();
                    for (unsigned n = 0; n < iterations; n++)
                        require(functions[version](src, w * 4, 0, 0, w, h,
                            dst, w * 4, 0, 0, w, h), "benchmark rejected");
                    times[version][round] = (now() - start) * 1e6 / iterations;
                }
            }
            qsort(times[0], 9, sizeof(double), compare_double);
            qsort(times[1], 9, sizeof(double), compare_double);
            printf("%s %ux%u baseline_us=%.3f optimized_us=%.3f speedup=%.2f rounds=9 iterations=%u\n",
                over ? "OVER" : "SRC", w, h, times[0][4], times[1][4],
                times[0][4] / times[1][4], iterations);
            free(src); free(dst);
        }
    }
}

int main(int argc, char **argv) {
    raster_fn reference[2] = {NULL, NULL};
    void *library = NULL;
    if (argc == 2) {
        library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library != NULL, "baseline library unavailable");
        reference[0] = (raster_fn)dlsym(library, "avz_framebuffer_bilinear_scale_copy_bgra8");
        reference[1] = (raster_fn)dlsym(library, "avz_framebuffer_bilinear_scale_source_over_bgra8");
        require(reference[0] && reference[1], "baseline symbols missing");
    }
    differential(reference);
    pixman_identity();
    printf("graphics identity: %u exact cases passed (full buffers/canaries, alpha, scaling, aliases, errors)\n", cases);
    benchmark(reference);
    if (library) dlclose(library);
    return 0;
}
