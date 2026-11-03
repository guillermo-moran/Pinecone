#include "pinecone_layer_encoder.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    struct pinecone_layer l = {
        .source = {1, 2, 1, PINECONE_LAYER_BGRA_PREMULTIPLIED},
        .destination = {2, 2, 2, PINECONE_LAYER_BGRA_PREMULTIPLIED},
        .crop = {0, 0, 2, 1}, .frame = {0, 0, 2, 2},
        .alpha = 128, .bilinear = 1
    };
    uint8_t out[64], before[64];
    memset(out, 0xa5, sizeof(out)); memcpy(before, out, sizeof(out));
    l.transform = 1;
    assert(!pinecone_encode_layer(out, &l));
    assert(!memcmp(before, out, sizeof(out)));
    l.transform = 0; l.crop.x = -1;
    assert(!pinecone_encode_layer(out, &l));
    l.crop.x = 0; l.crop.width = UINT32_MAX;
    assert(!pinecone_encode_layer(out, &l));
    l.crop.width = 2; l.protected_content = 1;
    assert(!pinecone_encode_layer(out, &l));
    l.protected_content = 0; l.source.format = 99;
    assert(!pinecone_encode_layer(out, &l));
    l.source.format = PINECONE_LAYER_BGRA_PREMULTIPLIED;
    assert(pinecone_encode_layer(out, &l));
    return fwrite(out, 1, sizeof(out), stdout) == sizeof(out) ? 0 : 1;
}
