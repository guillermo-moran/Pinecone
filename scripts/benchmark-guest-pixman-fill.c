/* Run inside the emulated Linux guest with libpinecone-pixman preloaded.
 * Compare PINECONE_PIXMAN_CPU_FOREIGN_FILL=0/1 in separate processes.
 * Measures the full synchronous fill, including scratch allocation and waits. */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

typedef int (*fill_fn)(uint32_t *, int, int, int, int, int, int, uint32_t);

static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

int main(void) {
    void *library = dlopen("libpixman-1.so.0", RTLD_NOW | RTLD_GLOBAL);
    void *bridge = dlopen("libpinecone-pixman.so", RTLD_NOW | RTLD_GLOBAL);
    fill_fn fill = bridge ? (fill_fn)dlsym(bridge, "pixman_fill") : NULL;
    if (!library || !fill) { fprintf(stderr, "pixman bridge unavailable: %s\n", dlerror()); return 1; }
    if (access("/dev/dri/card0", R_OK | W_OK)) { perror("DRM device required"); return 1; }
    void *(*create)(uint32_t, int, int, int) = dlsym(bridge, "pinecone_pixman_create_bits");
    int (*unref)(void *) = dlsym(bridge, "pixman_image_unref");
    // Cairo normally creates a shared image before raw fills. Establish that
    // same DRM context; otherwise both modes silently use the CPU path.
    void *shared = create ? create(0x20028888u, 2, 2, 0) : NULL;
    if (!shared || !unref) { fputs("Shared graphics context required\n", stderr); return 1; }
    enum { stride = 488, rows = 1026, repeats = 12 };
    uint32_t *pixels = malloc((size_t)stride * rows * sizeof(*pixels));
    if (!pixels) return 1;
    struct { int width, height; uint32_t color; } cases[] = {
        {480, 1024, 0}, {480, 1024, 0xff192a3b}, {160, 40, 0xffffffff},
        {24, 24, 0x70133729}
    };
    unsigned mismatched_cases = 0;
    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
        for (size_t i = 0; i < (size_t)stride * rows; ++i) pixels[i] = 0xa5a5a5a5;
        uint64_t begin = now_ns();
        for (unsigned i = 0; i < repeats; ++i) {
            if (!fill(pixels, stride, 32, 2, 1, cases[c].width, cases[c].height,
                      cases[c].color ^ (i & 1))) return 2;
        }
        uint64_t elapsed = now_ns() - begin;
        unsigned mismatches = 0;
        for (unsigned y = 0; y < rows; ++y) {
            for (unsigned x = 0; x < stride; ++x) {
                int inside = x >= 2 && x < (unsigned)cases[c].width + 2 &&
                    y >= 1 && y < (unsigned)cases[c].height + 1;
                uint32_t expected = inside ? cases[c].color ^ 1 : 0xa5a5a5a5;
                if (pixels[y * stride + x] != expected) {
                    if (!mismatches++) fprintf(stderr,
                        "fill mismatch case=%u x=%u y=%u expected=%08x actual=%08x\n",
                        c, x, y, expected, pixels[y * stride + x]);
                }
            }
        }
        mismatched_cases += mismatches != 0;
        printf("PINECONE_FILL_BENCH mode=%s case=%u width=%d height=%d repeats=%d elapsed_ns=%llu verified=%u\n",
            getenv("PINECONE_PIXMAN_CPU_FOREIGN_FILL") ? getenv("PINECONE_PIXMAN_CPU_FOREIGN_FILL") : "default",
            c, cases[c].width, cases[c].height, repeats, (unsigned long long)elapsed,
            mismatches == 0);
        fflush(stdout);
    }
    free(pixels);
    unref(shared);
    dlclose(bridge);
    dlclose(library);
    return mismatched_cases ? 3 : 0;
}
