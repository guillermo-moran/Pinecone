#include <pixman.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum pinecone_test_format {
    PINECONE_TEST_ARGB = 0,
    PINECONE_TEST_A8 = 1,
    PINECONE_TEST_XRGB = 2,
};

static pixman_format_code_t pixman_format(enum pinecone_test_format format) {
    switch (format) {
    case PINECONE_TEST_A8:
        return PIXMAN_a8;
    case PINECONE_TEST_XRGB:
        return PIXMAN_x8r8g8b8;
    case PINECONE_TEST_ARGB:
    default:
        return PIXMAN_a8r8g8b8;
    }
}

static void write_pixel(
    uint8_t *bytes, enum pinecone_test_format format, uint32_t pixel
) {
    if (format == PINECONE_TEST_A8) {
        bytes[0] = (uint8_t)(pixel >> 24);
        return;
    }
    memcpy(bytes, &pixel, sizeof(pixel));
}

static uint32_t read_pixel(
    const uint8_t *bytes, enum pinecone_test_format format
) {
    if (format == PINECONE_TEST_A8)
        return (uint32_t)bytes[0] << 24;
    uint32_t pixel;
    memcpy(&pixel, bytes, sizeof(pixel));
    return pixel;
}

int main(void) {
    static const uint32_t pixels[] = {
        UINT32_C(0x00000000), UINT32_C(0xff000000),
        UINT32_C(0xffffffff), UINT32_C(0x80402010),
        UINT32_C(0x40302010), UINT32_C(0x01010101),
        UINT32_C(0xfe7f3f1f),
    };
    static const uint32_t masks[] = {
        UINT32_C(0x00000000), UINT32_C(0x400c2030),
        UINT32_C(0x80402010), UINT32_C(0xffffffff),
    };
    unsigned long case_id = 0;

    puts("# id op srcfmt maskkind component dstfmt source mask destination expected");
    for (int operation = PIXMAN_OP_CLEAR;
         operation <= PIXMAN_OP_SATURATE; operation++) {
        for (int source_format = PINECONE_TEST_ARGB;
             source_format <= PINECONE_TEST_XRGB; source_format++) {
            for (int destination_format = PINECONE_TEST_ARGB;
                 destination_format <= PINECONE_TEST_XRGB;
                 destination_format++) {
                for (int mask_kind = 0; mask_kind <= 2; mask_kind++) {
                    int component_limit = mask_kind == 2 ? 1 : 0;
                    for (int component_alpha = 0;
                         component_alpha <= component_limit; component_alpha++) {
                        for (size_t pixel_index = 0;
                             pixel_index < sizeof(pixels) / sizeof(pixels[0]);
                             pixel_index++) {
                            uint32_t source_pixel = pixels[pixel_index];
                            uint32_t destination_pixel =
                                pixels[(pixel_index * 3u + 2u) %
                                    (sizeof(pixels) / sizeof(pixels[0]))];
                            uint32_t mask_pixel =
                                masks[(pixel_index + (size_t)operation) %
                                    (sizeof(masks) / sizeof(masks[0]))];
                            uint8_t source_bytes[4] = {0};
                            uint8_t mask_bytes[4] = {0};
                            uint8_t destination_bytes[4] = {0};
                            write_pixel(source_bytes, source_format, source_pixel);
                            write_pixel(mask_bytes,
                                mask_kind == 1 ? PINECONE_TEST_A8
                                               : PINECONE_TEST_ARGB,
                                mask_pixel);
                            write_pixel(destination_bytes, destination_format,
                                destination_pixel);

                            pixman_image_t *source = pixman_image_create_bits(
                                pixman_format(source_format), 1, 1,
                                (uint32_t *)source_bytes, 4);
                            pixman_image_t *destination = pixman_image_create_bits(
                                pixman_format(destination_format), 1, 1,
                                (uint32_t *)destination_bytes, 4);
                            pixman_image_t *mask = NULL;
                            if (mask_kind != 0) {
                                mask = pixman_image_create_bits(
                                    mask_kind == 1 ? PIXMAN_a8 : PIXMAN_a8r8g8b8,
                                    1, 1, (uint32_t *)mask_bytes, 4);
                                pixman_image_set_component_alpha(
                                    mask, component_alpha != 0);
                            }
                            if (source == NULL || destination == NULL ||
                                (mask_kind != 0 && mask == NULL)) {
                                fputs("failed to create Pixman test image\n", stderr);
                                return EXIT_FAILURE;
                            }
                            pixman_image_composite32(
                                (pixman_op_t)operation, source, mask, destination,
                                0, 0, 0, 0, 0, 0, 1, 1);
                            uint32_t expected = read_pixel(
                                destination_bytes, destination_format);
                            printf(
                                "%lu %d %d %d %d %d %08x %08x %08x %08x\n",
                                case_id++, operation, source_format, mask_kind,
                                component_alpha, destination_format,
                                source_pixel, mask_pixel, destination_pixel,
                                expected);
                            pixman_image_unref(source);
                            if (mask != NULL)
                                pixman_image_unref(mask);
                            pixman_image_unref(destination);
                        }
                    }
                }
            }
        }
    }
    return EXIT_SUCCESS;
}
