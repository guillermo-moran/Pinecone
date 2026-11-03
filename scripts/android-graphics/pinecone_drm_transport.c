#define _POSIX_C_SOURCE 200809L
#include "pinecone_drm_transport.h"
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <unistd.h>

_Static_assert(sizeof(struct pinecone_drm_execbuffer) == 64, "virtgpu UAPI size");
_Static_assert(offsetof(struct pinecone_drm_execbuffer, fence_fd) == 28, "virtgpu fence offset");
_Static_assert(offsetof(struct pinecone_drm_execbuffer, in_syncobjs) == 48, "virtgpu syncobj offset");

static int now_ns(const struct pinecone_drm_ops *ops, uint64_t *value) {
    struct timespec ts;
    if (ops->monotonic_time(ops->context, &ts)) return -1;
    if (ts.tv_sec < 0 || ts.tv_nsec < 0 || ts.tv_nsec >= 1000000000L ||
        (uint64_t)ts.tv_sec > UINT64_MAX / 1000000000u) {
        errno = EOVERFLOW; return -1;
    }
    *value = (uint64_t)ts.tv_sec * 1000000000u;
    if (*value > UINT64_MAX - (uint64_t)ts.tv_nsec) { errno = EOVERFLOW; return -1; }
    *value += (uint64_t)ts.tv_nsec;
    return 0;
}

static int wait_acquires(const struct pinecone_drm_ops *ops, int source,
                         int destination, int timeout_ms) {
    struct pollfd fds[2];
    nfds_t count = 0;
    if (source >= 0) fds[count++] = (struct pollfd){source, POLLIN, 0};
    if (destination >= 0 && destination != source)
        fds[count++] = (struct pollfd){destination, POLLIN, 0};
    if (!count) return 0;
    uint64_t now, deadline;
    if (now_ns(ops, &now)) return -1;
    uint64_t budget = (uint64_t)timeout_ms * 1000000u;
    if (now > UINT64_MAX - budget) { errno = EOVERFLOW; return -1; }
    deadline = now + budget;
    for (;;) {
        uint64_t remaining = now < deadline ? deadline - now : 0;
        int wait_ms = (int)(remaining / 1000000u + (remaining % 1000000u != 0));
        int result = ops->poll_fds(ops->context, fds, count, wait_ms);
        if (result < 0 && errno != EINTR) return -1;
        if (result >= 0) {
            nfds_t pending = 0;
            for (nfds_t i = 0; i < count; ++i) {
                if (fds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    errno = EIO; return -1;
                }
                if (!(fds[i].revents & POLLIN)) {
                    fds[pending] = fds[i]; fds[pending++].revents = 0;
                }
            }
            count = pending;
            if (!count) return 0;
        }
        if (now_ns(ops, &now)) return -1;
        if (now >= deadline) { errno = ETIMEDOUT; return -1; }
    }
}

int pinecone_drm_submit_layer_with_ops(int drm_fd,
    const struct pinecone_layer *layer, int source_acquire_fd,
    int destination_acquire_fd, int timeout_ms, int *completion_fence_fd,
    const struct pinecone_drm_ops *ops) {
    if (!completion_fence_fd) { errno = EINVAL; return -1; }
    *completion_fence_fd = -1;
    uint8_t payload[64];
    if (drm_fd < 0 || source_acquire_fd < -1 || destination_acquire_fd < -1 ||
        timeout_ms < 0 || !ops || !ops->poll_fds || !ops->monotonic_time ||
        !ops->submit_ioctl || !ops->close_fd || !pinecone_encode_layer(payload, layer)) {
        errno = EINVAL; return -1;
    }
    if (wait_acquires(ops, source_acquire_fd, destination_acquire_fd, timeout_ms)) return -1;
    uint32_t handles[2] = {layer->source.resource, layer->destination.resource};
    struct pinecone_drm_execbuffer submit = {
        .flags = PINECONE_DRM_FENCE_FD_OUT, .size = sizeof(payload),
        .command = (uintptr_t)payload, .bo_handles = (uintptr_t)handles,
        .num_bo_handles = 2, .fence_fd = -1
    };
    /* Do not retry an interrupted submission: acceptance may be ambiguous. */
    if (ops->submit_ioctl(ops->context, drm_fd, PINECONE_DRM_EXECBUFFER_IOCTL, &submit)) {
        int error = errno;
        if (submit.fence_fd >= 0) ops->close_fd(ops->context, submit.fence_fd);
        errno = error;
        return -1;
    }
    if (submit.fence_fd < 0) { errno = EPROTO; return -1; }
    *completion_fence_fd = submit.fence_fd;
    return 0;
}

static int real_poll(void *context, struct pollfd *fds, nfds_t count, int timeout) {
    (void)context; return poll(fds, count, timeout);
}
static int real_clock(void *context, struct timespec *ts) {
    (void)context; return clock_gettime(CLOCK_MONOTONIC, ts);
}
static int real_ioctl(void *context, int fd, unsigned long request, void *data) {
    (void)context;
#if defined(__linux__)
    return ioctl(fd, request, data);
#else
    (void)fd; (void)request; (void)data; errno = ENOTSUP; return -1;
#endif
}
static int real_close(void *context, int fd) { (void)context; return close(fd); }

int pinecone_drm_submit_layer(int drm_fd, const struct pinecone_layer *layer,
    int source_acquire_fd, int destination_acquire_fd, int timeout_ms,
    int *completion_fence_fd) {
    const struct pinecone_drm_ops ops = {NULL, real_poll, real_clock, real_ioctl, real_close};
    return pinecone_drm_submit_layer_with_ops(drm_fd, layer, source_acquire_fd,
        destination_acquire_fd, timeout_ms, completion_fence_fd, &ops);
}
