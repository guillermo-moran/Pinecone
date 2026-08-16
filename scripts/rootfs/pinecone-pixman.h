#ifndef PINECONE_PIXMAN_H
#define PINECONE_PIXMAN_H

#include <stdint.h>

typedef struct pixman_image pixman_image_t;
typedef uint32_t pixman_format_code_t;

pixman_image_t *pinecone_pixman_create_bits(
    pixman_format_code_t format,
    int width,
    int height,
    int clear
);

/* The caller owns the returned close-on-exec dma-buf descriptor. */
int pinecone_pixman_export_dmabuf(
    pixman_image_t *image,
    int *dma_buf_fd,
    uint32_t *stride,
    uint64_t *modifier
);

#endif
