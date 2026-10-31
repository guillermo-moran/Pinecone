#include <stdlib.h>
static void *test_malloc(size_t);
static void *test_calloc(size_t, size_t);
static void test_free(void *);
static long test_syscall(long, long, long, long, long, long, long);
#define PINECONE_PIXMAN_TEST_SYSCALL test_syscall
#define malloc test_malloc
#define calloc test_calloc
#define free test_free
#include "rootfs/pinecone-pixman.c"
#undef malloc
#undef calloc
#undef free
#include "rootfs/pinecone-pixman.h"
#include <assert.h>
#include <stdbool.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <signal.h>

static int allocator_reentry, allocator_fail;
static void *test_malloc(size_t size) {
    if (!allocator_reentry) return malloc(size);
    if (allocator_fail) { errno = ENOMEM; return NULL; }
    assert(size <= 4096);
    void *result = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return result == MAP_FAILED ? NULL : result;
}
static void *test_calloc(size_t count, size_t size) {
    if (!allocator_reentry) return calloc(count, size);
    assert(size == 0 || count <= 4096 / size);
    void *result = test_malloc(count * size);
    if (result) memset(result, 0, count * size);
    return result;
}
static void test_free(void *pointer) {
    if (!allocator_reentry) { free(pointer); return; }
    if (pointer) assert(munmap(pointer, 4096) == 0);
}

static void test_allocator_mapping_reentry(void) {
    alarm(5);
    allocator_reentry = 1;
    pthread_mutex_lock(&pinecone_lock);
    void *first = pinecone_malloc(64);
    assert(first && pinecone_allocator_depth == 0);
    pinecone_free(first);
    unsigned char *second = pinecone_calloc(16, 4);
    assert(second && pinecone_allocator_depth == 0);
    for (unsigned i = 0; i < 64; ++i) assert(second[i] == 0);
    pinecone_free(second);
    allocator_fail = 1;
    assert(!pinecone_malloc(64) && errno == ENOMEM);
    assert(!pinecone_calloc(16, 4) && pinecone_allocator_depth == 0);
    allocator_fail = 0;
    // Ordinary anonymous allocations must not acquire the graphics lock either.
    void *anonymous = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(anonymous != MAP_FAILED);
    assert(pinecone_mapping_count == 0 && pinecone_allocator_depth == 0);
    pthread_mutex_unlock(&pinecone_lock);
    allocator_reentry = 0;
    assert(munmap(anonymous, 4096) == 0);
    alarm(0);
    puts("Pixman bridge: allocator mmap/munmap reentry passed");
}

static int mock_device, fail_submit, signal_submission;
static int mock_raw_fill;
static int mock_snapshot_device;
static unsigned snapshot_handles, snapshot_creates, snapshot_destroys;
static unsigned exec_count, kms_count, trace_count, trace[16], tags[8];
static long test_syscall(long number, long a, long b, long c, long d, long e, long f) {
    if (mock_snapshot_device && number == PINECONE_SYSCALL_MMAP && e == 42)
        return (long)syscall(number, 0, b, c, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mock_snapshot_device && number == PINECONE_SYSCALL_IOCTL && a == 42) {
        unsigned nr = (uint32_t)b & 0xffu;
        if (nr == PINECONE_DRM_IOCTL_MODE_CREATE_DUMB_NR) {
            struct pinecone_drm_mode_create_dumb *create = (void *)c;
            create->handle = ++snapshot_handles;
            create->pitch = create->width * 4;
            create->size = (uint64_t)create->pitch * create->height;
            ++snapshot_creates;
            return 0;
        }
        if (nr == PINECONE_DRM_IOCTL_MODE_MAP_DUMB_NR) {
            ((struct pinecone_drm_mode_map_dumb *)c)->offset = 0;
            return 0;
        }
        if (nr == PINECONE_DRM_IOCTL_MODE_DESTROY_DUMB_NR) {
            ++snapshot_destroys;
            return 0;
        }
    }
    if (mock_device && number == PINECONE_SYSCALL_IOCTL) {
        if (a == 42 && (uint32_t)b == PINECONE_IOWR(
                PINECONE_DRM_COMMAND_BASE + PINECONE_DRM_VIRTGPU_EXECBUFFER,
                struct pinecone_drm_execbuffer)) {
            ++exec_count;
            assert(trace_count < 16);
            trace[trace_count++] = 42;
            if (fail_submit) return -EIO;
            struct pinecone_drm_execbuffer *submit = (void *)c;
            struct pinecone_2d_batch *payload = (void *)(uintptr_t)submit->command;
            if (mock_raw_fill) {
                const struct pinecone_2d_payload *fill = (const void *)payload;
                assert(fill->version == PINECONE_EXACT_COMPOSITE_VERSION);
                assert(fill->operation == PINECONE_PIXMAN_OP_SRC);
                assert(fill->flags & PINECONE_SOURCE_IS_SOLID);
            } else {
                assert(payload->header.version == PINECONE_BATCH_VERSION);
                for (unsigned i = 0; i < payload->header.command_count; ++i) {
                    unsigned tag = payload->commands[i].destination_x;
                    assert(tag < 8);
                    ++tags[tag];
                }
            }
            submit->fence_fd = eventfd(signal_submission, EFD_CLOEXEC);
            assert(submit->fence_fd >= 0);
            return 0;
        }
        if (a == 77) {
            ++kms_count;
            assert(trace_count < 16);
            trace[trace_count++] = 77;
            return 0;
        }
    }
    long result = syscall(number, a, b, c, d, e, f);
    return result == -1 ? -errno : result;
}

static void reset_device(void) {
    assert(!pinecone_thread_batch.command_count && !pinecone_thread_batch.pending_count);
    mock_device = 1;
    fail_submit = 0;
    signal_submission = 1;
    exec_count = kms_count = trace_count = 0;
    memset(tags, 0, sizeof(tags));
}

#ifdef PINECONE_TEST_WLROOTS_COMMIT
// Minimal collaborators for the real upstream output commit function.
extern int pinecone_pixman_prepare_output_commit(void) __attribute__((weak));
struct wlr_output_state { uint32_t committed; void *buffer; };
struct wlr_output;
struct test_output_impl {
    bool (*commit)(struct wlr_output *, const struct wlr_output_state *);
};
struct wlr_output { const struct test_output_impl *impl; const char *name; };
static unsigned output_applied, output_events, buffer_unlocks;
static uint32_t output_compare_state(struct wlr_output *o, const struct wlr_output_state *s) {
    (void)o; (void)s; return 0;
}
static bool output_basic_test(struct wlr_output *o, const struct wlr_output_state *s) {
    (void)o; (void)s; return true;
}
static bool output_ensure_buffer(struct wlr_output *o, struct wlr_output_state *s, bool *new_buffer) {
    (void)o; (void)s; *new_buffer = true; return true;
}
static bool output_prepare_commit(struct wlr_output *o, struct wlr_output_state *s) {
    (void)o; (void)s; return true;
}
static void output_apply_commit(struct wlr_output *o, const struct wlr_output_state *s) {
    (void)o; (void)s; ++output_applied;
}
static void output_send_commit_event(struct wlr_output *o, const struct wlr_output_state *s) {
    (void)o; (void)s; ++output_events;
}
static void wlr_buffer_unlock(void *buffer) { (void)buffer; ++buffer_unlocks; }
static void (*test_legacy_commit)(void) = pinecone_pixman_output_commit;
static int (*test_checked_commit)(void) __attribute__((unused));
#define pinecone_pixman_output_commit test_legacy_commit
#define pinecone_pixman_prepare_output_commit test_checked_commit
#define wlr_log(...) ((void)0)
#include "wlroots-output-commit.inc"
#undef wlr_log
#undef pinecone_pixman_output_commit
#undef pinecone_pixman_prepare_output_commit

static bool test_kms_commit(struct wlr_output *o, const struct wlr_output_state *s) {
    (void)o; (void)s;
    return ioctl(77, 0, NULL) == 0;
}

static void queue_test_draw(unsigned tag, pixman_image_t *image) {
    struct pinecone_2d_payload payload = { .destination_x = tag };
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_enqueue_locked(42, &payload, 0, 0, tag + 1, NULL, NULL, image));
    pthread_mutex_unlock(&pinecone_lock);
}

static void test_output_commit_order(void) {
    reset_device();
    signal_submission = 0;
    test_checked_commit = pinecone_pixman_prepare_output_commit;
    const struct test_output_impl impl = { .commit = test_kms_commit };
    struct wlr_output output = { .impl = &impl, .name = "test" };
    const struct wlr_output_state state = {0};
    queue_test_draw(1, NULL);
    queue_test_draw(2, NULL);
    assert(wlr_output_commit_state(&output, &state));
    assert(trace_count == 2 && trace[0] == 42 && trace[1] == 77);
    assert(exec_count == 1 && tags[1] == 1 && tags[2] == 1);
    assert(output_applied == 1 && output_events == 1 && buffer_unlocks == 1);
    // The new boundary submits asynchronously; it does not drain the fence.
    assert(pinecone_thread_batch.pending_count == 1);
    int fence_fd = pinecone_thread_batch.pending[pinecone_thread_batch.pending_head].fence_fd;
    struct pollfd probe = { .fd = fence_fd, .events = POLLIN };
    assert(poll(&probe, 1, 0) == 0);
    signal_submission = 1;

    queue_test_draw(3, NULL);
    fail_submit = 1;
    assert(!wlr_output_commit_state(&output, &state));
    assert(kms_count == 1 && output_applied == 1 && output_events == 1);
    assert(buffer_unlocks == 2 && pinecone_thread_batch.command_count == 1);
    fail_submit = 0;
    assert(wlr_output_commit_state(&output, &state));
    assert(kms_count == 2 && tags[3] == 1 && buffer_unlocks == 3);
    uint64_t complete = 1;
    assert(write(fence_fd, &complete, sizeof(complete)) == sizeof(complete));
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_wait_all_pending_fences_locked() == 0);
    pthread_mutex_unlock(&pinecone_lock);

    // Old bridge ABI remains usable, but its flush must also precede KMS.
    test_checked_commit = NULL;
    trace_count = 0;
    queue_test_draw(4, NULL);
    assert(wlr_output_commit_state(&output, &state));
    assert(trace_count == 2 && trace[0] == 42 && trace[1] == 77);
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_wait_all_pending_fences_locked() == 0);
    pthread_mutex_unlock(&pinecone_lock);
    mock_device = 0;
    puts("Pixman output: exact base+DMA+ownership commit submits before separate-fd KMS, skips failed submit, retries retained draws and preserves legacy ABI");
}
#endif

static uint32_t image_word;
static unsigned unref_count;
static uint32_t *test_data(pixman_image_t *image) {
    (void)image;
    return &image_word;
}
static int test_stride(pixman_image_t *image) { (void)image; return 4; }
static int test_height(pixman_image_t *image) { (void)image; return 1; }
static pixman_image_t *test_ref(pixman_image_t *image) { return image; }
static pixman_bool_t test_unref(pixman_image_t *image) {
    (void)image;
    __atomic_add_fetch(&unref_count, 1u, __ATOMIC_RELAXED);
    return 0;
}

struct lease_image { uint32_t *pixels; unsigned refs; };
static uint32_t *lease_data(pixman_image_t *image) {
    return ((struct lease_image *)image)->pixels;
}
static pixman_image_t *lease_ref(pixman_image_t *image) {
    ++((struct lease_image *)image)->refs;
    return image;
}
static pixman_bool_t lease_unref(pixman_image_t *image) {
    struct lease_image *i = (struct lease_image *)image;
    assert(i->refs);
    return --i->refs == 0;
}
static pixman_format_code_t lease_format(pixman_image_t *image) {
    (void)image;
    return PINECONE_FORMAT_A8R8G8B8;
}
static void lease_release(void *owner) {
    // The callback may re-enter wlroots/Pixman; never run it under the lock.
    assert(pthread_mutex_trylock(&pinecone_lock) == 0);
    ++*(unsigned *)owner;
    pthread_mutex_unlock(&pinecone_lock);
}

struct reentrant_owner { void *mapping; unsigned released; };
static void reentrant_release(void *owner) {
    struct reentrant_owner *state = owner;
    ++state->released;
    assert(munmap(state->mapping, 4096) == 0);
}

static void test_reentrant_submission(void) {
    reset_device();
    real_get_data = lease_data;
    real_get_stride = test_stride;
    real_get_height = real_get_width = test_height;
    real_get_format = lease_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    struct reentrant_owner owner = {
        .mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
    };
    assert(owner.mapping != MAP_FAILED);
    uint32_t pixels[3] = {0};
    struct lease_image images[4] = {{ owner.mapping, 1 }};
    unsigned released = 0;
    for (unsigned i = 0; i < 4; ++i) {
        if (i) images[i] = (struct lease_image){ &pixels[i - 1], 1 };
        pixman_image_t *image = (pixman_image_t *)&images[i];
        struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
            images[i].pixels, 4, i ? (void *)&released : (void *)&owner,
            i ? lease_release : reentrant_release);
        assert(lease && pinecone_pixman_image_attach_buffer(image, lease));
        struct pinecone_2d_payload payload = { .destination_x = i + 1 };
        pthread_mutex_lock(&pinecone_lock);
        assert(pinecone_enqueue_locked(42, &payload, 0, 0, i + 1, NULL, NULL, image));
        pthread_mutex_unlock(&pinecone_lock);
        pinecone_pixman_buffer_unregister(lease);
        assert(!pixman_image_unref(image));
        pthread_mutex_lock(&pinecone_lock);
        assert(pinecone_flush_batch_locked() == 0);
        pthread_mutex_unlock(&pinecone_lock);
        if (i == 2) assert(pinecone_thread_batch.pending_count == 3 && !owner.released);
    }
    // Reaping the first lease at saturation destroyed its backing via munmap,
    // which recursively drained the fourth batch while the outer flush waited.
    assert(exec_count == 4 && tags[4] == 1);
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_wait_all_pending_fences_locked() == 0);
    pthread_mutex_unlock(&pinecone_lock);
    for (unsigned i = 0; i < 4; ++i) assert(images[i].refs == 0 && tags[i + 1] == 1);
    assert(owner.released == 1 && released == 3 && pinecone_buffers == NULL);
    assert(!pinecone_thread_batch.command_count && !pinecone_thread_batch.pending_count);
    mock_device = 0;
    puts("Pixman submission: saturated lease destruction re-enters munmap without duplicate submit or lost image retention");
}
static void *signal_fence(void *argument) {
    struct timespec delay = { .tv_nsec = 20000000 };
    nanosleep(&delay, NULL);
    uint64_t value = 1;
    assert(write(*(int *)argument, &value, sizeof(value)) == sizeof(value));
    return NULL;
}

static struct pinecone_pending_batch *stage_test_batch(unsigned signaled) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    unsigned index = (batch->pending_head + batch->pending_count) %
        PINECONE_MAX_IN_FLIGHT_BATCHES;
    struct pinecone_pending_batch *pending = &batch->pending[index];
    struct pinecone_fence_use *use = calloc(1, sizeof(*use));
    assert(use);
    use->fd = eventfd(signaled, EFD_CLOEXEC);
    assert(use->fd >= 0);
    use->graphics_fd = 42;
    use->count = batch->handle_count;
    memcpy(use->handles, batch->handles, use->count * sizeof(use->handles[0]));
    use->next = pinecone_fence_uses;
    pinecone_fence_uses = use;
    pending->use = use;
    pending->fence_fd = use->fd;
    pending->graphics_fd = 42;
    pending->image_count = batch->image_count;
    memcpy(pending->images, batch->images, batch->image_count * sizeof(batch->images[0]));
    ++batch->pending_count;
    pinecone_reset_batch_locked();
    return pending;
}

static unsigned cpu_fill_calls;
static pixman_bool_t test_cpu_fill(uint32_t *bits, int stride, int bpp,
    int x, int y, int width, int height, uint32_t value) {
    assert(pinecone_thread_batch.command_count == 0);
    assert(pinecone_thread_batch.pending_count == 0);
    ++cpu_fill_calls;
    for (int row = y; row < y + height; ++row) {
        for (int column = x; column < x + width; ++column) {
            if (bpp == 32) bits[row * stride + column] = value;
            else ((uint8_t *)bits)[row * stride * 4 + column] = (uint8_t)value;
        }
    }
    return 1;
}

static void test_foreign_fills(void) {
    reset_device();
    int saved_policy = pinecone_cpu_foreign_fill;
    pinecone_cpu_foreign_fill = 1;
    pixman_bool_t (*saved_fill)(uint32_t *, int, int, int, int, int, int, uint32_t) = real_fill;
    real_fill = test_cpu_fill;
    uint32_t pixels[8 * 5];
    uint64_t copied = pinecone_copyback_bytes;
    uint64_t direct_count = pinecone_cpu_fill_count, direct_bytes = pinecone_cpu_fill_bytes;
    unsigned creates = snapshot_creates;
    const uint32_t colors[] = {0, UINT32_MAX, 0xff123456, 0x70133729};
    for (unsigned bpp = 8; bpp <= 32; bpp += 24) {
        for (unsigned c = 0; c < sizeof(colors) / sizeof(colors[0]); ++c) {
            memset(pixels, 0xa5, sizeof(pixels));
            assert(pixman_fill(pixels, 8, bpp, 2, 1, 3, 2, colors[c]));
            for (unsigned y = 0; y < 5; ++y) {
                for (unsigned x = 0; x < 32 / (bpp / 8); ++x) {
                    bool inside = x >= 2 && x < 5 && y >= 1 && y < 3;
                    if (bpp == 32)
                        assert(pixels[y * 8 + x] == (inside ? colors[c] : 0xa5a5a5a5));
                    else
                        assert(((uint8_t *)pixels)[y * 32 + x] ==
                            (inside ? (uint8_t)colors[c] : 0xa5));
                }
            }
        }
    }
    assert(cpu_fill_calls == 8 && exec_count == 0 && snapshot_creates == creates);
    assert(pinecone_copyback_bytes == copied);
    assert(pinecone_cpu_fill_count - direct_count == 8);
    assert(pinecone_cpu_fill_bytes - direct_bytes == 120);

    // A raw CPU write must drain queued draws and wait for pending readers.
    struct pinecone_2d_payload draw = { .destination_x = 1 };
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_enqueue_locked(42, &draw, 0, 0, 7, NULL, NULL, NULL));
    pthread_mutex_unlock(&pinecone_lock);
    assert(pixman_fill(pixels, 8, 32, 0, 0, 8, 5, 0));
    assert(exec_count == 1 && cpu_fill_calls == 9);
    struct pinecone_pending_batch *pending = stage_test_batch(0);
    int fence = pending->fence_fd;
    pthread_t signaler;
    assert(pthread_create(&signaler, NULL, signal_fence, &fence) == 0);
    assert(pixman_fill(pixels, 8, 32, 0, 0, 8, 5, UINT32_MAX));
    assert(pthread_join(signaler, NULL) == 0 && cpu_fill_calls == 10);

    // An unproven completion must not fall through to an unsafe CPU write.
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        struct rlimit no_core = {0, 0};
        assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
        struct pinecone_pending_batch *failed = stage_test_batch(0);
        close(failed->fence_fd);
        (void)pixman_fill(pixels, 8, 32, 0, 0, 8, 5, 0);
        _exit(99);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);

    // A registered destination remains on the GPU even with CPU fills enabled.
    assert(pinecone_mapping_count == 0);
    pinecone_mappings[0] = (struct pinecone_mapping){
        .address = pixels, .length = sizeof(pixels), .fd = 42, .handle = 7};
    pinecone_mapping_count = 1;
    mock_raw_fill = 1;
    assert(pixman_fill(pixels, 8, 32, 0, 0, 8, 5, 0xff123456));
    assert(cpu_fill_calls == 10 && exec_count == 2);
    mock_raw_fill = 0;
    struct pinecone_fence_use *reader = calloc(1, sizeof(*reader));
    assert(reader);
    reader->fd = eventfd(0, EFD_CLOEXEC);
    assert(reader->fd >= 0);
    reader->graphics_fd = 42;
    reader->handles[0] = 7;
    reader->count = 1;
    reader->next = pinecone_fence_uses;
    pinecone_fence_uses = reader;
    uint64_t waits = pinecone_handle_blocking_waits;
    assert(pthread_create(&signaler, NULL, signal_fence, &reader->fd) == 0);
    assert(pixman_fill(pixels, 8, 32, 0, 0, 8, 5, 0x70133729));
    assert(pthread_join(signaler, NULL) == 0);
    assert(pinecone_handle_blocking_waits > waits);
    close(reader->fd);
    pinecone_remove_fence_use_locked(reader);
    assert(cpu_fill_calls == 11 && exec_count == 2);
    for (unsigned i = 0; i < 40; ++i) assert(pixels[i] == 0x70133729);
    pinecone_forget_mapping_locked(pixels);
    pinecone_cpu_foreign_fill = 0;
    assert(pixman_fill(pixels, 8, 32, 0, 0, 8, 5, 1));
    assert(cpu_fill_calls == 12 && exec_count == 2);
    for (unsigned i = 0; i < 40; ++i) assert(pixels[i] == 1);
    assert(pinecone_copyback_bytes == copied && snapshot_creates == creates);
    real_fill = saved_fill;
    pinecone_cpu_foreign_fill = saved_policy;
    mock_device = 0;
    puts("Pixman raw fills: direct CPU writes preserve padding/alpha and fences; opaque registered destinations stay accelerated without scratch copies");
}

static void test_client_snapshot_batching(void) {
    static uint32_t pixels[3];
    for (unsigned mapping_kind = 0; mapping_kind < 3; ++mapping_kind) {
        // No mapping models wl_shm; fd 43 models a separate-file PRIME import;
        // fd 42 models an unknown alias on the output's DRM file.
        struct lease_image src = { &pixels[0], 1 }, dst = { &pixels[1], 1 };
        struct lease_image mask = { &pixels[2], 1 };
        pixman_image_t *source = (pixman_image_t *)&src;
        pixman_image_t *destination = (pixman_image_t *)&dst;
        pixman_image_t *mask_image = (pixman_image_t *)&mask;
        unsigned released = 0;
        struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
            dst.pixels, 4, &released, lease_release);
        assert(lease && pinecone_pixman_image_attach_buffer(destination, lease));
        pthread_mutex_lock(&pinecone_lock);
        assert(pinecone_record_mapping_locked(dst.pixels, 4, 42, 90));
        if (mapping_kind) {
            int fd = mapping_kind == 1 ? 43 : 42;
            // Independent DRM files can reuse the output/snapshot handle IDs.
            assert(pinecone_record_mapping_locked(src.pixels, 4, fd,
                mapping_kind == 1 ? 90 : 91));
            assert(pinecone_record_mapping_locked(mask.pixels, 4, fd,
                mapping_kind == 1 ? 100 : 92));
        }
        struct pinecone_image_state *state = pinecone_image_state(source, 1);
        struct pinecone_image_state *mask_state = pinecone_image_state(mask_image, 1);
        // Mock preallocated DRM resources, not eligibility or upload behavior.
        uint32_t snapshots[4] = {0};
        struct pinecone_upload_surface surfaces[4];
        for (unsigned i = 0; i < 4; ++i) {
            surfaces[i] = (struct pinecone_upload_surface){
                .address = &snapshots[i], .length = 4, .width = 1, .height = 1,
                .pitch = 4, .fd = 42, .handle = 100 + i,
            };
        }
        state->source_cache = &surfaces[0];
        state->source_spares[0] = &surfaces[1];
        mask_state->mask_cache = &surfaces[2];
        mask_state->mask_spares[0] = &surfaces[3];
        pinecone_spare_bytes += 8;
        pthread_mutex_unlock(&pinecone_lock);
        pinecone_pixman_begin_render_pass();
        for (unsigned draw = 0; draw < 2; ++draw) {
            *src.pixels = 0xff112233 + draw;
            *mask.pixels = draw ? 0x80123456 : 0xff123456;
            pinecone_pixman_begin_cpu_access_flags(1);
            assert(pinecone_pixman_access_buffer(src.pixels, 4));
            assert(pinecone_pixman_access_buffer(mask.pixels, 4));
            assert(pixman_image_get_data(source) == src.pixels);
            assert(pixman_image_get_data(mask_image) == mask.pixels);
            assert(state->cpu_data_unbounded && state->scoped_cpu_access_count);
            assert(pinecone_image_has_cpu_hazard(state, 0));
            enum pinecone_fallback_reason reason;
            assert(pinecone_try_composite(PINECONE_PIXMAN_OP_OVER, source,
                mask_image, destination, 0, 0, 0, 0, 0, 0, 1, 1, &reason));
            assert(pinecone_thread_batch.command_count == draw + 1);
            pinecone_pixman_end_cpu_access();
        }
        pinecone_pixman_end_render_pass();
        *src.pixels = 0xdeadbeef;
        *mask.pixels = 0;
        assert(snapshots[0] == 0xff112233 && snapshots[1] == 0xff112234);
        assert(snapshots[2] == 0xff123456 && snapshots[3] == 0x80123456);
        assert(pinecone_thread_batch.command_count == 2);
        assert(src.refs == 2 && mask.refs == 2 && dst.refs == 2);
        pinecone_pixman_buffer_unregister(lease);
        assert(!pixman_image_unref(destination) && released == 0);
        pthread_mutex_lock(&pinecone_lock);
        (void)stage_test_batch(1);
        assert(pinecone_wait_all_pending_fences_locked() == 0);
        assert(released == 1);
        // Borrowed mock surfaces must not pass through the DRM/free teardown.
        state->source_cache = state->source_spares[0] = NULL;
        mask_state->mask_cache = mask_state->mask_spares[0] = NULL;
        pinecone_spare_bytes -= 8;
        pinecone_forget_mapping_locked(dst.pixels);
        if (mapping_kind) {
            pinecone_forget_mapping_locked(src.pixels);
            pinecone_forget_mapping_locked(mask.pixels);
        }
        pthread_mutex_unlock(&pinecone_lock);
        assert(pixman_image_unref(source) && pixman_image_unref(mask_image));
    }
    puts("Pixman client batching: scoped wl_shm, cross-fd imports and unknown mapped aliases retain independent source/mask snapshots across multiple composites");
}

struct region_image {
    struct lease_image base;
    int width, height, stride;
    pixman_format_code_t format;
};
static int region_width(pixman_image_t *image) { return ((struct region_image *)image)->width; }
static int region_height(pixman_image_t *image) { return ((struct region_image *)image)->height; }
static int region_stride(pixman_image_t *image) { return ((struct region_image *)image)->stride; }
static pixman_format_code_t region_format(pixman_image_t *image) {
    return ((struct region_image *)image)->format;
}

static void test_region_snapshots(void) {
    enum { W = 64, H = 32, PITCH = 272 };
    static uint32_t source_storage[4][PITCH * H / 4];
    static uint32_t destination_storage[4][8 * 8];
    real_get_data = lease_data;
    real_get_stride = region_stride;
    real_get_width = region_width;
    real_get_height = region_height;
    real_get_format = region_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    for (unsigned kind = 0; kind < 4; ++kind) {
        size_t bpp = kind == 2 ? 1 : 4;
        struct region_image src = {
            {source_storage[kind], 1}, W, H, PITCH,
            kind == 2 ? PINECONE_FORMAT_A8 : (kind == 1 ?
                PINECONE_FORMAT_X8R8G8B8 : PINECONE_FORMAT_A8R8G8B8),
        };
        struct region_image dst = {
            {destination_storage[kind], 1}, 8, 8, 32, PINECONE_FORMAT_A8R8G8B8,
        };
        pixman_image_t *source = (void *)&src, *destination = (void *)&dst;
        uint8_t *pixels = (void *)src.base.pixels;
        for (unsigned i = 0; i < PITCH * H; ++i) pixels[i] = (i * 13u + i / PITCH) & 255u;
        unsigned released = 0;
        struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
            dst.base.pixels, sizeof(destination_storage[kind]), &released, lease_release);
        assert(lease && pinecone_pixman_image_attach_buffer(destination, lease));
        pthread_mutex_lock(&pinecone_lock);
        assert(pinecone_record_mapping_locked(src.base.pixels, PITCH * H, 43, 90));
        assert(pinecone_record_mapping_locked(dst.base.pixels, sizeof(destination_storage[kind]), 42, 90));
        struct pinecone_image_state *state = pinecone_image_state(source, 1);
        if (kind == 3) {
            state->has_transform = 1;
            state->transform.matrix[0][0] = state->transform.matrix[1][1] = 2 << 16;
            state->filter = PINECONE_FILTER_BILINEAR;
        }
        uint8_t snapshots[2][PITCH * H];
        memset(snapshots, 0xa5, sizeof(snapshots));
        struct pinecone_upload_surface surfaces[2];
        for (unsigned i = 0; i < 2; ++i) surfaces[i] = (struct pinecone_upload_surface){
            .address = snapshots[i], .length = PITCH * H, .width = W, .height = H,
            .pitch = PITCH, .fd = 42, .handle = 100 + i,
        };
        state->source_cache = &surfaces[0];
        state->source_spares[0] = &surfaces[1];
        pinecone_spare_bytes += surfaces[1].length;
        pthread_mutex_unlock(&pinecone_lock);
        // A numerically equal scratch handle on another DRM file is unrelated.
        pinecone_uploads[PINECONE_UPLOAD_SOURCE].fd = 43;
        pinecone_uploads[PINECONE_UPLOAD_SOURCE].handle = 100;
        uint64_t copied = pinecone_source_copy_bytes, saved = pinecone_source_region_saved_bytes;
        uint64_t refreshes = pinecone_snapshot_hazard_refreshes;
        unsigned extent = kind == 3 ? 8 : 4, sx = kind == 3 ? 18 : 9, sy = kind == 3 ? 10 : 5;
        pinecone_pixman_begin_render_pass();
        if (kind == 3) {
            // Runtime's reflect-repeat scaled bilinear case must stay software.
            state->repeat = 2;
            state->transform.matrix[0][0] = 150513;
            state->transform.matrix[1][1] = 150655;
            enum pinecone_fallback_reason reason;
            assert(!pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, source, NULL,
                destination, 9, 5, 0, 0, 0, 0, 4, 4, &reason));
            assert(reason == PINECONE_FALLBACK_IMAGE_STATE);
            assert(pinecone_thread_batch.command_count == 0 && pinecone_source_copy_bytes == copied);
            state->repeat = PINECONE_REPEAT_NONE;
            state->transform.matrix[0][0] = state->transform.matrix[1][1] = 2 << 16;
        }
        for (unsigned draw = 0; draw < 2; ++draw) {
            enum pinecone_fallback_reason reason;
            assert(pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, source, NULL,
                destination, 9, 5, 0, 0, 0, 0, 4, 4, &reason));
            assert(pinecone_thread_batch.command_count == draw + 1);
            const struct pinecone_2d_payload *command = &pinecone_thread_batch.payload.commands[draw];
            assert(command->source_x == 0 && command->source_y == 0);
            assert(command->source_width == extent && command->source_height == extent);
            assert(((command->flags & PINECONE_FILTER_BILINEAR_FLAG) != 0) == (kind == 3));
            assert(((command->flags & PINECONE_SOURCE_PACKED_A8) != 0) == (kind == 2));
            for (unsigned y = 0; y < H; ++y) {
                for (unsigned x = 0; x < PITCH; ++x) {
                    uint8_t expected = y < extent && x < extent * bpp
                        ? pixels[(sy + y) * PITCH + sx * bpp + x] : 0xa5;
                    assert(snapshots[draw][y * PITCH + x] == expected);
                }
            }
            if (draw == 0) pixels[sy * PITCH + sx * bpp] ^= 0xff;
        }
        pinecone_pixman_end_render_pass();
        assert(snapshots[0][0] != snapshots[1][0]);
        uint64_t region_bytes = (uint64_t)extent * extent * bpp;
        assert(pinecone_source_copy_bytes - copied == 2 * region_bytes);
        assert(pinecone_source_region_saved_bytes - saved == 2 * ((uint64_t)W * H * bpp - region_bytes));
        assert(pinecone_snapshot_hazard_refreshes - refreshes == 2);
        memset(&pinecone_uploads[PINECONE_UPLOAD_SOURCE], 0, sizeof(pinecone_uploads[0]));
        pinecone_pixman_buffer_unregister(lease);
        assert(!pixman_image_unref(destination));
        pthread_mutex_lock(&pinecone_lock);
        (void)stage_test_batch(1);
        assert(pinecone_wait_all_pending_fences_locked() == 0 && released == 1);
        state->source_cache = state->source_spares[0] = NULL;
        pinecone_spare_bytes -= surfaces[1].length;
        pinecone_forget_mapping_locked(src.base.pixels);
        pinecone_forget_mapping_locked(dst.base.pixels);
        pthread_mutex_unlock(&pinecone_lock);
        assert(pixman_image_unref(source));
    }
    real_get_stride = test_stride;
    real_get_width = real_get_height = test_height;
    real_get_format = lease_format;
    puts("Pixman regions: ARGB/XRGB/A8 and bilinear extents rebase exactly, preserve padding and pending snapshots; 4x4 ARGB copies 64 bytes versus 8192 full-image bytes per draw");
}

static void test_registered_cache_hits(void) {
    static uint32_t pixels[4 * 4];
    unsigned released = 0;
    struct region_image src = {{pixels, 1}, 4, 4, 16, PINECONE_FORMAT_A8R8G8B8};
    pixman_image_t *source = (void *)&src;
    real_get_data = lease_data;
    real_get_stride = region_stride;
    real_get_width = region_width;
    real_get_height = region_height;
    real_get_format = region_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
        pixels, sizeof(pixels), &released, lease_release);
    assert(lease && pinecone_pixman_image_attach_buffer(source, lease));
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_record_mapping_locked(pixels, sizeof(pixels), 43, 80));
    struct pinecone_image_state *state = pinecone_image_state(source, 0);
    uint32_t copies[3][16] = {{0}};
    struct pinecone_upload_surface surfaces[3];
    for (unsigned i = 0; i < 3; ++i) surfaces[i] = (struct pinecone_upload_surface){
        .address = copies[i], .length = sizeof(pixels), .width = 4, .height = 4,
        .pitch = 16, .fd = 42, .handle = 100 + i,
    };
    state->source_cache = &surfaces[0];
    state->mask_cache = &surfaces[1];
    state->source_spares[0] = &surfaces[2];
    pinecone_spare_bytes += sizeof(pixels);
    assert(pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 1, 1, 3, 3, 4) == &surfaces[0]);
    assert(pinecone_prepare_mask_cache_locked(state, 42, (void *)pixels,
        16, 1, 1, 3, 3, src.format, 0) == &surfaces[1]);
    struct pinecone_fence_use *use = calloc(1, sizeof(*use));
    assert(use);
    use->fd = eventfd(0, EFD_CLOEXEC);
    assert(use->fd >= 0);
    use->graphics_fd = 43;
    use->count = 1;
    use->handles[0] = 80;
    use->next = pinecone_fence_uses;
    pinecone_fence_uses = use;
    uint64_t syncs = pinecone_image_sync_requests, waits = pinecone_handle_blocking_waits;
    uint64_t source_bytes = pinecone_source_copy_bytes, mask_bytes = pinecone_mask_copy_bytes;
    uint64_t source_hits = pinecone_source_cache_hits, mask_hits = pinecone_mask_cache_hits;
    pthread_t worker;
    assert(pthread_create(&worker, NULL, signal_fence, &use->fd) == 0);
    for (unsigned i = 0; i < 20; ++i) {
        assert(pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
            16, 4, 4, 2, 2, 2, 2, 4) == &surfaces[0]);
        assert(pinecone_prepare_mask_cache_locked(state, 42, (void *)pixels,
            16, 1, 1, 3, 3, src.format, 0) == &surfaces[1]);
    }
    assert(pinecone_source_copy_bytes == source_bytes && pinecone_mask_copy_bytes == mask_bytes);
    assert(pinecone_source_cache_hits - source_hits == 20 && pinecone_mask_cache_hits - mask_hits == 20);
    assert(pinecone_image_sync_requests == syncs && pinecone_handle_blocking_waits == waits);

    // Exercise the actual composite caller too: contained hits keep their
    // offset within the retained snapshot and must not pre-sync the backing.
    static uint32_t output[16];
    struct region_image dst = {{output, 1}, 4, 4, 16, PINECONE_FORMAT_A8R8G8B8};
    pixman_image_t *destination = (void *)&dst;
    assert(pinecone_record_mapping_locked(output, sizeof(output), 42, 90));
    pthread_mutex_unlock(&pinecone_lock);
    unsigned output_released = 0;
    struct pinecone_pixman_buffer *out = pinecone_pixman_buffer_register(
        output, sizeof(output), &output_released, lease_release);
    assert(out && pinecone_pixman_image_attach_buffer(destination, out));
    pinecone_pixman_begin_render_pass();
    enum pinecone_fallback_reason reason;
    assert(pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, source, NULL,
        destination, 2, 2, 0, 0, 0, 0, 2, 2, &reason));
    assert(pinecone_try_composite(PINECONE_PIXMAN_OP_OVER, source, source,
        destination, 1, 1, 1, 1, 0, 0, 3, 3, &reason));
    pinecone_pixman_end_render_pass();
    assert(pinecone_thread_batch.command_count == 2);
    const struct pinecone_2d_payload *command = pinecone_thread_batch.payload.commands;
    assert(command[0].source_x == 1 && command[0].source_y == 1);
    assert(command[0].source_width == 2 && command[0].source_height == 2);
    assert(command[1].source_x == 0 && command[1].source_y == 0);
    assert(pinecone_thread_batch.handles[command[0].source_resource_id - 1] == 100);
    assert(pinecone_thread_batch.handles[command[1].mask_resource_id - 1] == 101);
    assert(pinecone_image_sync_requests == syncs && pinecone_handle_blocking_waits == waits);
    assert(pinecone_source_copy_bytes == source_bytes && pinecone_mask_copy_bytes == mask_bytes);
    pinecone_pixman_buffer_unregister(out);
    assert(!pixman_image_unref(destination));
    pthread_mutex_lock(&pinecone_lock);
    (void)stage_test_batch(1);
    assert(pinecone_wait_all_pending_fences_locked() == 0 && output_released == 1);
    pinecone_forget_mapping_locked(output);
    assert(pthread_join(worker, NULL) == 0);
    close(use->fd);
    pinecone_remove_fence_use_locked(use);
    // Neither cache may return an equal-numbered resource from another DRM fd.
    assert(!pinecone_prepare_source_cache_locked(state, 44, (void *)pixels,
        16, 4, 4, 2, 2, 2, 2, 4));
    assert(!pinecone_prepare_mask_cache_locked(state, 44, (void *)pixels,
        16, 1, 1, 3, 3, src.format, 0));
    pthread_mutex_unlock(&pinecone_lock);
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 2));
    pixels[10] = 0x12345678;
    pinecone_pixman_buffer_end_cpu_access(lease, 2);
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 2, 2, 2, 2, 4) == &surfaces[0]);
    assert(copies[0][0] == pixels[10] && pinecone_source_copy_bytes == source_bytes + 16);
    // Disjoint requests cannot reuse a current-generation region accidentally.
    assert(pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 0, 0, 1, 1, 4) == &surfaces[0]);
    assert(copies[0][0] == pixels[0] && pinecone_source_copy_bytes == source_bytes + 20);

    // A failed refresh cannot leave metadata claiming a region is current.
    use = calloc(1, sizeof(*use));
    assert(use);
    use->fd = eventfd(0, EFD_CLOEXEC);
    assert(use->fd >= 0);
    close(use->fd);
    use->graphics_fd = 42;
    use->handles[0] = 100;
    use->handles[1] = 101;
    use->count = 2;
    use->next = pinecone_fence_uses;
    pinecone_fence_uses = use;
    assert(!pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 1, 0, 1, 1, 4));
    assert(state->source_cache_width == 0 && state->source_cache_height == 0);
    assert(!pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 0, 0, 1, 1, 4));
    assert(!pinecone_prepare_mask_cache_locked(state, 42, (void *)pixels,
        16, 1, 1, 3, 3, src.format, 0));
    assert(state->mask_cache_width == 0 && state->mask_cache_height == 0);
    pinecone_remove_fence_use_locked(use);
    pthread_mutex_unlock(&pinecone_lock);
    assert(pinecone_pixman_get_data_escaping(source) == pixels);
    pthread_mutex_lock(&pinecone_lock);
    pixels[0] = 0xabcdef01;
    assert(pinecone_prepare_source_cache_locked(state, 42, (void *)pixels,
        16, 4, 4, 0, 0, 1, 1, 4) == &surfaces[0]);
    assert(copies[0][0] == pixels[0]);
    state->source_cache = state->mask_cache = state->source_spares[0] = NULL;
    pinecone_spare_bytes -= sizeof(pixels);
    pinecone_forget_mapping_locked(pixels);
    pthread_mutex_unlock(&pinecone_lock);
    pinecone_pixman_buffer_unregister(lease);
    assert(pixman_image_unref(source) && released == 1);
    real_get_stride = test_stride;
    real_get_width = real_get_height = test_height;
    real_get_format = lease_format;
    puts("Pixman registered snapshots: 20 contained source and 20 exact mask hits copy zero bytes and issue zero backing syncs/waits; writes, disjoint regions, escapes and DRM-fd mismatch invalidate reuse");
}

static void test_mask_upload_formats(void) {
    enum { PITCH = 64, HEIGHT = 4, WIDTH = 7 };
    uint8_t source[PITCH * HEIGHT], output[PITCH * HEIGHT];
    for (size_t i = 0; i < sizeof(source); ++i)
        source[i] = (uint8_t)(i * 37u + 11u);
    const pixman_format_code_t formats[] = {
        PINECONE_FORMAT_A8, PINECONE_FORMAT_A8R8G8B8, PINECONE_FORMAT_X8R8G8B8
    };
    struct pinecone_upload_surface upload = {
        .address = output, .length = sizeof(output), .width = WIDTH,
        .height = HEIGHT, .pitch = PITCH, .fd = 42, .handle = 100
    };
    pthread_mutex_lock(&pinecone_lock);
    for (size_t f = 0; f < sizeof(formats) / sizeof(formats[0]); ++f) {
        for (int component = 0; component <= 1; ++component) {
            for (unsigned repeated_row = 0; repeated_row <= 1; ++repeated_row) {
                const size_t stride = repeated_row ? 0 : PITCH;
                const int packed = formats[f] == PINECONE_FORMAT_A8 && !component;
                const size_t bytes = WIDTH * (packed ? 1u : 4u);
                memset(output, 0xa5, sizeof(output));
                uint64_t before = pinecone_mask_copy_bytes;
                assert(pinecone_upload_mask_locked(&upload, 42, source, stride,
                    2, 1, WIDTH, 2, formats[f], component));
                assert(pinecone_mask_copy_bytes - before == bytes * 2);
                for (unsigned y = 0; y < HEIGHT; ++y) {
                    for (unsigned x = 0; x < PITCH; ++x) {
                        uint8_t expected = 0xa5;
                        if (y < 2 && x < bytes) {
                            if (packed)
                                expected = source[(y + 1) * stride + 2 + x];
                            else if (formats[f] == PINECONE_FORMAT_A8)
                                expected = x % 4 == 3
                                    ? source[(y + 1) * stride + 2 + x / 4] : 0;
                            else
                                expected = source[(y + 1) * stride + 8 + x];
                        }
                        assert(output[y * PITCH + x] == expected);
                    }
                }
            }
        }
    }
    pthread_mutex_unlock(&pinecone_lock);
    puts("Pixman mask uploads: packed A8, ARGB/XRGB rows, component alpha, offsets, zero stride and untouched padding passed");
}

static void test_mask_command_formats(void) {
    real_get_data = lease_data;
    real_get_stride = region_stride;
    real_get_width = region_width;
    real_get_height = region_height;
    real_get_format = region_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    for (int component = 0; component <= 1; ++component) {
        uint32_t pixels[3] = { 0xff112233, 0, 0x00000080 };
        uint32_t snapshot = 0xa5a5a5a5;
        struct region_image src = {{&pixels[0], 1}, 1, 1, 4, PINECONE_FORMAT_A8R8G8B8};
        struct region_image dst = {{&pixels[1], 1}, 1, 1, 4, PINECONE_FORMAT_A8R8G8B8};
        struct region_image mask = {{&pixels[2], 1}, 1, 1, 4, PINECONE_FORMAT_A8};
        struct pinecone_upload_surface cache = {
            .address = &snapshot, .length = 4, .width = 1, .height = 1,
            .pitch = 4, .fd = 42, .handle = 100
        };
        struct pinecone_pixman_buffer *leases[3];
        unsigned released = 0;
        pixman_image_t *images[] = {(void *)&src, (void *)&dst, (void *)&mask};
        for (unsigned i = 0; i < 3; ++i) {
            leases[i] = pinecone_pixman_buffer_register(&pixels[i], 4, &released, lease_release);
            assert(leases[i] && pinecone_pixman_image_attach_buffer(images[i], leases[i]));
            pthread_mutex_lock(&pinecone_lock);
            assert(pinecone_record_mapping_locked(&pixels[i], 4,
                i == 2 && !component ? 43 : 42, 90 + i));
            pthread_mutex_unlock(&pinecone_lock);
        }
        pthread_mutex_lock(&pinecone_lock);
        struct pinecone_image_state *state = pinecone_image_state(images[2], 0);
        state->mask_cache = &cache;
        state->unsafe_state = component ? 128u : 0;
        /* Scalar masks exercise the upload (not direct handle) path. The
         * component-alpha case must reject a direct packed A8 handle itself. */
        uint64_t copied = pinecone_mask_copy_bytes;
        pthread_mutex_unlock(&pinecone_lock);
        pinecone_pixman_begin_render_pass();
        enum pinecone_fallback_reason reason;
        assert(pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, images[0], images[2],
            images[1], 0, 0, 0, 0, 0, 0, 1, 1, &reason));
        pinecone_pixman_end_render_pass();
        assert(pinecone_thread_batch.command_count == 1);
        const struct pinecone_2d_payload *command = pinecone_thread_batch.payload.commands;
        assert(!!(command->flags & PINECONE_MASK_PACKED_A8) == !component);
        assert(!!(command->flags & PINECONE_MASK_COMPONENT_ALPHA) == component);
        assert(pinecone_thread_batch.handles[command->mask_resource_id - 1] == 100);
        assert(snapshot == (component ? 0x80000000u : 0xa5a5a580u));
        assert(pinecone_mask_copy_bytes - copied == (component ? 4u : 1u));
        for (unsigned i = 0; i < 3; ++i) {
            pinecone_pixman_buffer_unregister(leases[i]);
            assert(!pixman_image_unref(images[i]));
        }
        pthread_mutex_lock(&pinecone_lock);
        state->mask_cache = NULL;
        (void)stage_test_batch(1);
        assert(pinecone_wait_all_pending_fences_locked() == 0 && released == 3);
        for (unsigned i = 0; i < 3; ++i) pinecone_forget_mapping_locked(&pixels[i]);
        pthread_mutex_unlock(&pinecone_lock);
    }
    puts("Pixman mask commands: uploaded A8 advertises packed format; component-alpha A8 rejects direct replicated coverage and retains zero RGB coverage");
}

static pixman_image_t *snapshot_create(pixman_format_code_t format,
        int width, int height, uint32_t *data, int stride) {
    struct region_image *image = calloc(1, sizeof(*image));
    assert(image && data);
    *image = (struct region_image){{data, 1}, width, height, stride, format};
    return (void *)image;
}

static pixman_bool_t snapshot_unref(pixman_image_t *image) {
    struct region_image *region = (void *)image;
    if (--region->base.refs) return 0;
    free(region);
    return 1;
}

static void test_owned_shm_snapshots(void) {
    uint8_t input[96], output[96];
    for (unsigned i = 0; i < sizeof(input); ++i) input[i] = (uint8_t)(i * 13u);
    for (size_t rows = 0; rows <= 4; ++rows) {
        for (size_t bytes = 0; bytes <= 16; bytes += 4) {
            for (size_t spad = 0; spad <= 4; spad += 4) {
                for (size_t dpad = 0; dpad <= 4; dpad += 4) {
                    memset(output, 0xa5, sizeof(output));
                    size_t stride = bytes + spad, pitch = bytes + dpad;
                    size_t calls = pinecone_copy_pixel_rows(output + 4, pitch,
                        input + 4, stride, bytes, rows);
                    assert(calls == (!bytes || !rows ? 0 : (!spad && !dpad ? 1 : rows)));
                    for (size_t i = 0; i < sizeof(output); ++i) {
                        uint8_t expected = 0xa5;
                        for (size_t row = 0; row < rows; ++row)
                            if (i >= 4 + row * pitch && i < 4 + row * pitch + bytes)
                                expected = input[4 + row * stride + i - (4 + row * pitch)];
                        assert(output[i] == expected);
                    }
                }
            }
        }
    }
    const uint64_t creates_before = pinecone_shm_creates;
    const uint64_t initial_before = pinecone_shm_initial_bytes;
    const uint64_t updates_before = pinecone_shm_updates;
    const uint64_t bytes_before = pinecone_shm_update_bytes;
    const uint64_t empty_before = pinecone_shm_empty_updates;
    const uint64_t draws_before = pinecone_shm_direct_draws;
    const uint64_t releases_before = pinecone_shm_releases;
    const uint64_t invalid_before = pinecone_shm_invalid;
    const uint64_t rejected_before = pinecone_shm_update_rejects;
    const uint64_t budget_before = pinecone_shm_budget_rejects;
    real_create_bits_no_clear = snapshot_create;
    real_get_data = lease_data;
    real_get_stride = region_stride;
    real_get_width = region_width;
    real_get_height = region_height;
    real_get_format = region_format;
    real_ref = lease_ref;
    real_unref = snapshot_unref;
    pinecone_owned_graphics_fd = 42;
    mock_snapshot_device = 1;
    snapshot_handles = 1000;
    uint32_t source[8] = {0xff123456, 0xffabcdef, 0xdeadbeef, 0xdeadbeef,
                          0xff654321, 0xfffedcba, 0xdeadbeef, 0xdeadbeef};
    for (unsigned format = 0; format < 2; ++format) {
        pixman_format_code_t code = format ? PINECONE_FORMAT_X8R8G8B8 : PINECONE_FORMAT_A8R8G8B8;
        uint64_t copied = pinecone_source_copy_bytes;
        pixman_image_t *image = pinecone_pixman_snapshot_bits(code, 2, 2, source, 16);
        assert(image && pinecone_snapshot_bytes > 0);
        struct region_image *region = (void *)image;
        uint8_t *pixels = (void *)region->base.pixels;
        assert(!memcmp(pixels, source, 8));
        assert(!memcmp(pixels + region->stride, source + 4, 8));
        assert(pinecone_source_copy_bytes - copied == 16);
        for (unsigned y = 0; y < 2; ++y)
            for (int x = 8; x < region->stride; ++x) assert(pixels[y * region->stride + x] == 0);
        uint32_t prior = source[0];
        source[0] ^= UINT32_MAX;
        assert(*(uint32_t *)pixels == prior);
        source[0] = prior;

        pixman_box32_t damage[] = {{1, 0, 2, 1}, {0, 1, 1, 2}};
        uint32_t saved = source[1];
        source[1] = 0xff998877;
        copied = pinecone_source_copy_bytes;
        assert(pinecone_pixman_update_snapshot(image, source, 16, damage, 2));
        assert(pinecone_source_copy_bytes - copied == 8);
        assert(((uint32_t *)pixels)[0] == prior && ((uint32_t *)pixels)[1] == source[1]);
        assert(!memcmp(pixels + region->stride, source + 4, 8));
        source[1] = saved;
        uint32_t unchanged = ((uint32_t *)pixels)[1];
        pixman_box32_t invalid[] = {{1, 0, 2, 1}, {0, 0, 3, 1}};
        assert(!pinecone_pixman_update_snapshot(image, source, 16, invalid, 2));
        assert(((uint32_t *)pixels)[1] == unchanged);
        assert(pinecone_pixman_update_snapshot(image, source, 16, NULL, 0));
        assert(!pinecone_pixman_update_snapshot(image, pixels, region->stride, damage, 2));
        assert(!pinecone_pixman_update_snapshot(image, source, 7, damage, 2));
        assert(!pinecone_pixman_update_snapshot(image, source, 16, damage, 4097));
        assert(pinecone_source_copy_bytes - copied == 8);

        struct pinecone_fence_use *failed = calloc(1, sizeof(*failed));
        assert(failed);
        failed->fd = eventfd(0, EFD_CLOEXEC);
        assert(failed->fd >= 0);
        close(failed->fd);
        failed->graphics_fd = 42;
        failed->count = 1;
        pthread_mutex_lock(&pinecone_lock);
        failed->handles[0] = pinecone_image_state(image, 0)->owned_surface->handle;
        failed->next = pinecone_fence_uses;
        pinecone_fence_uses = failed;
        pthread_mutex_unlock(&pinecone_lock);
        assert(!pinecone_pixman_update_snapshot(image, source, 16, damage, 2));
        assert(((uint32_t *)pixels)[1] == unchanged);
        assert(pinecone_source_copy_bytes - copied == 8);
        pthread_mutex_lock(&pinecone_lock);
        pinecone_remove_fence_use_locked(failed);
        pthread_mutex_unlock(&pinecone_lock);

        /* The same private source is drawn twice without copying its bytes. */
        pixman_image_t *destination = pinecone_pixman_snapshot_bits(code, 2, 2, source, 16);
        assert(destination);
        copied = pinecone_source_copy_bytes;
        pinecone_pixman_begin_render_pass();
        enum pinecone_fallback_reason reason;
        for (unsigned draw = 0; draw < 2; ++draw)
            assert(pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, image, NULL,
                destination, 0, 0, 0, 0, 0, 0, 2, 2, &reason));
        pinecone_pixman_end_render_pass();
        assert(pinecone_thread_batch.command_count == 2);
        assert(pinecone_source_copy_bytes == copied);
        /* Updating a pending reader must wait for its fence before writing. */
        pthread_mutex_lock(&pinecone_lock);
        struct pinecone_pending_batch *pending = stage_test_batch(0);
        int fence = pending->fence_fd;
        pthread_mutex_unlock(&pinecone_lock);
        pthread_t signaler;
        assert(pthread_create(&signaler, NULL, signal_fence, &fence) == 0);
        assert(pinecone_pixman_update_snapshot(image, source, 16, damage, 2));
        assert(pthread_join(signaler, NULL) == 0);
        assert(pinecone_source_copy_bytes - copied == 8);
        assert(!pixman_image_unref(image) && !pixman_image_unref(destination));
        pthread_mutex_lock(&pinecone_lock);
        assert(pinecone_wait_all_pending_fences_locked() == 0);
        pthread_mutex_unlock(&pinecone_lock);
        assert(pinecone_snapshot_bytes == 0);
    }
    unsigned created = snapshot_creates;
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8, 2, 2, source, 16));
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8R8G8B8, 2, 2, NULL, 16));
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8R8G8B8, 2, 2, source, 7));
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8R8G8B8, 2, 2, source, SIZE_MAX));
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8R8G8B8, INT_MAX, INT_MAX, source, SIZE_MAX));
    assert(snapshot_creates == created);
    pinecone_snapshot_bytes = pinecone_snapshot_budget;
    assert(!pinecone_pixman_snapshot_bits(PINECONE_FORMAT_A8R8G8B8, 2, 2, source, 16));
    assert(pinecone_snapshot_bytes == pinecone_snapshot_budget);
    pinecone_snapshot_bytes = 0;
    assert(snapshot_creates == snapshot_destroys);
    assert(pinecone_shm_creates - creates_before == 4);
    assert(pinecone_shm_initial_bytes - initial_before == 64);
    assert(pinecone_shm_updates - updates_before == 6);
    assert(pinecone_shm_update_bytes - bytes_before == 32);
    assert(pinecone_shm_empty_updates - empty_before == 2);
    assert(pinecone_shm_direct_draws - draws_before == 4);
    assert(pinecone_shm_releases - releases_before == 4);
    assert(pinecone_shm_invalid - invalid_before == 5);
    assert(pinecone_shm_update_rejects - rejected_before == 10);
    assert(pinecone_shm_budget_rejects - budget_before == 1);
    uint32_t packed[480 * 3];
    for (unsigned i = 0; i < 480 * 3; ++i) packed[i] = 0xff000000u | i;
    uint64_t calls_before = pinecone_shm_copy_calls;
    pixman_image_t *exact = pinecone_pixman_snapshot_bits(
        PINECONE_FORMAT_A8R8G8B8, 480, 3, packed, 480 * 4);
    assert(exact && real_get_stride(exact) == 480 * 4);
    assert(pinecone_snapshot_bytes == sizeof(packed));
    assert(pinecone_shm_copy_calls - calls_before == 1);
    assert(!memcmp(real_get_data(exact), packed, sizeof(packed)));
    pixman_box32_t full = {0, 0, 480, 3};
    packed[100] ^= 1;
    assert(pinecone_pixman_update_snapshot(exact, packed, 480 * 4, &full, 1));
    assert(pinecone_shm_copy_calls - calls_before == 2);
    assert(!memcmp(real_get_data(exact), packed, sizeof(packed)));
    pixman_box32_t empty_edges[] = {{480, 3, 480, 3}, {1, 3, 480, 3}, {480, 1, 480, 3}};
    assert(pinecone_pixman_update_snapshot(exact, packed, 480 * 4, empty_edges, 3));
    assert(pinecone_shm_copy_calls - calls_before == 2);
    assert(!memcmp(real_get_data(exact), packed, sizeof(packed)));
    assert(pixman_image_unref(exact));
    assert(pinecone_snapshot_bytes == 0);
    struct pinecone_upload_surface *scratch = pinecone_allocate_image_surface_locked(42, 480, 3);
    assert(scratch && scratch->width == 512 && scratch->height == 64);
    pinecone_release_image_surface_locked(scratch);
    assert(snapshot_creates == snapshot_destroys);
    mock_snapshot_device = 0;
    pinecone_owned_graphics_fd = -1;
    real_create_bits_no_clear = NULL;
    puts("Pixman committed snapshots: independent ARGB/XRGB bytes, damage-only updates, validation before write, fenced readers/destruction, zero-copy repeat draws and 16 MiB budget passed");
}

static void test_buffer_leases(void) {
    static uint32_t pixels[8];
    unsigned released = 0;
    real_get_data = lease_data;
    real_get_stride = test_stride;
    real_get_height = real_get_width = test_height;
    real_get_format = lease_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    test_client_snapshot_batching();
    struct lease_image a = { &pixels[0], 1 }, b = { &pixels[1], 1 };
    pixman_image_t *image = (pixman_image_t *)&a, *dest = (pixman_image_t *)&b;
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    assert(pinecone_image_has_cpu_hazard(state, 0));
    struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
        a.pixels, 4, &released, lease_release);
    struct pinecone_pixman_buffer *out = pinecone_pixman_buffer_register(
        b.pixels, 4, &released, lease_release);
    assert(lease && out);
    assert(!pinecone_pixman_image_attach_buffer(dest, lease)); // Out of range.
    assert(pinecone_pixman_image_attach_buffer(image, lease));
    assert(pinecone_pixman_image_attach_buffer(dest, out));
    assert(state->cpu_data_unbounded); // Provenance is not silently cleared.
    assert(!pinecone_image_has_cpu_hazard(state, 1));
    assert(!pinecone_pixman_buffer_begin_cpu_access(lease, 0));
    uint64_t generation = state->cpu_generation;
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 1));
    assert(!pinecone_image_has_cpu_hazard(state, 0));
    assert(pinecone_image_has_cpu_hazard(state, 1));
    pinecone_pixman_buffer_end_cpu_access(lease, 1);
    assert(state->cpu_generation == generation);
    pinecone_pixman_begin_cpu_access_flags(1);
    assert(pixman_image_get_data(image) == a.pixels);
    assert(!pinecone_image_has_cpu_hazard(state, 0));
    assert(pinecone_image_has_cpu_hazard(state, 1));
    pinecone_pixman_end_cpu_access();
    assert(state->cpu_generation == generation);
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 2));
    assert(pinecone_image_has_cpu_hazard(state, 0));
    assert(state->cpu_generation > generation);
    generation = state->cpu_generation;
    state->source_cache_generation = state->mask_cache_generation = generation;
    *a.pixels = 42;
    pinecone_pixman_buffer_end_cpu_access(lease, 2);
    assert(state->cpu_generation > generation);
    assert(state->source_cache_generation != state->cpu_generation);
    assert(state->mask_cache_generation != state->cpu_generation);

    uint32_t cached_pixel = 0;
    struct pinecone_upload_surface cache = {
        .address = &cached_pixel, .length = 4, .width = 1, .height = 1,
        .pitch = 4, .fd = 43, .handle = 81,
    };
    state->source_cache = &cache;
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 2));
    assert(pinecone_prepare_source_cache_locked(state, 43,
        (const uint8_t *)a.pixels, 4, 1, 1, 0, 0, 1, 1, 4) == &cache);
    assert(cached_pixel == 42);
    *a.pixels = 99; // The final CPU write happens after the intermediate upload.
    pinecone_pixman_buffer_end_cpu_access(lease, 2);
    assert(pinecone_prepare_source_cache_locked(state, 43,
        (const uint8_t *)a.pixels, 4, 1, 1, 0, 0, 1, 1, 4) == &cache);
    assert(cached_pixel == 99);
    state->source_cache = NULL;

    // Raw wlroots mappings join the token scope without calling image_get_data.
    pinecone_pixman_begin_cpu_access_flags(1);
    assert(pinecone_pixman_access_buffer(a.pixels, 4));
    assert(!pinecone_image_has_cpu_hazard(state, 0));
    assert(pinecone_image_has_cpu_hazard(state, 1));
    pinecone_pixman_begin_cpu_access_flags(2);
    assert(pinecone_pixman_access_buffer(a.pixels, 4));
    pinecone_pixman_end_cpu_access();
    assert(pinecone_image_has_cpu_hazard(state, 0));
    generation = state->cpu_generation;
    pinecone_pixman_end_cpu_access();
    assert(state->cpu_generation > generation);
    assert(!pinecone_image_has_cpu_hazard(state, 1));

    // Different images over the same bytes share CPU hazards, not trust.
    struct lease_image alias = { a.pixels, 1 };
    pixman_image_t *alias_image = (pixman_image_t *)&alias;
    pinecone_pixman_begin_cpu_access_flags(2);
    assert(pixman_image_get_data(alias_image) == a.pixels);
    assert(pinecone_image_has_cpu_hazard(state, 0));
    pinecone_pixman_end_cpu_access();
    assert(pinecone_image_has_cpu_hazard(pinecone_image_state(alias_image, 0), 0));
    assert(pixman_image_unref(alias_image));

    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_record_mapping_locked(a.pixels, 4, 42, 71));
    assert(pinecone_record_mapping_locked(b.pixels, 4, 42, 72));
    pthread_mutex_unlock(&pinecone_lock);
    enum pinecone_fallback_reason reason;
    for (unsigned frame = 0; frame < 2; ++frame) {
        pinecone_pixman_begin_render_pass();
        assert(pinecone_try_composite(PINECONE_PIXMAN_OP_SRC, image, NULL, dest,
            0, 0, 0, 0, 0, 0, 1, 1, &reason));
        pinecone_pixman_end_render_pass();
        assert(pinecone_thread_batch.command_count == frame + 1);
    }
    assert(a.refs == 2 && b.refs == 2);

    // Model the device's queued->inflight handoff with a real unsignaled fence.
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    struct pinecone_pending_batch *pending = stage_test_batch(0);
    struct pinecone_fence_use *use = pending->use;
    pthread_mutex_unlock(&pinecone_lock);

    // Actual CPU access waits on the submitted reader, even via a token.
    pthread_t thread;
    int fence = use->fd;
    assert(pthread_create(&thread, NULL, signal_fence, &fence) == 0);
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 2));
    assert(pthread_join(thread, NULL) == 0);
    pinecone_pixman_buffer_end_cpu_access(lease, 2);
    pinecone_pixman_buffer_unregister(lease);
    pinecone_pixman_buffer_unregister(out);
    assert(pinecone_image_has_cpu_hazard(state, 0));
    assert(!pixman_image_unref(image) && !pixman_image_unref(dest));
    assert(released == 0 && a.refs == 1 && b.refs == 1);

    // A new renderer lease over the same storage batches while the previous
    // frame still owns its images. Retiring one lease never revokes another.
    struct lease_image next = { b.pixels, 1 };
    pixman_image_t *next_image = (pixman_image_t *)&next;
    struct pinecone_pixman_buffer *next_lease = pinecone_pixman_buffer_register(
        next.pixels, 4, &released, lease_release);
    assert(next_lease && pinecone_pixman_image_attach_buffer(next_image, next_lease));
    uint64_t completed;
    assert(read(use->fd, &completed, sizeof(completed)) == sizeof(completed));
    pinecone_pixman_begin_render_pass();
    assert(pinecone_try_composite(PINECONE_PIXMAN_OP_CLEAR, NULL, NULL, next_image,
        0, 0, 0, 0, 0, 0, 1, 1, &reason));
    pinecone_pixman_end_render_pass();
    assert(batch->pending_count == 1 && batch->command_count == 1);
    pinecone_pixman_buffer_unregister(next_lease);
    assert(!pixman_image_unref(next_image));
    pthread_mutex_lock(&pinecone_lock);
    (void)stage_test_batch(1);
    pthread_mutex_unlock(&pinecone_lock);

    // Fence errors must not dispose of backing locks or spin the drain loop.
    pthread_mutex_lock(&pinecone_lock);
    close(use->fd);
    assert(pinecone_wait_all_pending_fences_locked() == -1);
    assert(batch->pending_count == 2 && released == 0);
    use->fd = pending->fence_fd = eventfd(1, EFD_CLOEXEC);
    assert(use->fd >= 0);
    assert(pinecone_wait_all_pending_fences_locked() == 0);
    assert(released == 3 && a.refs == 0 && b.refs == 0 && next.refs == 0);
    pinecone_forget_mapping_locked(a.pixels);
    pinecone_forget_mapping_locked(b.pixels);
    pthread_mutex_unlock(&pinecone_lock);

    // Escapes through an unknown alias poison current and future registrations,
    // including after the alias image is destroyed or a lease is retired.
    a = (struct lease_image){ &pixels[2], 1 };
    alias = (struct lease_image){ a.pixels, 1 };
    lease = pinecone_pixman_buffer_register(a.pixels, 4, &released, lease_release);
    assert(lease && pinecone_pixman_image_attach_buffer(image, lease));
    state = pinecone_image_state(image, 0);
    pinecone_pixman_begin_cpu_access_flags(1);
    assert(pinecone_pixman_get_data_escaping(alias_image) == a.pixels);
    pinecone_pixman_end_cpu_access();
    assert(pinecone_image_has_cpu_hazard(state, 0));
    assert(pixman_image_unref(alias_image));
    pinecone_pixman_buffer_unregister(lease);
    assert(pixman_image_unref(image));
    assert(!pinecone_pixman_buffer_register(a.pixels, 4, &released, lease_release));
    assert(released == 4);
    assert(!pinecone_pixman_buffer_register((void *)(UINTPTR_MAX - 1), 4,
        &released, lease_release));
    assert(pinecone_buffers == NULL);

    // Explicit CPU scopes retain the backing even after registration/image
    // destruction, and raw unscoped aliases cannot be blessed by a new token.
    a = (struct lease_image){ &pixels[4], 1 };
    lease = pinecone_pixman_buffer_register(a.pixels, 4, &released, lease_release);
    assert(lease && pinecone_pixman_image_attach_buffer(image, lease));
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 3));
    pinecone_pixman_buffer_unregister(lease);
    assert(pixman_image_unref(image) && released == 4);
    pinecone_pixman_buffer_end_cpu_access(lease, 3);
    assert(released == 5 && pinecone_buffers == NULL);
    assert(pinecone_pixman_access_buffer(&pixels[5], 4));
    assert(!pinecone_pixman_buffer_register(&pixels[5], 4, &released, lease_release));

    // An unobserved external destination must not bypass hazard checks merely
    // because no setter/get_data hook has created its state yet.
    a = (struct lease_image){ &pixels[3], 1 };
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_record_mapping_locked(a.pixels, 4, 42, 73));
    pthread_mutex_unlock(&pinecone_lock);
    uint64_t rejected = pinecone_batch_rejection_hazard_count;
    pinecone_pixman_begin_render_pass();
    assert(!pinecone_try_composite(PINECONE_PIXMAN_OP_CLEAR, NULL, NULL, image,
        0, 0, 0, 0, 0, 0, 1, 1, &reason)); // No GPU at fd 42.
    pinecone_pixman_end_render_pass();
    assert(pinecone_batch_rejection_hazard_count == rejected + 1);
    assert(pinecone_thread_batch.command_count == 0);
    assert(pixman_image_unref(image));
    pthread_mutex_lock(&pinecone_lock);
    pinecone_forget_mapping_locked(a.pixels);
    pthread_mutex_unlock(&pinecone_lock);
    puts("Pixman ownership: unknown aliases, read/write scopes, end-write invalidation, cross-frame batching and fenced backing leases passed");
}

static void *shared_only_thread(void *argument) {
    assert(pinecone_register_thread());
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_fence_use *use = calloc(1, sizeof(*use));
    assert(use != NULL);
    use->fd = eventfd(1, EFD_CLOEXEC);
    assert(use->fd >= 0);
    use->next = pinecone_fence_uses;
    pinecone_fence_uses = use;
    struct pinecone_pending_batch *pending = &pinecone_thread_batch.pending[0];
    pending->fence_fd = use->fd;
    pending->use = use;
    pending->image_count = 1;
    pending->images[0] = argument;
    pinecone_thread_batch.pending_count = 1;
    pthread_mutex_unlock(&pinecone_lock);
    return NULL;
}

struct reader {
    int fence;
    uint32_t *pixels;
};

static void *complete_reader(void *argument) {
    struct reader *reader = argument;
    struct timespec delay = { .tv_nsec = 20000000 };
    nanosleep(&delay, NULL);
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += 2;
    // Unrelated threads can grow the table while the caller waits for its BO.
    assert(pthread_mutex_timedlock(&pinecone_lock, &deadline) == 0);
    struct pinecone_image_state *stable = pinecone_image_state((pixman_image_t *)&image_word, 0);
    assert(stable != NULL);
    assert(pinecone_rehash_images_locked(pinecone_image_capacity * 2));
    assert(pinecone_image_state((pixman_image_t *)&image_word, 0) == stable);
    // A submitted reader must see the old contents until it signals its fence.
    assert(*reader->pixels == 0x11223344);
    uint64_t done = 1;
    assert(write(reader->fence, &done, sizeof(done)) == sizeof(done));
    pthread_mutex_unlock(&pinecone_lock);
    return NULL;
}

static void test_escape_range_bounds(void) {
    static uint8_t arena[(PINECONE_MAX_ESCAPED_RANGES + 16) * 16];
    static uint8_t overflow_arena[10000 * 8];
    static uint32_t clean_pixels[3];
    unsigned released = 0;
    real_get_data = lease_data;
    real_ref = lease_ref;
    real_unref = lease_unref;
    struct lease_image image = { &clean_pixels[0], 1 };
    struct lease_image unattached = { &clean_pixels[1], 1 };
    struct pinecone_pixman_buffer *lease = pinecone_pixman_buffer_register(
        image.pixels, 4, &released, lease_release);
    struct pinecone_pixman_buffer *other = pinecone_pixman_buffer_register(
        unattached.pixels, 4, &released, lease_release);
    assert(lease && other);
    assert(pinecone_pixman_image_attach_buffer((pixman_image_t *)&image, lease));
    struct pinecone_image_state *state = pinecone_image_state((pixman_image_t *)&image, 0);
    assert(!pinecone_image_has_cpu_hazard(state, 1));
    assert(sizeof(pinecone_escaped_ranges) == 64 * 1024);

    pthread_mutex_lock(&pinecone_lock);
    size_t prior = pinecone_escaped_range_count;
    assert(!pinecone_escape_tracking_failed && prior < PINECONE_MAX_ESCAPED_RANGES - 3);
    pinecone_record_range_escape_locked(arena + 32, 4);
    pinecone_record_range_escape_locked(arena + 40, 4);
    assert(pinecone_escaped_range_count == prior + 2);
    pinecone_record_range_escape_locked(arena + 36, 4); // Bridge both adjacent ranges.
    assert(pinecone_escaped_range_count == prior + 1);
    for (unsigned i = 0; i < 10000; ++i)
        pinecone_record_range_escape_locked(arena + 32 + i % 12, 1);
    assert(pinecone_escaped_range_count == prior + 1);
    pinecone_record_range_escape_locked(arena + 28, 20); // Extend both ends.
    pinecone_record_range_escape_locked(arena + 16, 4);
    pinecone_record_range_escape_locked(arena + 64, 4);
    assert(pinecone_escaped_range_count == prior + 3);
    pinecone_record_range_escape_locked(arena + 20, 44); // Merge three intervals.
    assert(pinecone_escaped_range_count == prior + 1);
    assert(!pinecone_range_escaped_locked((uintptr_t)arena, 16));
    assert(!pinecone_range_escaped_locked((uintptr_t)(arena + 68), 4));
    for (unsigned i = 16; i < 68; ++i)
        assert(pinecone_range_escaped_locked((uintptr_t)(arena + i), 1));
    pthread_mutex_unlock(&pinecone_lock);

    // Lifetime churn and address reuse do not remove earlier escape history.
    for (unsigned i = 0; i < 5000; ++i) {
        struct pinecone_pixman_buffer *reuse = pinecone_pixman_buffer_register(
            arena + 80, 4, &released, lease_release);
        assert(reuse);
        pinecone_pixman_buffer_unregister(reuse);
        assert(!pinecone_pixman_buffer_register(arena + 32, 4, &released, lease_release));
    }
    assert(released == 5000 && pinecone_escaped_range_count == prior + 1);
    assert(pinecone_pixman_access_buffer(arena + 80, 4));
    assert(!pinecone_pixman_buffer_register(arena + 80, 4, &released, lease_release));

    pthread_mutex_lock(&pinecone_lock);
    size_t inserted = 0;
    while (pinecone_escaped_range_count < PINECONE_MAX_ESCAPED_RANGES) {
        pinecone_record_range_escape_locked(arena + 128 + inserted * 16, 4);
        ++inserted;
    }
    assert(inserted > 4000 && !pinecone_escape_tracking_failed);
    for (size_t i = 0; i < inserted; ++i) {
        uintptr_t address = (uintptr_t)(arena + 128 + i * 16);
        assert(pinecone_range_escaped_locked(address, 4));
        assert(!pinecone_range_escaped_locked(address + 4, 12));
        pinecone_record_range_escape_locked((void *)address, 4);
    }
    assert(pinecone_escaped_range_count == PINECONE_MAX_ESCAPED_RANGES);
    assert(!pinecone_escape_tracking_failed);
    // Merging at capacity must succeed and make room for a distinct interval.
    pinecone_record_range_escape_locked(arena + 132, 12);
    assert(pinecone_escaped_range_count == PINECONE_MAX_ESCAPED_RANGES - 1);
    pinecone_record_range_escape_locked(arena + 128 + inserted * 16, 4);
    assert(pinecone_escaped_range_count == PINECONE_MAX_ESCAPED_RANGES);
    assert(!pinecone_escape_tracking_failed);
    for (size_t i = 1; i < pinecone_escaped_range_count; ++i)
        assert(pinecone_escaped_ranges[i - 1].end < pinecone_escaped_ranges[i].start);
    pinecone_record_range_escape_locked(arena + 128 + (inserted + 1) * 16, 4);
    assert(pinecone_escape_tracking_failed);
    for (unsigned i = 0; i < 10000; ++i)
        pinecone_record_range_escape_locked(overflow_arena + i * 8, 4);
    assert(pinecone_escaped_range_count == PINECONE_MAX_ESCAPED_RANGES);
    assert(pinecone_image_has_cpu_hazard(state, 0));
    assert(pinecone_image_has_cpu_hazard(state, 1));
    struct pinecone_image_state bridge_owned = {0};
    assert(!pinecone_image_has_cpu_hazard(&bridge_owned, 1));
    pthread_mutex_unlock(&pinecone_lock);

    // Saturation poisons even previously clean external leases, never admits
    // a replacement token, and cannot be undone by normal scope/lifetime ends.
    assert(!pinecone_pixman_image_attach_buffer((pixman_image_t *)&unattached, other));
    assert(!pinecone_pixman_buffer_register(&clean_pixels[2], 4, &released, lease_release));
    assert(pinecone_pixman_buffer_begin_cpu_access(lease, 1));
    pinecone_pixman_buffer_end_cpu_access(lease, 1);
    pinecone_pixman_begin_render_pass();
    pinecone_pixman_end_render_pass();
    assert(pinecone_image_has_cpu_hazard(state, 1));
    pinecone_pixman_buffer_unregister(lease);
    pinecone_pixman_buffer_unregister(other);
    assert(pixman_image_unref((pixman_image_t *)&image));
    assert(pixman_image_unref((pixman_image_t *)&unattached));
    assert(released == 5002 && pinecone_buffers == NULL);
    assert(pinecone_escape_tracking_failed);
    assert(!pinecone_pixman_buffer_register(arena + 80, 4, &released, lease_release));
    puts("Pixman escapes: coalescing, 5000 lease reuses, 4096-interval cap and 10000 overflow ranges stay bounded and fail closed");
}

static void test_solid_color_encoding(void) {
    unsigned token;
    pixman_image_t *image = (pixman_image_t *)&token;
    // Sweep every 16-bit component, including non-replicated low bytes and
    // non-premultiplied inputs: the bridge must match Pixman, not normalize it.
    for (unsigned v = 0; v <= UINT16_MAX; ++v) {
        pixman_color_t color = { .red = v, .green = UINT16_MAX - v,
            .blue = v ^ 0x55aa, .alpha = (v * 73u) & UINT16_MAX };
        pinecone_pixman_created_solid(image, &color);
        pthread_mutex_lock(&pinecone_lock);
        struct pinecone_image_state *state = pinecone_image_state(image, 0);
        assert(state && state->is_solid);
        assert(state->solid_color == ((uint32_t)(color.alpha >> 8) << 24 |
            (uint32_t)(color.red >> 8) << 16 | (uint32_t)(color.green >> 8) << 8 |
            (uint32_t)(color.blue >> 8)));
        pthread_mutex_unlock(&pinecone_lock);
    }
    pthread_mutex_lock(&pinecone_lock);
    pinecone_remove_image_state_locked(pinecone_image_state(image, 0));
    pthread_mutex_unlock(&pinecone_lock);
    puts("Pixman solid encoding: premultiplied components and all 16-bit truncation boundaries match upstream");
}

static void test_small_composite_policy(void) {
    struct pinecone_image_state solid = { .is_solid = 1 }, mask = {0};
    int saved = pinecone_cpu_small_composite;
    pinecone_cpu_small_composite = 1;
    assert(!pinecone_render_pass_depth && !pinecone_thread_batch.command_count);
#define SMALL(op, src, m, fmt, mf, w, h) \
    pinecone_prefer_cpu_composite_locked(op, src, m, fmt, mf, w, h)
    assert(SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    assert(SMALL(3, &solid, &mask, PINECONE_FORMAT_A8R8G8B8, PINECONE_FORMAT_A8, 16, 16));
    assert(SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 256, 1));
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 257, 1));
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 0, 1));
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, UINT32_MAX, UINT32_MAX));
    assert(!SMALL(1, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    assert(!SMALL(3, &mask, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    assert(!SMALL(3, NULL, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_X8R8G8B8, 0, 1, 1));
    assert(!SMALL(3, &solid, &mask, PINECONE_FORMAT_A8R8G8B8, PINECONE_FORMAT_A8R8G8B8, 1, 1));
    mask.unsafe_state = 1;
    assert(!SMALL(3, &solid, &mask, PINECONE_FORMAT_A8R8G8B8, PINECONE_FORMAT_A8, 1, 1));
    solid.unsafe_state = 1;
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    solid.unsafe_state = 0;
    pinecone_render_pass_depth = 1;
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    pinecone_render_pass_depth = 0;
    pinecone_thread_batch.command_count = 1;
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    pinecone_thread_batch.command_count = 0;
    pinecone_cpu_small_composite = 0;
    assert(!SMALL(3, &solid, NULL, PINECONE_FORMAT_A8R8G8B8, 0, 1, 1));
    pinecone_cpu_small_composite = saved;
#undef SMALL
    puts("Pixman small-composite policy: bounded simple OVER only, no render-pass/batch splits, explicit opt-out");
}

static void unexpected_cpu_composite(pixman_op_t op, pixman_image_t *s,
    pixman_image_t *m, pixman_image_t *d, int32_t sx, int32_t sy,
    int32_t mx, int32_t my, int32_t dx, int32_t dy, uint32_t w, uint32_t h) {
    (void)op; (void)s; (void)m; (void)d; (void)sx; (void)sy;
    (void)mx; (void)my; (void)dx; (void)dy; (void)w; (void)h;
    assert(!"the bridge callback must return to Pixman, not invoke it recursively");
}

static void test_small_composite_fences(void) {
    reset_device();
    uint32_t pixels[16] = {0};
    struct region_image src = {{NULL, 1}, 1, 1, 4, PINECONE_FORMAT_A8R8G8B8};
    struct region_image dst = {{pixels, 1}, 4, 4, 16, PINECONE_FORMAT_A8R8G8B8};
    pixman_image_t *source = (void *)&src, *destination = (void *)&dst;
    real_get_data = lease_data;
    real_get_stride = region_stride;
    real_get_width = region_width;
    real_get_height = region_height;
    real_get_format = region_format;
    real_ref = lease_ref;
    real_unref = lease_unref;
    __typeof__(real_composite32) saved_composite = real_composite32;
    real_composite32 = unexpected_cpu_composite;
    pixman_color_t color = {.red = 0x4040, .alpha = 0x8080};
    pinecone_pixman_created_solid(source, &color);
    assert(pinecone_mapping_count == 0);
    assert(pinecone_record_mapping_locked(pixels, sizeof(pixels), 42, 7));
    struct pinecone_image_state *state = pinecone_image_state(destination, 1);
    uint64_t generation = state->cpu_generation, routed = pinecone_cpu_small_count;
    struct pinecone_fence_use *reader = calloc(1, sizeof(*reader));
    assert(reader);
    reader->fd = eventfd(0, EFD_CLOEXEC);
    assert(reader->fd >= 0);
    reader->graphics_fd = 42;
    reader->handles[0] = 7;
    reader->count = 1;
    reader->next = pinecone_fence_uses;
    pinecone_fence_uses = reader;
    pthread_t signaler;
    uint64_t waits = pinecone_handle_blocking_waits;
    assert(pthread_create(&signaler, NULL, signal_fence, &reader->fd) == 0);
    assert(!pinecone_pixman_composite(3, source, NULL, destination,
        0, 0, 0, 0, 0, 0, 4, 4));
    assert(pthread_join(signaler, NULL) == 0);
    assert(pinecone_handle_blocking_waits > waits && exec_count == 0);
    assert(state->cpu_generation == generation + 1);
    assert(pinecone_cpu_small_count == routed + 1);
    // Invalid completion may never authorize the CPU to write shared pixels.
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        struct rlimit no_core = {0, 0};
        assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
        close(reader->fd);
        (void)pinecone_pixman_composite(3, source, NULL, destination,
            0, 0, 0, 0, 0, 0, 4, 4);
        _exit(99);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    close(reader->fd);
    pinecone_remove_fence_use_locked(reader);
    pinecone_forget_mapping_locked(pixels);
    assert(pixman_image_unref(source) && pixman_image_unref(destination));
    real_composite32 = saved_composite;
    mock_device = 0;
    puts("Pixman small composites: shared readers fenced, unleased destination cache invalidated, failed fences abort before CPU access");
}

int main(void) {
    pinecone_resolve();
    const char *test_case = getenv("PINECONE_PIXMAN_REGRESSION_CASE");
    if (test_case && *test_case && strcmp(test_case, "commit") &&
        strcmp(test_case, "reentrant") && strcmp(test_case, "allocator")) {
        fprintf(stderr, "Unknown regression case: %s\n", test_case);
        return 2;
    }
    if (!test_case || !*test_case || !strcmp(test_case, "allocator"))
        test_allocator_mapping_reentry();
#ifdef PINECONE_TEST_WLROOTS_COMMIT
    if (!test_case || !*test_case || !strcmp(test_case, "commit")) test_output_commit_order();
#else
    if (test_case && !strcmp(test_case, "commit")) {
        fputs("The commit regression requires the Phoc source archive\n", stderr);
        return 2;
    }
    puts("SKIP: upstream commit regression (pass phoc-0.57.0.tar.xz to the runner)");
#endif
    if (!test_case || !*test_case || !strcmp(test_case, "reentrant")) test_reentrant_submission();
    if (test_case && *test_case) return 0;
    test_solid_color_encoding();
    test_small_composite_policy();
    test_buffer_leases();
    test_region_snapshots();
    test_registered_cache_hits();
    test_mask_upload_formats();
    test_mask_command_formats();
    test_owned_shm_snapshots();
    test_foreign_fills();
    test_small_composite_fences();
    real_get_data = test_data;
    real_get_stride = test_stride;
    real_get_height = test_height;
    real_ref = test_ref;
    real_unref = test_unref;
    pixman_image_t *image = (pixman_image_t *)&image_word;
    pinecone_pixman_begin_cpu_access_flags(1u);
    assert(pixman_image_get_data(image) == &image_word);
    pinecone_pixman_end_cpu_access();
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_image_state(image, 0)->cpu_generation == 0);
    assert(pinecone_image_state(image, 0)->cpu_data_unbounded == 1);
    struct pinecone_image_state solid = { .is_solid = 1, .cpu_data_unbounded = 1 };
    assert(!pinecone_image_has_cpu_hazard(&solid, 1));
    pthread_mutex_unlock(&pinecone_lock);
    pinecone_pixman_begin_cpu_access_flags(2u);
    assert(pixman_image_get_data(image) == &image_word);
    pinecone_pixman_end_cpu_access();
    pthread_mutex_lock(&pinecone_lock);
    assert(pinecone_image_state(image, 0)->cpu_generation == 2);

    // Model a freshly bridge-allocated image, before any pointer can escape.
    uint32_t owned_key;
    pixman_image_t *owned = (pixman_image_t *)&owned_key;
    struct pinecone_image_state *owned_state = pinecone_image_state(owned, 1);
    owned_state->cpu_data_unbounded = 0;
    pthread_mutex_unlock(&pinecone_lock);
    pinecone_pixman_begin_cpu_access_flags(1u);
    assert(pixman_image_get_data(owned) == &image_word);
    pinecone_pixman_begin_cpu_access_flags(2u);
    assert(pixman_image_get_data(owned) == &image_word);
    assert(owned_state->scoped_cpu_access_count == 1);
    assert(pinecone_image_has_cpu_hazard(owned_state, 1));
    pinecone_pixman_end_cpu_access();
    assert(owned_state->scoped_cpu_access_count == 1);
    pinecone_pixman_end_cpu_access();
    assert(owned_state->scoped_cpu_access_count == 0);
    assert(owned_state->cpu_generation == 2);
    assert(!pinecone_image_has_cpu_hazard(owned_state, 1));

    // Public Cairo exports must escape even when invoked from a draw callback.
    pinecone_pixman_begin_cpu_access_flags(1u);
    assert(pinecone_pixman_get_data_escaping(owned) == &image_word);
    pinecone_pixman_end_cpu_access();
    pinecone_pixman_begin_render_pass();
    assert(pinecone_image_has_cpu_hazard(owned_state, 1));
    pinecone_pixman_end_render_pass();
    assert(owned_state->cpu_data_unbounded);

    // Retention failure must remain a process-wide hazard after scope exit.
    uint32_t failed_key;
    pixman_image_t *failed = (pixman_image_t *)&failed_key;
    struct pinecone_image_state *failed_state = pinecone_image_state(failed, 1);
    failed_state->cpu_data_unbounded = 0;
    pinecone_pixman_begin_cpu_access_flags(3u);
    real_ref = NULL;
    assert(pixman_image_get_data(failed) == &image_word);
    real_ref = test_ref;
    pinecone_pixman_end_cpu_access();
    assert(failed_state->cpu_data_unbounded);
    pthread_mutex_lock(&pinecone_lock);

    // get_data itself must wait before exposure and return no pointer on error.
    image_word = 0x11223344;
    assert(pinecone_record_mapping_locked(&image_word, sizeof(image_word), 42, 9));
    struct pinecone_fence_use *access_use = calloc(1, sizeof(*access_use));
    assert(access_use);
    access_use->fd = eventfd(0, EFD_CLOEXEC);
    assert(access_use->fd >= 0);
    access_use->graphics_fd = 42;
    access_use->handles[0] = 9;
    access_use->count = 1;
    pinecone_fence_uses = access_use;
    struct reader access_reader = { .fence = access_use->fd, .pixels = &image_word };
    pthread_t access_thread;
    assert(pthread_create(&access_thread, NULL, complete_reader, &access_reader) == 0);
    pthread_mutex_unlock(&pinecone_lock);
    pinecone_pixman_begin_cpu_access_flags(1u);
    assert(pixman_image_get_data(image) == &image_word);
    pinecone_pixman_end_cpu_access();
    assert(pthread_join(access_thread, NULL) == 0);
    pthread_mutex_lock(&pinecone_lock);
    close(access_use->fd);
    access_use->fd = -1;
    pthread_mutex_unlock(&pinecone_lock);
    assert(pixman_image_get_data(image) == NULL);
    assert(pinecone_pixman_get_data_escaping(image) == NULL);
    pthread_mutex_lock(&pinecone_lock);
    pinecone_remove_fence_use_locked(access_use);
    pinecone_forget_mapping_locked(&image_word);

    uint32_t cache_pixel = 0x11223344;
    uint32_t replacement = 0xaabbccdd;
    struct pinecone_upload_surface cache = {
        .address = &cache_pixel, .length = 4, .width = 1, .height = 1,
        .pitch = 4, .fd = 42, .handle = 7
    };
    struct pinecone_image_state state = {
        .source_cache = &cache, .cpu_generation = 2, .source_cache_generation = 1
    };
    struct pinecone_fence_use *use = calloc(1, sizeof(*use));
    assert(use != NULL);
    use->fd = eventfd(0, EFD_CLOEXEC);
    assert(use->fd >= 0);
    use->graphics_fd = 42;
    use->handles[0] = 7;
    use->count = 1;
    pinecone_fence_uses = use;

    // Independent handles must not wait on this outstanding reader.
    assert(pinecone_wait_handle_locked(42, 8) == 0);
    struct reader reader = { .fence = use->fd, .pixels = &cache_pixel };
    pthread_t thread;
    assert(pthread_create(&thread, NULL, complete_reader, &reader) == 0);
    assert(pinecone_prepare_source_cache_locked(
        &state, 42, (const uint8_t *)&replacement, 4, 1, 1, 0, 0, 1, 1, 4) == &cache);
    assert(cache_pixel == replacement);
    assert(state.source_cache_generation == 2);
    assert(pthread_join(thread, NULL) == 0);
    close(use->fd);
    pinecone_remove_fence_use_locked(use);

    // A new generation can use an idle spare without touching an active reader.
    cache_pixel = 0x11223344;
    uint32_t spare_pixel = 0;
    struct pinecone_upload_surface spare = cache;
    spare.address = &spare_pixel;
    spare.handle = 8;
    state.source_spares[0] = &spare;
    state.cpu_generation = 3;
    pinecone_spare_bytes = spare.length;
    use = calloc(1, sizeof(*use));
    assert(use != NULL);
    use->fd = eventfd(0, EFD_CLOEXEC);
    assert(use->fd >= 0);
    use->graphics_fd = 42;
    use->handles[0] = 7;
    use->count = 1;
    pinecone_fence_uses = use;
    uint64_t rotations = pinecone_cache_rotations;
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 0, 0, 1, 1, 4) == &spare);
    assert(cache_pixel == 0x11223344 && spare_pixel == replacement);
    assert(state.source_spares[0] == &cache && pinecone_spare_bytes == 4);
    assert(pinecone_cache_rotations == rotations + 1);
    close(use->fd);
    pinecone_remove_fence_use_locked(use);
    pinecone_spare_bytes = 0;

    // An escaped writable pointer invalidates generation-only cache reuse.
    state.cpu_data_unbounded = 1;
    replacement = 0xdeadbeef;
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 0, 0, 1, 1, 4) == &spare);
    assert(spare_pixel == replacement);
    // GPU-owned alias snapshots also refresh without a CPU generation change.
    state.cpu_data_unbounded = 0;
    state.owned_surface = &cache;
    replacement = 0x10203040;
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 0, 0, 1, 1, 4) == &spare);
    assert(spare_pixel == replacement);
    state.owned_surface = NULL;
    state.cpu_data_unbounded = 1;
    state.mask_cache = &cache;
    state.mask_cache_generation = state.cpu_generation;
    state.mask_cache_width = state.mask_cache_height = 1;
    state.mask_cache_format = PINECONE_FORMAT_A8R8G8B8;
    assert(pinecone_prepare_mask_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 0, 0, 1, 1,
        PINECONE_FORMAT_A8R8G8B8, 1) == &cache);
    uint32_t prior_mask = cache_pixel;
    replacement = 0xff102030;
    assert(pinecone_prepare_mask_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 0, 0, 1, 1,
        PINECONE_FORMAT_A8R8G8B8, 1) == &cache);
    assert(cache_pixel != prior_mask);
    pthread_mutex_unlock(&pinecone_lock);
    unsigned before = __atomic_load_n(&unref_count, __ATOMIC_RELAXED);
    assert(pthread_create(&thread, NULL, shared_only_thread, image) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(pinecone_fence_uses == NULL);
    assert(__atomic_load_n(&unref_count, __ATOMIC_RELAXED) == before + 1);
    puts("Pixman bridge: generations, independent handles, unlocked waits, stable rehash and fenced reuse passed");
    test_escape_range_bounds(); // Global saturation is intentionally irreversible.
    return 0;
}
