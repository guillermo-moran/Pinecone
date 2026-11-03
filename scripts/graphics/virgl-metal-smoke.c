#include "ARM64VizVirGL.h"
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static int exercise(AVZVirGL *r, unsigned format, unsigned flags) {
    printf("round trip: format %u, flags %u\n", format, flags); fflush(stdout);
    unsigned red = format == 67 ? 0 : 2, blue = format == 67 ? 2 : 0;
    CHECK(avz_virgl_context_create(r, 1, "Pinecone smoke", 14) == 0);
    AVZVirGLResource resource = {.handle = 1, .target = 2, .format = format,
        .bind = 2 | 8, .width = 2, .height = 2, .depth = 1, .array_size = 1, .flags = flags};
    CHECK(avz_virgl_resource_create(r, &resource) == 0);
    CHECK(avz_virgl_context_resource(r, 1, 1, 1) == 0);
    // Public VirGL protocol: create surface, bind framebuffer, clear red.
    const uint32_t clear[] = {
        (5u << 16) | (8u << 8) | 1u, 1, 1, format, 0, 0,
        (3u << 16) | 5u, 1, 0, 1,
        (8u << 16) | 7u, 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0,
    };
    CHECK(avz_virgl_submit(r, 1, clear, sizeof(clear) / sizeof(*clear)) == 0);
    unsigned char pixels[16] = {0};
    CHECK(avz_virgl_read_pixels(r, 1, 2, 2, pixels, sizeof(pixels)) == 0);
    for (unsigned i = 0; i < 16; i += 4) {
        CHECK(pixels[i + blue] == 0 && pixels[i + 1] == 0 && pixels[i + red] == 255 && pixels[i + 3] == 255);
    }
    CHECK(avz_virgl_backing_attach(r, 1, 16) == 0);
    unsigned char pattern[] = {255, 0, 0, 255, 0, 255, 0, 255,
                               0, 0, 255, 255, 255, 255, 0, 255};
    CHECK(avz_virgl_backing_copy(r, 1, 0, pattern, 16, 1) == 0);
    AVZVirGLTransfer transfer = {.handle = 1, .context = 1, .stride = 8,
        .width = 2, .height = 2, .depth = 1};
    CHECK(avz_virgl_transfer(r, &transfer, 1) == 0);
    CHECK(avz_virgl_finish(r) == 0);
    CHECK(avz_virgl_read_pixels(r, 1, 2, 2, pixels, 16) == 0);
    CHECK(!memcmp(pixels, pattern, 16));
    CHECK(avz_virgl_submit(r, 1, clear + 10, 9) == 0);
    transfer.width = transfer.height = 1;
    CHECK(avz_virgl_transfer(r, &transfer, 0) == 0);
    CHECK(avz_virgl_backing_copy(r, 1, 0, pixels, 16, 0) == 0);
    CHECK(pixels[blue] == 0 && pixels[1] == 0 && pixels[red] == 255 && pixels[3] == 255);
    CHECK(!memcmp(pixels + 4, pattern + 4, 12));
    CHECK(avz_virgl_context_resource(r, 1, 1, 0) == 0);
    CHECK(avz_virgl_resource_unref(r, 1) == 0);
    CHECK(avz_virgl_context_destroy(r, 1) == 0);
    CHECK(avz_virgl_reset(r) == 0);
    CHECK(avz_virgl_context_create(r, 1, "reset", 5) == 0);
    CHECK(avz_virgl_resource_create(r, &resource) == 0);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s FRAMEWORK_DIRECTORY\n", argv[0]); return 2; }
    char status[256] = {0};
    AVZVirGL *r = avz_virgl_create(argv[1], status, sizeof(status));
    printf("renderer: %s\n", status); fflush(stdout);
    CHECK(r);
    uint32_t version = 0, size = 0;
    CHECK(avz_virgl_capset(r, 1, &version, &size) == 0 && size > 0);
    printf("VirGL capset 1: version %u, %u bytes\n", version, size);
    for (unsigned f = 0; f < 2; ++f) {
        for (unsigned flags = 0; flags < 2; ++flags) {
            CHECK(exercise(r, f ? 67 : 1, flags) == 0);
            CHECK(avz_virgl_reset(r) == 0);
        }
    }
    avz_virgl_destroy(r);
    puts("PASS actual VirGL -> ANGLE Metal clear, BGRA/RGBA readback, upload, orientation, reset and resource reuse");
    return 0;
}
