#ifdef WLROOTS_DMABUF_WAIT_TEST
/* Real Wayland loop/epoll, real pipe descriptors, upstream surface unlock and
 * the patched waiter. Only buffer attributes and commit effects are fixtures. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wayland-server.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/pixman.h>
#include <wlr/types/wlr_compositor.h>

static int polls, commits, errors, live_waits, live_fds;
static int poll_errno, fail_alloc, fail_dup, fail_fd, fail_timer, fail_update;
static uint32_t committed_seq[128];
static bool renderer_pixman = true;
static struct wlr_dmabuf_attributes attrs;
static int buffer_destroys;

static void buffer_fixture_destroy(struct wlr_buffer *buffer) {
    assert(buffer->n_locks == 0);
    buffer_destroys++;
}
#include "buffer-lifetime-under-test.inc"

bool wlr_buffer_get_dmabuf(struct wlr_buffer *buffer, struct wlr_dmabuf_attributes *a) {
    (void)buffer;
    *a = attrs;
    return true;
}
bool wlr_renderer_is_pixman(struct wlr_renderer *renderer) {
    (void)renderer;
    return renderer_pixman;
}
static void surface_commit_state(struct wlr_surface *surface, struct wlr_surface_state *next) {
    assert(next->cached_state_locks == 0);
    assert(commits < 128);
    committed_seq[commits++] = next->seq;
    surface->current.seq = next->seq;
    surface->current.width = next->width;
}
static void surface_state_destroy_cached(struct wlr_surface_state *state, struct wlr_surface *surface) {
    (void)surface;
    wl_list_remove(&state->cached_state_link);
    free(state);
}
#include "surface-unlock-under-test.inc"

static int wait_poll(struct pollfd *fds, nfds_t n, int timeout) {
    assert(n == 1 && timeout == 0 && fds->events == POLLIN);
    polls++;
    if (poll_errno) { errno = poll_errno; return -1; }
    return poll(fds, n, timeout);
}
static void *wait_calloc(size_t count, size_t size) {
    if (fail_alloc) return NULL;
    void *p = calloc(count, size);
    if (p) live_waits++;
    return p;
}
static void wait_free(void *p) { if (p) live_waits--; free(p); }
static int wait_dup(int fd, int cmd, int arg) {
    if (fail_dup) return -1;
    int result = fcntl(fd, cmd, arg);
    if (result >= 0) live_fds++;
    return result;
}
static int wait_close(int fd) { live_fds--; return close(fd); }
static struct wl_event_source *wait_add_fd(struct wl_event_loop *loop, int fd,
        uint32_t mask, wl_event_loop_fd_func_t func, void *data) {
    return fail_fd ? NULL : wl_event_loop_add_fd(loop, fd, mask, func, data);
}
static struct wl_event_source *wait_add_timer(struct wl_event_loop *loop,
        wl_event_loop_timer_func_t func, void *data) {
    return fail_timer ? NULL : wl_event_loop_add_timer(loop, func, data);
}
static int wait_timer_update(struct wl_event_source *source, int ms) {
    return fail_update ? -1 : wl_event_source_timer_update(source, ms);
}
static void wait_error(struct wl_client *client, const char *fmt, ...) {
    assert(client && fmt);
    errors++;
}
#define poll wait_poll
#define calloc wait_calloc
#define free wait_free
#define fcntl wait_dup
#define close wait_close
#define wl_event_loop_add_fd wait_add_fd
#define wl_event_loop_add_timer wait_add_timer
#define wl_event_source_timer_update wait_timer_update
#define wl_client_post_implementation_error wait_error
#include "dmabuf-wait-under-test.inc"
#undef poll
#undef calloc
#undef free
#undef fcntl
#undef close
#undef wl_event_loop_add_fd
#undef wl_event_loop_add_timer
#undef wl_event_source_timer_update
#undef wl_client_post_implementation_error

struct fixture {
    struct wl_display *display;
    struct wl_event_loop *loop;
    struct wl_client *client;
    struct wlr_renderer renderer;
    struct wlr_compositor compositor;
    struct wlr_surface surface;
    struct wlr_buffer buffer;
    int pipe[2], client_fd;
};
static const struct wlr_buffer_impl source_impl = {.destroy = buffer_fixture_destroy};
static void fixture_init(struct fixture *f) {
    *f = (struct fixture){0};
    assert(live_waits == 0 && live_fds == 0);
    polls = commits = errors = poll_errno = 0;
    fail_alloc = fail_dup = fail_fd = fail_timer = fail_update = 0;
    renderer_pixman = true;
    f->display = wl_display_create();
    assert(f->display);
    f->loop = wl_display_get_event_loop(f->display);
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
    f->client_fd = sockets[0];
    f->client = wl_client_create(f->display, sockets[1]);
    assert(f->client);
    f->surface.resource = wl_resource_create(f->client, &wl_surface_interface, 6, 0);
    assert(f->surface.resource);
    wl_signal_init(&f->renderer.events.destroy);
    wl_signal_init(&f->renderer.events.lost);
    wl_signal_init(&f->surface.events.destroy);
    wl_list_init(&f->surface.cached);
    f->compositor.renderer = &f->renderer;
    f->surface.compositor = &f->compositor;
    f->surface.current.width = 11; // Old content/geometry until ready.
    f->surface.pending.seq = 1;
    f->surface.pending.committed = WLR_SURFACE_STATE_BUFFER;
    f->surface.pending.width = 99;
    f->buffer.impl = &source_impl;
    f->surface.pending.buffer = &f->buffer;
    wl_signal_init(&f->buffer.events.release);
    buffer_destroys = 0;
    assert(pipe2(f->pipe, O_CLOEXEC | O_NONBLOCK) == 0);
    attrs = (struct wlr_dmabuf_attributes){.n_planes = 1, .fd = {f->pipe[0]}};
}
static void cache_pending(struct fixture *f) {
    struct wlr_surface_state *cached = calloc(1, sizeof(*cached));
    assert(cached);
    *cached = f->surface.pending;
    wl_list_insert(f->surface.cached.prev, &cached->cached_state_link);
    f->surface.pending.seq++;
    f->surface.pending.cached_state_locks = 0;
}
static void dispatch(struct fixture *f) { assert(wl_event_loop_dispatch(f->loop, 0) == 0); }
static void signal_ready(struct fixture *f) { assert(write(f->pipe[1], "x", 1) == 1); }
static struct pixman_dmabuf_wait *first_wait(struct fixture *f) {
    assert(!wl_list_empty(&f->surface.events.destroy.listener_list));
    struct wl_listener *listener = wl_container_of(f->surface.events.destroy.listener_list.next, listener, link);
    struct pixman_dmabuf_wait *wait = wl_container_of(listener, wait, surface_destroy);
    return wait;
}
static void fixture_finish(struct fixture *f) {
    wl_signal_emit_mutable(&f->surface.events.destroy, &f->surface);
    assert(wl_list_empty(&f->surface.events.destroy.listener_list));
    assert(wl_list_empty(&f->renderer.events.destroy.listener_list));
    assert(wl_list_empty(&f->renderer.events.lost.listener_list));
    struct wlr_surface_state *state, *tmp;
    wl_list_for_each_safe(state, tmp, &f->surface.cached, cached_state_link) {
        surface_state_destroy_cached(state, &f->surface);
    }
    assert(live_waits == 0 && live_fds == 0);
    close(f->pipe[0]);
    if (f->pipe[1] >= 0) close(f->pipe[1]);
    close(f->client_fd);
    wl_display_destroy_clients(f->display);
    wl_display_destroy(f->display);
}
static void event_readiness(void) {
    struct fixture f;
    fixture_init(&f);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    assert(f.surface.pending.cached_state_locks == 1);
    cache_pending(&f);
    for (int i = 0; i < 1000; i++) dispatch(&f);
    assert(polls == 1 && commits == 0 && f.surface.current.width == 11);
    signal_ready(&f);
    dispatch(&f);
    assert(polls == 2 && commits == 1 && f.surface.current.width == 99);
    assert(committed_seq[0] == 1 && live_waits == 0 && live_fds == 0);
    for (int i = 0; i < 1000; i++) dispatch(&f);
    assert(polls == 2 && commits == 1);
    fixture_finish(&f);

    fixture_init(&f);
    signal_ready(&f);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    assert(f.surface.pending.cached_state_locks == 0 && live_waits == 0);
    fixture_finish(&f);
}
static void event_ordering(void) {
    struct fixture f;
    fixture_init(&f);
    f.surface.pending.seq = UINT32_MAX;
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    int pipe2fds[2];
    assert(pipe2(pipe2fds, O_CLOEXEC | O_NONBLOCK) == 0);
    attrs.fd[0] = pipe2fds[0];
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    assert(write(pipe2fds[1], "y", 1) == 1);
    dispatch(&f);
    assert(commits == 0 && live_waits == 1);
    signal_ready(&f);
    dispatch(&f);
    assert(commits == 2 && committed_seq[0] == UINT32_MAX && committed_seq[1] == 0);
    close(pipe2fds[0]); close(pipe2fds[1]);
    fixture_finish(&f);

    fixture_init(&f);
    uint32_t other_lock = wlr_surface_lock_pending(&f.surface);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    signal_ready(&f);
    dispatch(&f);
    assert(commits == 0 && live_waits == 0);
    wlr_surface_unlock_cached(&f.surface, other_lock);
    assert(commits == 1);
    fixture_finish(&f);
}
static void event_cancellation(void) {
    for (int mode = 0; mode < 6; mode++) {
        struct fixture f;
        fixture_init(&f);
        assert(pixman_dmabuf_lock_surface(&f.surface));
        cache_pending(&f);
        if (mode == 0) wl_signal_emit_mutable(&f.surface.events.destroy, &f.surface);
        if (mode == 1) wl_signal_emit_mutable(&f.renderer.events.destroy, &f.renderer);
        if (mode == 2) wl_signal_emit_mutable(&f.renderer.events.lost, &f.renderer);
        if (mode == 3) { close(f.pipe[1]); f.pipe[1] = -1; dispatch(&f); }
        if (mode == 4) { f.compositor.renderer = NULL; signal_ready(&f); dispatch(&f); }
        if (mode == 5) { poll_errno = EIO; signal_ready(&f); dispatch(&f); }
        assert(commits == 0 && f.surface.current.width == 11);
        assert(errors == (mode != 0) && live_waits == 0 && live_fds == 0);
        dispatch(&f);
        assert(commits == 0);
        fixture_finish(&f);
    }
}
static void event_backoff(void) {
    struct fixture f;
    fixture_init(&f);
    signal_ready(&f);
    poll_errno = EINTR;
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    assert(first_wait(&f)->fd_source == NULL && first_wait(&f)->retry_ms == 16);
    // Disarm only the test timer while testing fd-spin independence; scheduler
    // delays on a loaded builder must not turn a valid timer fire into failure.
    assert(wl_event_source_timer_update(first_wait(&f)->timer, 0) == 0);
    for (int i = 0; i < 1000; i++) dispatch(&f);
    assert(polls == 1 && commits == 0);
    assert(wl_event_source_timer_update(first_wait(&f)->timer, 16) == 0);
    assert(poll(NULL, 0, 20) == 0);
    dispatch(&f);
    assert(polls == 2 && first_wait(&f)->retry_ms == 32);
    poll_errno = 0;
    assert(poll(NULL, 0, 40) == 0);
    dispatch(&f);
    assert(commits == 1 && live_waits == 0);
    fixture_finish(&f);

    fixture_init(&f);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    poll_errno = EAGAIN;
    signal_ready(&f);
    dispatch(&f);
    assert(first_wait(&f)->fd_source == NULL && commits == 0);
    char byte;
    assert(read(f.pipe[0], &byte, 1) == 1);
    poll_errno = 0;
    assert(poll(NULL, 0, 20) == 0);
    dispatch(&f);
    assert(first_wait(&f)->fd_source != NULL && commits == 0);
    int before = polls;
    for (int i = 0; i < 1000; i++) dispatch(&f);
    assert(polls == before);
    signal_ready(&f);
    dispatch(&f);
    assert(commits == 1);
    fixture_finish(&f);
}
static void event_failures(void) {
    for (int mode = 0; mode < 7; mode++) {
        struct fixture f;
        fixture_init(&f);
        if (mode == 0) fail_alloc = 1;
        if (mode == 1) fail_dup = 1;
        if (mode == 2) fail_fd = 1;
        if (mode == 3) { poll_errno = EINTR; fail_timer = 1; }
        if (mode == 4) { poll_errno = EINTR; fail_update = 1; }
        if (mode == 5) poll_errno = EBADF;
        if (mode == 6) attrs.n_planes = 2;
        assert(!pixman_dmabuf_lock_surface(&f.surface));
        assert(f.surface.pending.cached_state_locks == 0 && live_waits == 0 && live_fds == 0);
        fixture_finish(&f);
    }
    struct fixture f;
    fixture_init(&f);
    for (int i = 0; i < 64; i++) {
        assert(pixman_dmabuf_lock_surface(&f.surface));
        cache_pending(&f);
    }
    assert(!pixman_dmabuf_lock_surface(&f.surface));
    assert(live_waits == 64 && live_fds == 64 && f.surface.pending.cached_state_locks == 0);
    fixture_finish(&f);

    fixture_init(&f);
    renderer_pixman = false;
    assert(pixman_dmabuf_lock_surface(&f.surface) && polls == 0);
    renderer_pixman = true;
    f.surface.pending.buffer = NULL;
    assert(pixman_dmabuf_lock_surface(&f.surface) && polls == 0);
    f.surface.pending.buffer = &f.buffer;
    f.surface.pending.committed = 0;
    assert(pixman_dmabuf_lock_surface(&f.surface) && polls == 0);
    fixture_finish(&f);
}
static void event_rearm_failures(void) {
    for (int mode = 0; mode < 3; mode++) {
        struct fixture f;
        fixture_init(&f);
        assert(pixman_dmabuf_lock_surface(&f.surface));
        cache_pending(&f);
        poll_errno = EINTR;
        if (mode == 0) fail_timer = 1;
        if (mode == 1) fail_update = 1;
        signal_ready(&f);
        dispatch(&f);
        if (mode == 2) {
            char byte;
            assert(read(f.pipe[0], &byte, 1) == 1);
            poll_errno = 0;
            fail_fd = 1;
            assert(poll(NULL, 0, 20) == 0);
            dispatch(&f);
        }
        assert(errors == 1 && commits == 0 && live_waits == 0 && live_fds == 0);
        assert(f.surface.current.width == 11);
        fixture_finish(&f);
    }
}
static void event_buffer_lifetime(void) {
    struct fixture f;
    fixture_init(&f);
    // Upstream pending/cached states pin the buffer. Destroying wl_buffer drops
    // the producer reference, but cannot invalidate the queued source or fd.
    wlr_buffer_lock(&f.buffer);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    wlr_buffer_drop(&f.buffer);
    assert(f.buffer.dropped && f.buffer.n_locks == 1 && buffer_destroys == 0);
    signal_ready(&f);
    dispatch(&f);
    assert(commits == 1 && buffer_destroys == 0);
    wlr_buffer_unlock(&f.buffer);
    assert(buffer_destroys == 1);
    fixture_finish(&f);

    fixture_init(&f);
    wlr_buffer_lock(&f.buffer);
    assert(pixman_dmabuf_lock_surface(&f.surface));
    cache_pending(&f);
    wlr_buffer_drop(&f.buffer);
    wl_signal_emit_mutable(&f.surface.events.destroy, &f.surface);
    assert(commits == 0 && buffer_destroys == 0 && live_waits == 0);
    wlr_buffer_unlock(&f.buffer);
    assert(buffer_destroys == 1);
    fixture_finish(&f);
}
int main(void) {
    event_readiness();
    event_ordering();
    event_cancellation();
    event_backoff();
    event_failures();
    event_rearm_failures();
    event_buffer_lifetime();
    puts("PASS: real Wayland fd/timer dispatch; idle producer 1000 dispatches/1 poll; readiness commits exactly once; upstream cached ordering/wrap/other locks/buffer lifetime; error/reset/destroy cancellation; bounded transient backoff, rearm failures and waiter cap");
    return 0;
}
#else
/* Compile the patch's actual importer body against a deterministic DRM model.
 * Real host descriptors/mappings exercise ownership; only DRM/DMA ioctls and
 * device discovery are simulated. No Linux device or running guest is needed. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define FOURCC(a,b,c,d) ((uint32_t)(a) | (uint32_t)(b)<<8 | (uint32_t)(c)<<16 | (uint32_t)(d)<<24)
#define DRM_FORMAT_XRGB8888 FOURCC('X','R','2','4')
#define DRM_FORMAT_ARGB8888 FOURCC('A','R','2','4')
#define DRM_FORMAT_XBGR8888 FOURCC('X','B','2','4')
#define DRM_FORMAT_ABGR8888 FOURCC('A','B','2','4')
#define DRM_FORMAT_MOD_LINEAR UINT64_C(0)
#define DRM_FORMAT_MOD_INVALID UINT64_C(0x00ffffffffffffff)
#define DRM_NODE_PRIMARY 0
#define DRM_CAP_PRIME 5
#define DRM_PRIME_CAP_IMPORT 1
#define DRM_CLOEXEC 1
#define DMA_BUF_SYNC_READ 1
#define DMA_BUF_SYNC_START 0
#define DMA_BUF_SYNC_END 4
#define DMA_BUF_IOCTL_SYNC 99
#define WLR_BUFFER_DATA_PTR_ACCESS_READ 1
#define WLR_BUFFER_DATA_PTR_ACCESS_WRITE 2
#define WLR_ERROR 0
#define wlr_log_errno(...) ((void)0)
#define wl_container_of(ptr, sample, member) \
    ((__typeof__(sample))((char *)(ptr) - offsetof(__typeof__(*sample), member)))

struct dma_buf_sync { uint64_t flags; };
struct wlr_dmabuf_attributes {
    int32_t width, height;
    uint32_t format;
    uint64_t modifier;
    int n_planes;
    uint32_t offset[4], stride[4];
    int fd[4];
};
struct wlr_buffer;
struct wlr_buffer_impl {
    void (*destroy)(struct wlr_buffer *);
    bool (*begin_data_ptr_access)(struct wlr_buffer *, uint32_t, void **, uint32_t *, size_t *);
    void (*end_data_ptr_access)(struct wlr_buffer *);
};
struct wlr_buffer {
    const struct wlr_buffer_impl *impl;
    int width, height, locks;
    bool dropped, finished;
    struct wlr_dmabuf_attributes attributes;
};
struct wlr_drm_format_set {
    uint32_t formats[4];
    uint64_t modifiers[4];
    size_t count;
};

enum fault {
    NONE, ALLOC, DUP, SEEK_END_FAIL, SEEK_RESET_FAIL, NODE, NAME, OPEN, STAT,
    WRONG_DEVICE, PRIME, MAP, MMAP, POLL_FAIL, POLL_ERROR, POLL_TIMEOUT,
    SYNC_START_FAIL, SYNC_END_FAIL, UNMAP, CAP, NO_CAP, CREATE, EXPORT, FORMAT_ADD
};
static enum fault fault;
static int caller_fd, device_fd, duplicate_fd, imported_fd;
static int owned_fds, live_maps, allocations, handles, dumb_handles;
static int starts, ends, polls, retries_start, retries_end, retries_poll;
static int source_unlocks, source_finishes;
static off_t object_size = 64;
static uint64_t map_offset = 4096;
static char events[1024];
static size_t event_count;

static void event(char c) {
    assert(event_count + 1 < sizeof(events));
    events[event_count++] = c;
    events[event_count] = 0;
}
static bool fail(enum fault f) {
    if (fault != f) return false;
    errno = EIO;
    return true;
}
static void *test_calloc(size_t n, size_t size) {
    if (fail(ALLOC)) return NULL;
    void *p = calloc(n, size);
    if (p) allocations++;
    return p;
}
static void test_free(void *p) {
    if (p) allocations--;
    free(p);
}
static int test_open(const char *path, int flags) {
    assert(strcmp(path, "/dev/null") == 0);
    assert(flags == (O_RDWR | O_CLOEXEC));
    if (fail(OPEN)) return -1;
    int fd = open(path, flags);
    assert(fd >= 0 && fd != device_fd && fd != caller_fd);
    owned_fds++;
    imported_fd = fd;
    event('o');
    return fd;
}
static int test_fcntl(int fd, int cmd, int arg) {
    assert(cmd == F_DUPFD_CLOEXEC && arg == 0);
    if (fail(DUP)) return -1;
    int result = fcntl(fd, cmd, arg);
    assert(result >= 0 && result != fd);
    assert(fcntl(result, F_GETFD) & FD_CLOEXEC);
    owned_fds++;
    duplicate_fd = result;
    event('d');
    return result;
}
static int test_close(int fd) {
    assert(fd != caller_fd && fd != device_fd && fcntl(fd, F_GETFD) >= 0);
    owned_fds--;
    event('c');
    return close(fd);
}
static int test_fstat(int fd, struct stat *s) {
    if (fail(STAT)) return -1;
    int ret = fstat(fd, s);
    if (fault == WRONG_DEVICE && fd == imported_fd) s->st_rdev++;
    return ret;
}
static off_t test_lseek(int fd, off_t off, int whence) {
    assert(fd == duplicate_fd && off == 0);
    if (whence == SEEK_END) {
        event('s');
        return fail(SEEK_END_FAIL) ? -1 : object_size;
    }
    assert(whence == SEEK_SET);
    event('r');
    return fail(SEEK_RESET_FAIL) ? -1 : 0;
}
static int drmGetNodeTypeFromFd(int fd) {
    assert(fd >= 0);
    return fault == NODE ? 2 : DRM_NODE_PRIMARY;
}
static char *drmGetDeviceNameFromFd2(int fd) {
    assert(fd >= 0);
    if (fail(NAME)) return NULL;
    char *s = strdup("/dev/null");
    assert(s);
    allocations++;
    return s;
}
static int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle) {
    assert(fd == imported_fd && prime_fd == duplicate_fd);
    if (fail(PRIME)) return -1;
    handles++;
    *handle = 37;
    event('h');
    return 0;
}
static int drmCloseBufferHandle(int fd, uint32_t handle) {
    assert(fd >= 0 && handle == 37 && handles > 0);
    handles--;
    event('g');
    return 0;
}
static int drmModeMapDumbBuffer(int fd, uint32_t handle, uint64_t *offset) {
    assert(fd == imported_fd && handle == 37);
    if (fail(MAP)) return -1;
    *offset = map_offset;
    event('m');
    return 0;
}
static void *test_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    assert(!addr && prot == PROT_READ && flags == MAP_SHARED);
    assert(fd == imported_fd && (uint64_t)offset == map_offset);
    assert(length <= (size_t)object_size);
    if (fail(MMAP)) return MAP_FAILED;
    void *data = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(data != MAP_FAILED);
    memset(data, 0x5a, length);
    assert(mprotect(data, length, PROT_READ) == 0);
    live_maps++;
    event('M');
    return data;
}
static int test_munmap(void *data, size_t length) {
    if (fail(UNMAP)) return -1;
    assert(live_maps > 0);
    live_maps--;
    event('u');
    return munmap(data, length);
}
static int test_poll(struct pollfd *pfd, nfds_t n, int timeout) {
    assert(pfd->fd >= 0 && n == 1 && timeout == 0 && pfd->events == POLLIN);
    polls++;
    event('p');
    if (retries_poll-- > 0) { errno = EINTR; return -1; }
    if (fail(POLL_FAIL)) return -1;
    pfd->revents = fault == POLL_ERROR ? POLLIN | POLLERR : POLLIN;
    return fault == POLL_TIMEOUT ? 0 : 1;
}
static int test_ioctl(int fd, unsigned long request, struct dma_buf_sync *sync) {
    assert(fd >= 0 && request == DMA_BUF_IOCTL_SYNC);
    assert(sync->flags == DMA_BUF_SYNC_READ || sync->flags == (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_END));
    if (sync->flags & DMA_BUF_SYNC_END) {
        ends++;
        event('e');
        if (retries_end-- > 0) { errno = EAGAIN; return -1; }
        return fail(SYNC_END_FAIL) ? -1 : 0;
    }
    starts++;
    event('b');
    if (retries_start-- > 0) { errno = EINTR; return -1; }
    return fail(SYNC_START_FAIL) ? -1 : 0;
}
static int drmGetCap(int fd, uint64_t cap, uint64_t *value) {
    assert(fd >= 0 && cap == DRM_CAP_PRIME);
    *value = fault == NO_CAP ? 0 : DRM_PRIME_CAP_IMPORT;
    return fail(CAP) ? -1 : 0;
}
static int drmModeCreateDumbBuffer(int fd, uint32_t w, uint32_t h, uint32_t bpp,
        uint32_t flags, uint32_t *handle, uint32_t *stride, uint64_t *size) {
    assert(fd >= 0 && w == 1 && h == 1 && bpp == 32 && flags == 0);
    if (fail(CREATE)) return -1;
    *handle = 53;
    *stride = 4;
    *size = 64;
    dumb_handles++;
    return 0;
}
static int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime) {
    assert(fd >= 0 && handle == 53 && flags == DRM_CLOEXEC);
    if (fail(EXPORT)) return -1;
    *prime = open("/dev/null", O_RDWR | O_CLOEXEC);
    assert(*prime >= 0);
    owned_fds++;
    return 0;
}
static int drmModeDestroyDumbBuffer(int fd, uint32_t handle) {
    assert(fd >= 0 && handle == 53 && dumb_handles > 0);
    dumb_handles--;
    return 0;
}
static bool wlr_drm_format_set_add(struct wlr_drm_format_set *s, uint32_t format, uint64_t modifier) {
    if (fail(FORMAT_ADD)) return false;
    assert(s->count < 4);
    s->formats[s->count] = format;
    s->modifiers[s->count++] = modifier;
    return true;
}
static bool wlr_buffer_get_dmabuf(struct wlr_buffer *b, struct wlr_dmabuf_attributes *a) {
    if (b->attributes.n_planes == -1) return false;
    *a = b->attributes;
    return true;
}
static void wlr_buffer_init(struct wlr_buffer *b, const struct wlr_buffer_impl *impl, int w, int h) {
    *b = (struct wlr_buffer){ .impl = impl, .width = w, .height = h };
}
static void wlr_buffer_finish(struct wlr_buffer *b) {
    assert(!b->finished);
    b->finished = true;
}
static struct wlr_buffer *wlr_buffer_lock(struct wlr_buffer *b) { b->locks++; return b; }
static void wlr_buffer_unlock(struct wlr_buffer *b) {
    if (!b) return;
    assert(b->locks > 0);
    b->locks--;
    if (b->impl == NULL) { source_unlocks++; return; }
    if (!b->locks && b->dropped) b->impl->destroy(b);
}
static void wlr_buffer_drop(struct wlr_buffer *b) {
    assert(!b->dropped);
    b->dropped = true;
    if (!b->locks) b->impl->destroy(b);
}

#define calloc test_calloc
#define free test_free
#define open test_open
#define close test_close
#define fcntl test_fcntl
#define fstat test_fstat
#define lseek test_lseek
#define mmap test_mmap
#define munmap test_munmap
#define poll test_poll
#define ioctl test_ioctl
#include "dmabuf-under-test.inc"
#undef calloc
#undef free
#undef open
#undef close
#undef fcntl
#undef fstat
#undef lseek
#undef mmap
#undef munmap
#undef poll
#undef ioctl

static struct wlr_dmabuf_attributes valid(void) {
    return (struct wlr_dmabuf_attributes){
        .width = 3, .height = 2, .format = DRM_FORMAT_ARGB8888,
        .modifier = DRM_FORMAT_MOD_LINEAR, .n_planes = 1,
        .offset = {4}, .stride = {16}, .fd = {caller_fd, -1, -1, -1},
    };
}
static void clean(void) {
    assert(owned_fds == 0 && live_maps == 0 && handles == 0 && dumb_handles == 0 && allocations == 0);
    assert(fcntl(caller_fd, F_GETFD) >= 0 && fcntl(device_fd, F_GETFD) >= 0);
}
static void reset(void) {
    clean();
    fault = NONE;
    event_count = 0;
    events[0] = 0;
    starts = ends = polls = source_unlocks = source_finishes = 0;
    retries_start = retries_end = retries_poll = 0;
    object_size = 64;
    map_offset = 4096;
}
static void validation(void) {
    struct wlr_dmabuf_attributes a = valid();
    size_t length = 0;
    assert(validate_attributes(&a, &length) && length == 36);
    const uint32_t formats[] = {DRM_FORMAT_XRGB8888, DRM_FORMAT_ARGB8888,
        DRM_FORMAT_XBGR8888, DRM_FORMAT_ABGR8888};
    struct wlr_drm_format_set set = {0};
    assert(pixman_dmabuf_add_formats(&set) && set.count == 4);
    for (size_t i = 0; i < 4; i++) {
        a.format = formats[i];
        assert(validate_attributes(&a, &length));
        assert(set.formats[i] == formats[i] && set.modifiers[i] == DRM_FORMAT_MOD_LINEAR);
    }
    fault = FORMAT_ADD;
    assert(!pixman_dmabuf_add_formats(&set));
    reset();
#define BAD(field, value) do { a = valid(); a.field = (value); \
    assert(!validate_attributes(&a, &length)); \
    assert(!pixman_dmabuf_check_import(device_fd, &a)); clean(); } while (0)
    BAD(format, FOURCC('N','V','1','2'));
    BAD(format, FOURCC('R','G','1','6'));
    BAD(format, UINT32_MAX);
    BAD(modifier, DRM_FORMAT_MOD_INVALID);
    BAD(modifier, UINT64_C(0x0100000000000001));
    BAD(modifier, UINT64_MAX);
    BAD(n_planes, 0); BAD(n_planes, 2); BAD(n_planes, 4); BAD(n_planes, -1);
    BAD(fd[0], -1);
    BAD(width, 0); BAD(width, -1); BAD(width, INT32_MAX); BAD(width, 32768);
    BAD(height, 0); BAD(height, -1); BAD(height, INT32_MAX); BAD(height, 32768);
    BAD(stride[0], 0); BAD(stride[0], 8); BAD(stride[0], 13);
    BAD(stride[0], UINT32_MAX); BAD(stride[0], UINT32_C(0x80000000));
    BAD(offset[0], 1); BAD(offset[0], UINT32_MAX);
#undef BAD
    a = valid();
    a.offset[0] = UINT32_MAX - 3;
    assert(!pixman_dmabuf_check_import(device_fd, &a));
    clean();
    a = valid();
    object_size = 35;
    assert(!pixman_dmabuf_check_import(device_fd, &a));
    clean();
    object_size = 36;
    assert(pixman_dmabuf_check_import(device_fd, &a));
    clean();
    reset();
    map_offset = UINT64_MAX;
    assert(!pixman_dmabuf_check_import(device_fd, &a));
    clean();
}
static void cleanup_failures(void) {
    const enum fault faults[] = {ALLOC, DUP, SEEK_END_FAIL, SEEK_RESET_FAIL,
        NODE, NAME, OPEN, STAT, WRONG_DEVICE, PRIME, MAP, MMAP};
    for (size_t i = 0; i < sizeof(faults) / sizeof(faults[0]); i++) {
        reset();
        fault = faults[i];
        struct wlr_dmabuf_attributes a = valid();
        assert(!pixman_dmabuf_check_import(device_fd, &a));
        clean();
        if (fault == SYNC_START_FAIL) assert(starts == 1 && ends == 0);
        if (fault == SYNC_END_FAIL) assert(starts == 1 && ends == 1);
    }
}
static void lifetime_access(void) {
    reset();
    struct wlr_buffer source = {.width = 3, .height = 2, .attributes = valid()};
    struct wlr_buffer *b = pixman_dmabuf_import(device_fd, &source);
    assert(b && source.locks == 1 && source_unlocks == 0);
    assert(pixman_dmabuf_buffer_is_imported(b) && pixman_dmabuf_buffer_ok(b));
    assert(!pixman_dmabuf_buffer_is_imported(&source) && pixman_dmabuf_buffer_ok(NULL));
    assert(owned_fds == 2 && live_maps == 1 && handles == 1);
    assert(strcmp(events, "dsrohmM") == 0);
    int dupfd = duplicate_fd, drmfd = imported_fd;
    struct pixman_dmabuf_buffer *mapped = wl_container_of(b, mapped, base);
    void *data = NULL;
    uint32_t format = 0;
    size_t stride = 0;
    pixman_dmabuf_get_mapping(b, &data, &format, &stride);
    assert(data == (char *)mapped->mapping + 4 && format == DRM_FORMAT_ARGB8888 && stride == 16);
    assert(starts == 0 && ends == 0 && polls == 0);
    int before = starts;
    assert(!b->impl->begin_data_ptr_access(b, 0, &data, &format, &stride));
    assert(!b->impl->begin_data_ptr_access(b, 2, &data, &format, &stride));
    assert(!b->impl->begin_data_ptr_access(b, 3, &data, &format, &stride));
    assert(starts == before && !mapped->accessing);
    for (int i = 0; i < 3; i++) {
        assert(b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
        assert(data == (char *)mapped->mapping + 4 && format == DRM_FORMAT_ARGB8888 && stride == 16);
        assert(((const uint32_t *)data)[0] == UINT32_C(0x5a5a5a5a));
        assert(!b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
        b->impl->end_data_ptr_access(b);
        assert(pixman_dmabuf_buffer_ok(b) && !mapped->accessing);
    }
    assert(starts == 3 && ends == 3 && polls == 3);
    // Model the token retaining a wrapper lock after the texture releases it.
    wlr_buffer_lock(b);
    wlr_buffer_drop(b);
    assert(source.locks == 1 && live_maps == 1);
    wlr_buffer_unlock(b);
    assert(source.locks == 0 && source_unlocks == 1);
    assert(fcntl(dupfd, F_GETFD) == -1 && fcntl(drmfd, F_GETFD) == -1);
    assert(strstr(events, "ugcc"));
    clean();
    reset();
    source.attributes.width++;
    assert(!pixman_dmabuf_import(device_fd, &source));
    source.attributes = valid(); source.attributes.n_planes = -1;
    assert(!pixman_dmabuf_import(device_fd, &source));
    source.attributes = valid();
    assert(!pixman_dmabuf_import(-1, &source));
    clean();
}
static void sync_failures(void) {
    reset();
    retries_start = retries_end = retries_poll = 2;
    struct wlr_dmabuf_attributes a = valid();
    struct pixman_dmabuf_buffer *mapped = map_attributes(device_fd, &a);
    assert(mapped && begin_read(mapped) && end_read(mapped));
    assert(finish_mapping(mapped));
    assert(starts == 3 && ends == 3 && polls == 3);
    clean();
    for (int phase = 0; phase < 2; phase++) {
        reset();
        struct wlr_buffer source = {.width = 3, .height = 2, .attributes = valid()};
        struct wlr_buffer *b = pixman_dmabuf_import(device_fd, &source);
        assert(b);
        void *data = NULL;
        uint32_t format;
        size_t stride;
        if (phase == 0) {
            fault = SYNC_START_FAIL;
            assert(!b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
            assert(data == NULL);
        } else {
            assert(b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
            fault = SYNC_END_FAIL;
            b->impl->end_data_ptr_access(b);
        }
        assert(!pixman_dmabuf_buffer_ok(b));
        fault = NONE;
        assert(!b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
        wlr_buffer_drop(b);
        assert(source.locks == 0);
        clean();
    }
}
static void bounded_readiness(void) {
    const enum fault faults[] = {POLL_TIMEOUT, POLL_FAIL, POLL_ERROR, SYNC_START_FAIL, SYNC_END_FAIL};
    for (size_t i = 0; i < sizeof(faults) / sizeof(faults[0]); i++) {
        reset();
        fault = faults[i];
        struct wlr_dmabuf_attributes a = valid();
        assert(pixman_dmabuf_check_import(device_fd, &a));
        assert(starts == 0 && ends == 0 && polls == 0);
        clean();
    }
    for (int mode = 0; mode < 6; mode++) {
        reset();
        struct wlr_buffer source = {.width = 3, .height = 2, .attributes = valid()};
        struct wlr_buffer *b = pixman_dmabuf_import(device_fd, &source);
        assert(b);
        void *data = NULL;
        uint32_t format = 0;
        size_t stride = 0;
        if (mode == 0) fault = POLL_TIMEOUT;
        if (mode == 1) retries_poll = INT_MAX;
        if (mode == 2) retries_start = INT_MAX;
        if (mode == 3) fault = POLL_ERROR;
        if (mode == 4) fault = POLL_FAIL;
        if (mode == 5) {
            assert(b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
            retries_end = INT_MAX;
            b->impl->end_data_ptr_access(b);
            assert(ends == 8 && !pixman_dmabuf_buffer_ok(b));
        } else {
            assert(!b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
            assert(data == NULL && format == 0 && stride == 0 && ends == 0);
            assert(polls <= 8 && starts <= 8);
            if (mode < 3) {
                assert(pixman_dmabuf_buffer_ok(b));
                fault = NONE;
                retries_poll = retries_start = 0;
                assert(b->impl->begin_data_ptr_access(b, 1, &data, &format, &stride));
                b->impl->end_data_ptr_access(b);
            } else {
                assert(!pixman_dmabuf_buffer_ok(b));
            }
        }
        fault = NONE;
        wlr_buffer_drop(b);
        assert(source.locks == 0);
        clean();
    }
}
static void independent_imports(void) {
    reset();
    struct wlr_buffer source = {.width = 3, .height = 2, .attributes = valid()};
    struct wlr_buffer *a = pixman_dmabuf_import(device_fd, &source);
    struct wlr_buffer *b = pixman_dmabuf_import(device_fd, &source);
    assert(a && b && source.locks == 2);
    struct pixman_dmabuf_buffer *ma = wl_container_of(a, ma, base);
    struct pixman_dmabuf_buffer *mb = wl_container_of(b, mb, base);
    assert(ma->drm_fd != mb->drm_fd && ma->prime_fd != mb->prime_fd);
    assert(ma->handle == mb->handle); // Same numeric handle in separate namespaces.
    wlr_buffer_drop(a);
    assert(handles == 1 && source.locks == 1 && live_maps == 1);
    assert(pixman_dmabuf_buffer_ok(b));
    wlr_buffer_drop(b);
    clean();
}
static void failed_unmap_retains_backing(void) {
    reset();
    struct wlr_buffer source = {.width = 3, .height = 2, .attributes = valid()};
    struct wlr_buffer *b = pixman_dmabuf_import(device_fd, &source);
    assert(b);
    struct pixman_dmabuf_buffer *mapping = wl_container_of(b, mapping, base);
    fault = UNMAP;
    wlr_buffer_drop(b);
    assert(source.locks == 1 && live_maps == 1 && handles == 1 && owned_fds == 2);
    assert(b->finished);
    fault = NONE;
    assert(finish_mapping(mapping)); // Recover test resources; production fails closed.
    assert(source.locks == 0);
    clean();
}
static void probe(void) {
    reset();
    int fd = pixman_dmabuf_open_device(device_fd);
    assert(fd >= 0 && owned_fds == 1);
    assert(starts == 1 && ends == 1 && polls == 1);
    test_close(fd);
    clean();
    const enum fault faults[] = {NODE, NAME, OPEN, STAT, WRONG_DEVICE, CAP, NO_CAP,
        CREATE, EXPORT, DUP, PRIME, MAP, MMAP, SYNC_START_FAIL, SYNC_END_FAIL};
    for (size_t i = 0; i < sizeof(faults) / sizeof(faults[0]); i++) {
        reset();
        fault = faults[i];
        assert(pixman_dmabuf_open_device(device_fd) < 0);
        clean();
    }
}
int main(void) {
    caller_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    device_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    assert(caller_fd >= 0 && device_fd >= 0);
    validation();
    cleanup_failures();
    lifetime_access();
    sync_failures();
    bounded_readiness();
    independent_imports();
    failed_unmap_retains_backing();
    probe();
    clean();
    close(caller_fd);
    close(device_fd);
    puts("PASS: formats/modifiers, plane/stride/offset/size bounds, fd ownership, DRM mapping, bounded READ fences/retries, map-only protocol checks, failures, lifetime and device probing");
    return 0;
}
#endif
