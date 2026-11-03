#ifndef ARM64VIZ_VIRGL_H
#define ARM64VIZ_VIRGL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Optional, dynamically loaded host renderer. No guest or framework pointer
 * crosses this API. Calls are synchronous and serialized on one GPU thread. */
typedef struct AVZVirGL AVZVirGL;
typedef struct {
    uint32_t handle, target, format, bind, width, height, depth, array_size;
    uint32_t last_level, nr_samples, flags;
} AVZVirGLResource;
typedef struct {
    uint32_t handle, context, level, stride, layer_stride;
    uint32_t x, y, z, width, height, depth;
    uint64_t offset;
} AVZVirGLTransfer;

AVZVirGL *avz_virgl_create(const char *framework_directory, char *status, size_t status_size);
void avz_virgl_destroy(AVZVirGL *renderer);
int avz_virgl_reset(AVZVirGL *renderer);
int avz_virgl_finish(AVZVirGL *renderer);
int avz_virgl_capset(AVZVirGL *, uint32_t id, uint32_t *version, uint32_t *size);
int avz_virgl_caps(AVZVirGL *, uint32_t id, uint32_t version, void *data, size_t size);
int avz_virgl_context_create(AVZVirGL *, uint32_t context, const char *name, uint32_t name_size);
int avz_virgl_context_destroy(AVZVirGL *, uint32_t context);
int avz_virgl_resource_create(AVZVirGL *, const AVZVirGLResource *resource);
int avz_virgl_resource_unref(AVZVirGL *, uint32_t resource);
int avz_virgl_context_resource(AVZVirGL *, uint32_t context, uint32_t resource, int attach);
int avz_virgl_backing_attach(AVZVirGL *, uint32_t resource, size_t size);
int avz_virgl_backing_detach(AVZVirGL *, uint32_t resource);
int avz_virgl_backing_copy(AVZVirGL *, uint32_t resource, size_t offset, void *bytes, size_t size, int to_host);
int avz_virgl_transfer(AVZVirGL *, const AVZVirGLTransfer *transfer, int to_host);
int avz_virgl_submit(AVZVirGL *, uint32_t context, const uint32_t *words, size_t word_count);
int avz_virgl_read_pixels(AVZVirGL *, uint32_t resource, uint32_t width, uint32_t height,
                          void *pixels, size_t size);
#ifdef __cplusplus
}
#endif
#endif
