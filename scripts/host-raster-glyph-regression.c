#include "ARM64VizNative.h"

#include <dlfcn.h>
#include <pixman.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { STRIDE = 320, HEIGHT = 8, BYTES = STRIDE * HEIGHT };
typedef __typeof__(&avz_framebuffer_composite_bgra8) composite_fn;
static unsigned cases;

static uint8_t multiply(uint8_t a, uint8_t b) {
    const unsigned product = a * b + 128u;
    return (uint8_t)((product + (product >> 8u)) >> 8u);
}

static void scalar(const uint8_t *mask, size_t mask_stride, uint8_t *dst,
                   size_t stride, size_t dx, size_t dy, size_t w, size_t h,
                   uint32_t color) {
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            const uint8_t alpha = mask[y * mask_stride + x];
            const uint8_t inverse = 255u - multiply(color >> 24u, alpha);
            uint8_t *pixel = dst + (dy + y) * stride + (dx + x) * 4u;
            for (size_t c = 0; c < 4; c++) {
                const unsigned value = multiply(color >> (c * 8u), alpha) +
                    multiply(pixel[c], inverse);
                pixel[c] = value > 255u ? 255u : value;
            }
        }
    }
}

static int draw(composite_fn fn, const uint8_t *mask, size_t mask_stride,
                uint8_t *dst, size_t stride, size_t dx, size_t dy,
                size_t w, size_t h, uint32_t color, int component) {
    return fn(NULL, 0, 0, 0, 0, 0, mask, mask_stride, 37,
              dst, stride, dx, dy, w, h, color, 3, 1, 0,
              component, 1, 0, 0);
}

static void check(const uint8_t *actual, const uint8_t *expected, size_t size,
                  const char *name) {
    cases++;
    if (memcmp(actual, expected, size) != 0) {
        fprintf(stderr, "%s mismatch case %u\n", name, cases);
        exit(1);
    }
}

static void regression(void) {
    uint8_t actual[BYTES + 32], expected[BYTES + 32], mask[BYTES + 32];
    for (unsigned alpha = 0; alpha < 256; alpha++) {
        const uint32_t color = alpha << 24u | (alpha / 2u) << 16u |
            (alpha / 3u) << 8u | alpha;
        for (unsigned coverage = 0; coverage < 256; coverage++) {
            memset(actual, 0xa5, sizeof(actual));
            memcpy(expected, actual, sizeof(actual));
            for (unsigned x = 0; x < 8; x++) mask[x] = coverage + x;
            scalar(mask, STRIDE, expected, STRIDE, 1, 1, 8, 1, color);
            if (!draw(avz_framebuffer_composite_bgra8, mask, STRIDE,
                      actual, STRIDE, 1, 1, 8, 1, color, 0)) exit(2);
            check(actual, expected, sizeof(actual), "all-alpha lanes");
        }
    }
    // All byte alignments, non-vector tails, clipped subrectangles, padding,
    // and non-premultiplied inputs (saturation is still specified).
    for (unsigned alignment = 0; alignment < 16; alignment++) {
        for (unsigned width = 1; width <= 65; width++) {
            for (unsigned i = 0; i < sizeof(actual); i++) {
                actual[i] = (i * 67u + width) & 255u;
                mask[i] = (i * 43u + alignment) & 255u;
            }
            memcpy(expected, actual, sizeof(actual));
            scalar(mask + alignment, STRIDE, expected + alignment,
                   STRIDE, 3, 1, width, 4, 0x80f17299);
            if (!draw(avz_framebuffer_composite_bgra8, mask + alignment, STRIDE,
                      actual + alignment, STRIDE, 3, 1, width, 4,
                      0x80f17299, 0)) exit(2);
            check(actual, expected, sizeof(actual), "unaligned tails/canaries");
        }
    }
    // The generic path has sequential alias semantics, not a snapshot. An
    // overlapping mask must never enter the vector path.
    for (unsigned offset = 0; offset < 32; offset++) {
        for (unsigned i = 0; i < sizeof(actual); i++) actual[i] = i * 31u;
        memcpy(expected, actual, sizeof(actual));
        scalar(expected + offset, STRIDE, expected, STRIDE, 0, 0, 33, 3, 0x80402010);
        if (!draw(avz_framebuffer_composite_bgra8, actual + offset, STRIDE,
                  actual, STRIDE, 0, 0, 33, 3, 0x80402010, 0)) exit(2);
        check(actual, expected, sizeof(actual), "mask/destination alias");
    }
    // Independent Pixman differential, including zero/full/partial alpha,
    // source color channels, packed mask rows and tails. The packed-A8 plus
    // component-alpha flag combination is not emitted by the guest bridge;
    // check its existing scalar semantics separately, not Pixman's CA-A8 rules.
    const uint32_t colors[] = {0, 0xff000000, 0xffffffff, 0x80402010, 0x01010001};
    for (unsigned color_index = 0; color_index < sizeof(colors) / sizeof(colors[0]); color_index++) {
        for (unsigned width = 1; width <= 65; width++) {
            for (int component = 0; component <= 1; component++) {
                uint32_t color = colors[color_index];
                for (unsigned i = 0; i < sizeof(actual); i++) {
                    actual[i] = i * 17u;
                    mask[i] = i * 19u;
                }
                memcpy(expected, actual, sizeof(actual));
                pixman_image_t *src = pixman_image_create_bits(PIXMAN_a8r8g8b8, 1, 1, &color, 4);
                pixman_image_set_repeat(src, PIXMAN_REPEAT_NORMAL);
                pixman_image_t *msk = pixman_image_create_bits(PIXMAN_a8, 80, HEIGHT, (uint32_t *)mask, STRIDE);
                pixman_image_t *dst = pixman_image_create_bits(PIXMAN_a8r8g8b8, 80, HEIGHT, (uint32_t *)expected, STRIDE);
                if (!src || !msk || !dst) exit(2);
                if (component)
                    scalar(mask, STRIDE, expected, STRIDE, 3, 1, width, 4, color);
                else
                    pixman_image_composite32(PIXMAN_OP_OVER, src, msk, dst, 0, 0, 0, 0, 3, 1, width, 4);
                if (!draw(avz_framebuffer_composite_bgra8, mask, STRIDE, actual,
                          STRIDE, 3, 1, width, 4, color, component)) exit(2);
                check(actual, expected, sizeof(actual), "Pixman solid A8 OVER");
                pixman_image_unref(src);
                pixman_image_unref(msk);
                pixman_image_unref(dst);
            }
        }
    }
    printf("host raster glyph: %u cases passed (all bytes including canaries)\n", cases);
}

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static double measure(composite_fn fn, unsigned width, unsigned height) {
    uint8_t mask[BYTES], destination[BYTES];
    for (unsigned i = 0; i < BYTES; i++) mask[i] = i * 13u;
    memset(destination, 0x71, sizeof(destination));
    const unsigned iterations = 100000;
    const double start = now();
    for (unsigned i = 0; i < iterations; i++) {
        if (!draw(fn, mask, STRIDE, destination, STRIDE, 1, 1, width, height,
                  0x80402010, 0)) exit(2);
    }
    return (now() - start) * 1e9 / iterations;
}

int main(int argc, char **argv) {
    regression();
    if (argc == 2) {
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr, "%s\n", dlerror()); return 2; }
        composite_fn before = (composite_fn)dlsym(library, "avz_framebuffer_composite_bgra8");
        if (!before) return 2;
        const unsigned widths[] = {8, 16, 19, 32, 64};
        for (unsigned trial = 0; trial < 5; trial++) {
            for (unsigned i = 0; i < sizeof(widths) / sizeof(widths[0]); i++) {
                double old_ns, new_ns;
                if (trial % 2) {
                    new_ns = measure(avz_framebuffer_composite_bgra8, widths[i], 7);
                    old_ns = measure(before, widths[i], 7);
                } else {
                    old_ns = measure(before, widths[i], 7);
                    new_ns = measure(avz_framebuffer_composite_bgra8, widths[i], 7);
                }
                printf("trial=%u size=%ux7 before_ns=%.1f after_ns=%.1f ratio=%.2f\n",
                       trial, widths[i], old_ns, new_ns, old_ns / new_ns);
            }
        }
        dlclose(library);
    }
    return 0;
}
