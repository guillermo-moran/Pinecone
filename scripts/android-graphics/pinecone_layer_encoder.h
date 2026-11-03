#ifndef PINECONE_LAYER_ENCODER_H
#define PINECONE_LAYER_ENCODER_H

/* Portable preparation layer, NOT an Android composer HAL. Inputs identify
 * registered virtio resources (or GEM handles before kernel relocation).
 * The caller owns buffer import, acquire/release fences and presentation. */
#include <stdint.h>
#include <string.h>

enum pinecone_layer_format { PINECONE_LAYER_BGRA_PREMULTIPLIED = 1,
                             PINECONE_LAYER_BGRX = 2 };
struct pinecone_layer_rect { int32_t x, y; uint32_t width, height; };
struct pinecone_layer_buffer {
    uint32_t resource, width, height;
    enum pinecone_layer_format format;
};
struct pinecone_layer {
    struct pinecone_layer_buffer source, destination;
    struct pinecone_layer_rect crop, frame;
    uint32_t transform;
    uint8_t alpha, bilinear, protected_content;
};

static inline void pinecone_layer_le32(uint8_t *out, uint32_t value) {
    for (unsigned i = 0; i != 4; ++i) out[i] = (uint8_t)(value >> (8 * i));
}
static inline int pinecone_layer_rect_fits(struct pinecone_layer_rect r,
                                         struct pinecone_layer_buffer b) {
    return r.x >= 0 && r.y >= 0 && r.width && r.height &&
        (uint64_t)(uint32_t)r.x + r.width <= b.width &&
        (uint64_t)(uint32_t)r.y + r.height <= b.height;
}
static inline int pinecone_layer_format_supported(enum pinecone_layer_format f) {
    return f == PINECONE_LAYER_BGRA_PREMULTIPLIED || f == PINECONE_LAYER_BGRX;
}

/* Encode one v3 source-over record; failure leaves output untouched and must
 * cause CLIENT composition. No rotation, protected buffers, YUV, fractional
 * crop, color conversion, HDR, or coverage-alpha support is implied. */
static inline int pinecone_encode_layer(uint8_t output[64], const struct pinecone_layer *l) {
    if (!output || !l || !l->source.resource || !l->destination.resource ||
        l->source.resource == l->destination.resource || l->transform ||
        l->protected_content || !pinecone_layer_format_supported(l->source.format) ||
        !pinecone_layer_format_supported(l->destination.format) ||
        !pinecone_layer_rect_fits(l->crop, l->source) ||
        !pinecone_layer_rect_fits(l->frame, l->destination)) return 0;
    uint8_t record[64] = {0};
    pinecone_layer_le32(record, 0x504e3244u);
    record[4] = 3; record[6] = 2; /* v3 SOURCE_OVER */
    uint32_t flags = l->source.format == PINECONE_LAYER_BGRA_PREMULTIPLIED ? 1u : 0u;
    if (l->bilinear) flags |= 2u;
    if (l->alpha != 255) flags |= 4u | 8u; /* solid alpha mask */
    pinecone_layer_le32(record + 8, flags);
    pinecone_layer_le32(record + 12, l->source.resource);
    pinecone_layer_le32(record + 16, l->destination.resource);
    pinecone_layer_le32(record + 20, (uint32_t)l->crop.x);
    pinecone_layer_le32(record + 24, (uint32_t)l->crop.y);
    pinecone_layer_le32(record + 28, (uint32_t)l->frame.x);
    pinecone_layer_le32(record + 32, (uint32_t)l->frame.y);
    pinecone_layer_le32(record + 36, l->frame.width);
    pinecone_layer_le32(record + 40, l->frame.height);
    pinecone_layer_le32(record + 48, l->crop.width);
    pinecone_layer_le32(record + 52, l->crop.height);
    if (l->alpha != 255) pinecone_layer_le32(record + 60, l->alpha);
    memcpy(output, record, sizeof(record));
    return 1;
}
#endif
