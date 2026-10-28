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

/* A registration is a renderer lease, NOT permission to expose a CPU pointer.
 * The owner guarantees stable, exclusively managed storage: all CPU accesses
 * use the hooks below, and external producers/aliases cannot modify it.
 * On success the bridge owns one backing lifetime and calls release(owner)
 * outside its lock after unregister AND the last attached image/fence/scope.
 * On failure the caller keeps that lifetime. Calls are externally serialized;
 * release runs on the thread dropping the last reference (not a worker).
 * Renderer enqueue and CPU scopes for an unsubmitted lease share a thread;
 * call output_commit before handing storage to another thread.
 * Unknown pointers remain untrusted; registration never revokes an escape.
 */
struct pinecone_pixman_buffer;
struct pinecone_pixman_buffer *pinecone_pixman_buffer_register(
    void *data, size_t length, void *owner, void (*release)(void *));
void pinecone_pixman_buffer_unregister(struct pinecone_pixman_buffer *buffer);
int pinecone_pixman_image_attach_buffer(
    pixman_image_t *image, struct pinecone_pixman_buffer *buffer);
/* READ=1, WRITE=2. Begin fences before CPU exposure; every successful begin
 * requires an end with identical flags. Writes invalidate at begin AND end.
 * Read scopes allow GPU reads, never GPU writes. Unregister consumes the
 * registration reference, but open scopes and images keep the token alive.
 */
int pinecone_pixman_buffer_begin_cpu_access(
    struct pinecone_pixman_buffer *buffer, uint32_t flags);
void pinecone_pixman_buffer_end_cpu_access(
    struct pinecone_pixman_buffer *buffer, uint32_t flags);
/* Public exports and retained aliases escape even inside a CPU scope. This
 * waits for the image's fences and permanently forbids asynchronous direct
 * use of its storage. Neither end_cpu_access nor mark_dirty revokes escape. */
uint32_t *pinecone_pixman_get_data_escaping(pixman_image_t *image);
/* Submit before KMS/backend commit. Zero means do not present; queued draws
 * remain retained for retry. Success does not wait for completion. */
int pinecone_pixman_prepare_output_commit(void);
/* Legacy unchecked ABI, retained for existing callers. */
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
