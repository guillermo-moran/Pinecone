#include "rootfs/pinecone-pixman.c"
#include <assert.h>
#include <sys/eventfd.h>

static uint32_t image_word;
static unsigned unref_count;
static uint32_t *test_data(pixman_image_t *image) {
    (void)image;
    return &image_word;
}
static pixman_image_t *test_ref(pixman_image_t *image) { return image; }
static pixman_bool_t test_unref(pixman_image_t *image) {
    (void)image;
    __atomic_add_fetch(&unref_count, 1u, __ATOMIC_RELAXED);
    return 0;
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

int main(void) {
    pinecone_resolve();
    real_get_data = test_data;
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
    assert(!pinecone_image_has_cpu_hazard(&solid));
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
    assert(pinecone_image_has_cpu_hazard(owned_state));
    pinecone_pixman_end_cpu_access();
    assert(owned_state->scoped_cpu_access_count == 1);
    pinecone_pixman_end_cpu_access();
    assert(owned_state->scoped_cpu_access_count == 0);
    assert(owned_state->cpu_generation == 2);
    assert(!pinecone_image_has_cpu_hazard(owned_state));

    // Public Cairo exports must escape even when invoked from a draw callback.
    pinecone_pixman_begin_cpu_access_flags(1u);
    assert(pinecone_pixman_get_data_escaping(owned) == &image_word);
    pinecone_pixman_end_cpu_access();
    pinecone_pixman_begin_render_pass();
    assert(pinecone_image_has_cpu_hazard(owned_state));
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
        &state, 42, (const uint8_t *)&replacement, 4, 1, 1, 4) == &cache);
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
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 4) == &spare);
    assert(cache_pixel == 0x11223344 && spare_pixel == replacement);
    assert(state.source_spares[0] == &cache && pinecone_spare_bytes == 4);
    assert(pinecone_cache_rotations == 1);
    close(use->fd);
    pinecone_remove_fence_use_locked(use);
    pinecone_spare_bytes = 0;

    // An escaped writable pointer invalidates generation-only cache reuse.
    state.cpu_data_unbounded = 1;
    replacement = 0xdeadbeef;
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 4) == &spare);
    assert(spare_pixel == replacement);
    // GPU-owned alias snapshots also refresh without a CPU generation change.
    state.cpu_data_unbounded = 0;
    state.owned_surface = &cache;
    replacement = 0x10203040;
    assert(pinecone_prepare_source_cache_locked(&state, 42,
        (const uint8_t *)&replacement, 4, 1, 1, 4) == &spare);
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
    return 0;
}
