/* Run in Pinecone's guest, not on the build host, with the bridge preloaded.
 * Compare CPU_SMALL_COMPOSITE=0/1 at OPERATOR_MASK=0x100f. OPERATOR_MASK=0
 * separately measures stock CPU Pixman with every composite offload disabled. */
#include <pixman.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static unsigned mul255(unsigned a, unsigned b) {
    unsigned v = a * b + 128;
    return (v + (v >> 8)) >> 8;
}

int main(void) {
    void *bridge = dlopen("libpinecone-pixman.so", RTLD_NOW | RTLD_GLOBAL);
    pixman_image_t *(*create)(pixman_format_code_t, int, int, int) =
        bridge ? dlsym(bridge, "pinecone_pixman_create_bits") : NULL;
    void (*begin)(uint32_t) = bridge ? dlsym(bridge, "pinecone_pixman_begin_cpu_access_flags") : NULL;
    void (*end)(void) = bridge ? dlsym(bridge, "pinecone_pixman_end_cpu_access") : NULL;
    int (*commit)(void) = bridge ? dlsym(bridge, "pinecone_pixman_prepare_output_commit") : NULL;
    if (!create || !begin || !end || !commit) { fputs("bridge required\n", stderr); return 1; }
    enum { side = 132, repeats = 32 };
    pixman_image_t *dst = create(PIXMAN_a8r8g8b8, side, side, 1);
    pixman_color_t color = { .red = 0x4040, .green = 0x2020, .blue = 0x1010, .alpha = 0x8080 };
    pixman_image_t *src = pixman_image_create_solid_fill(&color);
    _Alignas(uint32_t) uint8_t mask_data[side * side];
    for (unsigned i = 0; i < sizeof(mask_data); ++i) mask_data[i] = (uint8_t)(i * 37u);
    pixman_image_t *mask = pixman_image_create_bits(PIXMAN_a8, side, side, (uint32_t *)mask_data, side);
    if (!dst || !src || !mask) { fputs("shared images required\n", stderr); return 1; }
    const unsigned sizes[] = {1, 2, 4, 8, 16, 32, 64, 128};
    uint32_t expected_colors[256];
    for (unsigned m = 0; m < 256; ++m) {
        uint32_t expected = 0xff314253;
        for (unsigned i = 0; i < repeats; ++i) {
            uint32_t next = 0;
            const unsigned s[4] = {16, 32, 64, 128};
            for (unsigned ch = 0; ch < 4; ++ch) {
                unsigned v = mul255(s[ch], m) + mul255((expected >> (8 * ch)) & 255, 255 - mul255(128, m));
                next |= (v > 255 ? 255 : v) << (8 * ch);
            }
            expected = next;
        }
        expected_colors[m] = expected;
    }
    unsigned failures = 0;
    for (unsigned masked = 0; masked < 2; ++masked) {
        for (unsigned c = 0; c < sizeof(sizes) / sizeof(sizes[0]); ++c) {
            unsigned n = sizes[c];
            begin(3);
            uint32_t *pixels = pixman_image_get_data(dst);
            int stride = pixman_image_get_stride(dst) / 4;
            for (unsigned y = 0; y < side; ++y)
                for (unsigned x = 0; x < (unsigned)stride; ++x) pixels[y * stride + x] = 0xff314253;
            end();
            uint64_t start = now_ns();
            for (unsigned i = 0; i < repeats; ++i)
                pixman_image_composite32(PIXMAN_OP_OVER, src, masked ? mask : NULL,
                    dst, 0, 0, 2, 1, 2, 1, n, n);
            if (!commit()) return 2;
            begin(1);
            pixels = pixman_image_get_data(dst); /* Include GPU completion in timing. */
            uint64_t elapsed = now_ns() - start;
            unsigned mismatches = 0;
            for (unsigned y = 0; y < side; ++y) {
                for (unsigned x = 0; x < (unsigned)stride; ++x) {
                    uint32_t expected = 0xff314253;
                    if (x >= 2 && x < n + 2 && y >= 1 && y < n + 1) {
                        unsigned m = masked ? mask_data[y * side + x] : 255;
                        expected = expected_colors[m];
                    }
                    if (pixels[y * stride + x] != expected && !mismatches++)
                        fprintf(stderr, "composite mismatch masked=%u size=%u x=%u y=%u expected=%08x actual=%08x\n",
                            masked, n, x, y, expected, pixels[y * stride + x]);
                }
            }
            end();
            failures += mismatches != 0;
            printf("PINECONE_COMPOSITE_BENCH operators=%s small=%s masked=%u size=%u repeats=%u elapsed_ns=%llu verified=%u\n",
                getenv("PINECONE_PIXMAN_OPERATOR_MASK") ? getenv("PINECONE_PIXMAN_OPERATOR_MASK") : "default",
                getenv("PINECONE_PIXMAN_CPU_SMALL_COMPOSITE") ? getenv("PINECONE_PIXMAN_CPU_SMALL_COMPOSITE") : "default",
                masked, n, repeats, (unsigned long long)elapsed, mismatches == 0);
            fflush(stdout);
        }
    }
    pixman_image_unref(mask);
    pixman_image_unref(src);
    pixman_image_unref(dst);
    dlclose(bridge);
    return failures ? 3 : 0;
}
