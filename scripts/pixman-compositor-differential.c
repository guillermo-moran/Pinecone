#include "ARM64VizNative.h"

#include <pixman.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    TEST_WIDTH = 19,
    TEST_HEIGHT = 11,
    TEST_STRIDE = 256,
};

static uint32_t random_state = UINT32_C(0x9e3779b9);

static uint8_t next_byte(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return (uint8_t)random_state;
}

static void initialize_pixels(
    uint8_t *pixels, int packed_a8, int premultiplied
) {
    memset(pixels, 0xa5, TEST_STRIDE * TEST_HEIGHT);
    for (size_t y = 0; y < TEST_HEIGHT; y++) {
        uint8_t *row = pixels + y * TEST_STRIDE;
        for (size_t x = 0; x < TEST_WIDTH; x++) {
            if (packed_a8) {
                row[x] = next_byte();
                continue;
            }
            uint8_t alpha = next_byte();
            row[x * 4u + 0u] = premultiplied
                ? (uint8_t)(((uint16_t)next_byte() * alpha + 127u) / 255u)
                : next_byte();
            row[x * 4u + 1u] = premultiplied
                ? (uint8_t)(((uint16_t)next_byte() * alpha + 127u) / 255u)
                : next_byte();
            row[x * 4u + 2u] = premultiplied
                ? (uint8_t)(((uint16_t)next_byte() * alpha + 127u) / 255u)
                : next_byte();
            row[x * 4u + 3u] = alpha;
        }
    }
}

static int compare_pixels(
    const uint8_t *reference,
    const uint8_t *actual,
    const uint8_t *source,
    const uint8_t *initial,
    int packed_a8,
    pixman_op_t operation,
    int source_a8,
    int mask_kind,
    int component_alpha
) {
    const size_t row_bytes = TEST_WIDTH * (packed_a8 ? 1u : 4u);
    for (size_t y = 0; y < TEST_HEIGHT; y++) {
        for (size_t byte = 0; byte < row_bytes; byte++) {
            const size_t offset = y * TEST_STRIDE + byte;
            if (reference[offset] == actual[offset])
                continue;
            fprintf(stderr,
                "mismatch op=%d srcA8=%d mask=%d component=%d dstA8=%d "
                "xbyte=%zu y=%zu expected=%u actual=%u source=%u "
                "initial=%u sourceAlpha=%u initialAlpha=%u\n",
                operation, source_a8, mask_kind, component_alpha, packed_a8,
                byte, y, reference[offset], actual[offset], source[offset],
                initial[offset], source[y * TEST_STRIDE +
                    (byte / (packed_a8 ? 1u : 4u)) * 4u + 3u],
                initial[y * TEST_STRIDE +
                    (byte / (packed_a8 ? 1u : 4u)) * 4u + 3u]);
            return 0;
        }
    }
    return 1;
}

static int run_case(
    pixman_op_t operation,
    int source_a8,
    int mask_kind,
    int component_alpha,
    int destination_a8,
    int use_offsets
) {
    const int source_x = use_offsets ? 3 : 0;
    const int source_y = use_offsets ? 2 : 0;
    const int destination_x = use_offsets ? 5 : 0;
    const int destination_y = use_offsets ? 1 : 0;
    const int width = use_offsets ? 9 : TEST_WIDTH;
    const int height = use_offsets ? 7 : TEST_HEIGHT;
    uint8_t source[TEST_STRIDE * TEST_HEIGHT];
    uint8_t mask[TEST_STRIDE * TEST_HEIGHT];
    uint8_t reference[TEST_STRIDE * TEST_HEIGHT];
    uint8_t actual[TEST_STRIDE * TEST_HEIGHT];
    uint8_t initial[TEST_STRIDE * TEST_HEIGHT];
    initialize_pixels(source, source_a8, 1);
    initialize_pixels(mask, mask_kind == 1, 1);
    initialize_pixels(reference, destination_a8, 1);
    memcpy(actual, reference, sizeof(actual));
    memcpy(initial, reference, sizeof(initial));

    pixman_image_t *source_image = pixman_image_create_bits(
        source_a8 ? PIXMAN_a8 : PIXMAN_a8r8g8b8,
        TEST_WIDTH, TEST_HEIGHT, (uint32_t *)source, TEST_STRIDE);
    pixman_image_t *destination_image = pixman_image_create_bits(
        destination_a8 ? PIXMAN_a8 : PIXMAN_a8r8g8b8,
        TEST_WIDTH, TEST_HEIGHT, (uint32_t *)reference, TEST_STRIDE);
    pixman_image_t *mask_image = NULL;
    if (mask_kind != 0) {
        mask_image = pixman_image_create_bits(
            mask_kind == 1 ? PIXMAN_a8 : PIXMAN_a8r8g8b8,
            TEST_WIDTH, TEST_HEIGHT, (uint32_t *)mask, TEST_STRIDE);
        pixman_image_set_component_alpha(mask_image, component_alpha);
    }
    if (source_image == NULL || destination_image == NULL ||
        (mask_kind != 0 && mask_image == NULL)) {
        fprintf(stderr, "failed to create Pixman image\n");
        return 0;
    }

    pixman_image_composite32(
        operation, source_image, mask_image, destination_image,
        source_x, source_y, 0, 0, destination_x, destination_y,
        width, height);
    int result = avz_framebuffer_composite_bgra8(
        source, TEST_STRIDE, source_x, source_y, width, height,
        mask_kind == 0 ? NULL : mask, TEST_STRIDE, UINT8_MAX,
        actual, TEST_STRIDE, destination_x, destination_y, width, height,
        0, (uint32_t)operation, 0, 0, component_alpha,
        mask_kind == 1, source_a8, destination_a8);

    pixman_image_unref(source_image);
    if (mask_image != NULL)
        pixman_image_unref(mask_image);
    pixman_image_unref(destination_image);
    return result && compare_pixels(
        reference, actual, source, initial, destination_a8, operation,
        source_a8, mask_kind, component_alpha);
}

int main(void) {
    for (int operation = PIXMAN_OP_CLEAR;
         operation <= PIXMAN_OP_SATURATE; operation++) {
        for (int source_a8 = 0; source_a8 <= 1; source_a8++) {
            for (int mask_kind = 0; mask_kind <= 2; mask_kind++) {
                for (int component_alpha = 0; component_alpha <= 1;
                     component_alpha++) {
                    if ((mask_kind == 0 || mask_kind == 1) && component_alpha)
                        continue;
                    for (int destination_a8 = 0; destination_a8 <= 1;
                         destination_a8++) {
                        for (int use_offsets = 0; use_offsets <= 1;
                             use_offsets++) {
                            random_state = UINT32_C(0x9e3779b9);
                            if (!run_case(
                                    (pixman_op_t)operation, source_a8,
                                    mask_kind, component_alpha,
                                    destination_a8, use_offsets)) {
                                return EXIT_FAILURE;
                            }
                        }
                    }
                }
            }
        }
    }
    puts("Pinecone compositor matches Pixman reference cases");
    return EXIT_SUCCESS;
}
