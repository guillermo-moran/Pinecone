#include "pinecone_drm_transport.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>

struct state {
    int polls, submits, closes, mode, close_fd, last_timeout;
    uint64_t milliseconds;
};
enum { NORMAL, INTERRUPT, TIMEOUT, POLL_ERROR, FENCE_ERROR,
       SUBMIT_ERROR, MISSING_OUTPUT, ERROR_WITH_OUTPUT, PARTIAL, INTERRUPT_SUBMIT };

static int fake_clock(void *opaque, struct timespec *ts) {
    struct state *s = opaque;
    ts->tv_sec = (time_t)(s->milliseconds / 1000);
    ts->tv_nsec = (long)((s->milliseconds % 1000) * 1000000);
    s->milliseconds += 10;
    return 0;
}
static int fake_poll(void *opaque, struct pollfd *fds, nfds_t count, int timeout) {
    struct state *s = opaque;
    assert(count >= 1 && count <= 2);
    assert(timeout >= 0 && timeout <= 50);
    s->last_timeout = timeout;
    ++s->polls;
    if (s->mode == INTERRUPT && s->polls == 1) { errno = EINTR; return -1; }
    if (s->mode == TIMEOUT) return 0;
    if (s->mode == POLL_ERROR) { errno = EBADF; return -1; }
    if (s->mode == FENCE_ERROR) { fds[0].revents = POLLERR; return 1; }
    if (s->mode == PARTIAL && s->polls == 1) {
        assert(count == 2 && fds[0].fd == 10 && fds[1].fd == 11);
        fds[0].revents = POLLIN; return 1;
    }
    if (s->mode == PARTIAL) assert(count == 1 && fds[0].fd == 11);
    for (nfds_t i = 0; i < count; ++i) {
        assert(fds[i].events == POLLIN);
        fds[i].revents = POLLIN;
    }
    return (int)count;
}
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static int fake_ioctl(void *opaque, int fd, unsigned long request, void *argument) {
    struct state *s = opaque;
    struct pinecone_drm_execbuffer *submit = argument;
    assert(fd == 7 && request == 0xc0406442ul);
    assert(submit->flags == 2 && submit->size == 64 && submit->num_bo_handles == 2);
    assert(submit->ring_idx == 0 && submit->fence_fd == -1);
    const uint32_t *handles = (const void *)(uintptr_t)submit->bo_handles;
    const uint8_t *payload = (const void *)(uintptr_t)submit->command;
    assert(handles[0] == 17 && handles[1] == 29);
    assert(le32(payload) == 0x504e3244 && payload[4] == 3 && payload[6] == 2);
    assert(le32(payload + 12) == 17 && le32(payload + 16) == 29);
    ++s->submits;
    if (s->mode == SUBMIT_ERROR) { errno = ENOSYS; return -1; }
    if (s->mode == INTERRUPT_SUBMIT) { errno = EINTR; return -1; }
    if (s->mode == MISSING_OUTPUT) return 0;
    submit->fence_fd = 42;
    if (s->mode == ERROR_WITH_OUTPUT) { errno = EIO; return -1; }
    return 0;
}
static int fake_close(void *opaque, int fd) {
    struct state *s = opaque;
    ++s->closes; s->close_fd = fd; errno = EBADF; return 0;
}
static struct pinecone_layer layer(void) {
    return (struct pinecone_layer){
        .source = {17, 2, 2, PINECONE_LAYER_BGRA_PREMULTIPLIED},
        .destination = {29, 4, 4, PINECONE_LAYER_BGRA_PREMULTIPLIED},
        .crop = {0, 0, 2, 2}, .frame = {0, 0, 4, 4}, .alpha = 255
    };
}
static int run(struct state *s, int source, int destination, int timeout, int *output) {
    struct pinecone_layer l = layer();
    const struct pinecone_drm_ops ops = {s, fake_poll, fake_clock, fake_ioctl, fake_close};
    return pinecone_drm_submit_layer_with_ops(7, &l, source, destination, timeout, output, &ops);
}
int main(void) {
    int output;
    struct state s = {0};
    assert(run(&s, -1, -1, 50, &output) == 0 && output == 42);
    assert(s.polls == 0 && s.submits == 1 && s.closes == 0);
    s = (struct state){0};
    assert(run(&s, 10, 11, 50, &output) == 0 && output == 42);
    assert(s.polls == 1 && s.submits == 1 && s.closes == 0);
    s = (struct state){.mode = PARTIAL};
    assert(run(&s, 10, 11, 50, &output) == 0 && s.polls == 2);
    assert(s.last_timeout == 40);
    s = (struct state){.mode = INTERRUPT};
    assert(run(&s, 10, 10, 50, &output) == 0 && s.polls == 2);
    assert(s.last_timeout == 40 && s.closes == 0);
    const int modes[] = {TIMEOUT, POLL_ERROR, FENCE_ERROR, SUBMIT_ERROR,
                         MISSING_OUTPUT, ERROR_WITH_OUTPUT, INTERRUPT_SUBMIT};
    const int errors[] = {ETIMEDOUT, EBADF, EIO, ENOSYS, EPROTO, EIO, EINTR};
    for (unsigned i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
        s = (struct state){.mode = modes[i]}; output = 123;
        assert(run(&s, 10, 11, 50, &output) == -1);
        assert(output == -1 && errno == errors[i]);
        assert(s.submits == (i >= 3 ? 1 : 0));
        assert(s.closes == (modes[i] == ERROR_WITH_OUTPUT ? 1 : 0));
        if (s.closes) assert(s.close_fd == 42);
    }
    s = (struct state){.mode = TIMEOUT};
    assert(run(&s, 10, 11, 0, &output) == -1 && errno == ETIMEDOUT && s.polls == 1);
    s = (struct state){0};
    assert(run(&s, -2, -1, 50, &output) == -1 && errno == EINVAL);
    assert(s.submits == 0 && s.polls == 0);
    assert(run(&s, -1, -1, -1, &output) == -1 && errno == EINVAL);
    puts("Pinecone DRM transport mock checks passed");
    return 0;
}
