#ifndef PINECONE_PIXMAN_H
#define PINECONE_PIXMAN_H

#include <stdint.h>
#include <stddef.h>

typedef struct pixman_image pixman_image_t;
typedef uint32_t pixman_format_code_t;

pixman_image_t *pinecone_pixman_create_bits(
    pixman_format_code_t format,
    int width,
    int height,
    int clear
);

void pinecone_pixman_begin_cpu_access(void);
/* flags: bit 0 reads, bit 1 writes. End every successful begin scope. */
void pinecone_pixman_begin_cpu_access_flags(uint32_t flags);
/* Call after mapping and before exposing bytes to the CPU; zero means failure. */
int pinecone_pixman_access_buffer(void *data, size_t length);
void pinecone_pixman_end_cpu_access(void);
/* Public exports and retained aliases escape even inside a CPU scope. This
 * waits for the image's fences and permanently forbids asynchronous direct
 * use of its storage. Neither end_cpu_access nor mark_dirty revokes escape. */
uint32_t *pinecone_pixman_get_data_escaping(pixman_image_t *image);
void pinecone_pixman_output_commit(void);
void pinecone_pixman_begin_render_pass(void);
void pinecone_pixman_end_render_pass(void);

/* The caller owns the returned close-on-exec dma-buf descriptor. */
int pinecone_pixman_export_dmabuf(
    pixman_image_t *image,
    int *dma_buf_fd,
    uint32_t *stride,
    uint64_t *modifier
);

#endif
