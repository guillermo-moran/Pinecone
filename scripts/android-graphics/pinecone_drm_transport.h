#ifndef PINECONE_DRM_TRANSPORT_H
#define PINECONE_DRM_TRANSPORT_H

#include "pinecone_layer_encoder.h"
#include <poll.h>
#include <time.h>

/* The layer resource fields are GEM handles in drm_fd's namespace, not
 * DMA-BUF fds or host resource IDs. Caller retains the buffers until the
 * returned completion fence signals. Acquire fds are borrowed, never closed.
 * This fence covers composition; it is NOT an Android display-present fence.
 * Requires Pinecone's patched virtio DRM execbuffer path. On ioctl failure,
 * callers must conservatively retain buffer leases until DRM queue teardown
 * or another driver-specific completion guarantee: submission disposition can
 * be ambiguous. An error is not permission to reuse producer storage.
 * timeout_ms bounds acquire-fence waiting only; ioctl duration is unbounded
 * by this API and must be isolated from the Android composer service thread. */
int pinecone_drm_submit_layer(int drm_fd, const struct pinecone_layer *layer,
    int source_acquire_fd, int destination_acquire_fd, int timeout_ms,
    int *completion_fence_fd);

/* Injectable syscall boundary for transport verification. Functions follow
 * POSIX return/errno conventions; clock returns CLOCK_MONOTONIC time. */
struct pinecone_drm_ops {
    void *context;
    int (*poll_fds)(void *, struct pollfd *, nfds_t, int);
    int (*monotonic_time)(void *, struct timespec *);
    int (*submit_ioctl)(void *, int, unsigned long, void *);
    int (*close_fd)(void *, int);
};
int pinecone_drm_submit_layer_with_ops(int drm_fd,
    const struct pinecone_layer *layer, int source_acquire_fd,
    int destination_acquire_fd, int timeout_ms, int *completion_fence_fd,
    const struct pinecone_drm_ops *ops);

/* Linux virtgpu UAPI, fixed-width and layout checked in the implementation. */
struct pinecone_drm_execbuffer {
    uint32_t flags, size;
    uint64_t command, bo_handles;
    uint32_t num_bo_handles;
    int32_t fence_fd;
    uint32_t ring_idx, syncobj_stride, num_in_syncobjs, num_out_syncobjs;
    uint64_t in_syncobjs, out_syncobjs;
};
#define PINECONE_DRM_EXECBUFFER_IOCTL 0xc0406442ul
#define PINECONE_DRM_FENCE_FD_OUT 2u

#endif
