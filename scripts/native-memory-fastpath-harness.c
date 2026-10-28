#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

/* Compile the saved or working memory implementation in isolation. Cache
 * callbacks are spies, not a substitute for the parent's integrated tests. */
#ifndef AVZ_MEMORY_SOURCE
#define AVZ_MEMORY_SOURCE "../Sources/ARM64VizNative/ARM64VizGuestMemory.c"
#endif
#include AVZ_MEMORY_SOURCE

#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #test); abort(); \
} } while (0)

static _Atomic unsigned code_invalidations, mapping_invalidations;
int avz_native_block_cache_bind_physical_memory(AVZNativeBlockCache *cache,
    uint8_t *ram, uint64_t base, uint64_t size) {
    (void)cache; (void)ram; (void)base; (void)size; return 1;
}
void avz_native_block_cache_set_guest_memory(AVZNativeBlockCache *cache,
    AVZGuestMemory *memory) { (void)cache; (void)memory; }
void avz_native_block_cache_invalidate_decode_window(AVZNativeBlockCache *cache) {
    (void)cache;
}
void avz_native_block_cache_set_mapping_validator(AVZNativeBlockCache *cache,
    AVZNativeInstructionMappingValidateCallback validate, void *context) {
    (void)cache; (void)validate; (void)context;
}
void avz_native_block_cache_invalidate_translation_mappings(AVZNativeBlockCache *cache) {
    if (cache) atomic_fetch_add(&mapping_invalidations, 1);
}
void avz_native_block_cache_invalidate_physical_range(AVZNativeBlockCache *cache,
    uint64_t address, uint64_t count) {
    (void)address; (void)count;
    if (cache) atomic_fetch_add(&code_invalidations, 1);
}

enum { RAM_SIZE = 4 * 1024 * 1024, RAM_BASE = 0x40000000 };
typedef struct {
    AVZGuestMemory *memory;
    size_t bias;
    unsigned slow_reads, slow_writes, translations;
} Context;

static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Context *context = opaque;
    (void)write;
    context->translations++;
    if (address < RAM_BASE || address - RAM_BASE >= context->memory->size ||
        width > context->memory->size - (address - RAM_BASE)) return 0;
    *physical = address + context->bias;
    return *physical >= RAM_BASE && *physical - RAM_BASE < context->memory->size &&
        width <= context->memory->size - (*physical - RAM_BASE);
}

static int slow_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Context *context = opaque;
    uint64_t physical;
    context->slow_reads++;
    if (!avz_fast_width_supported(width) ||
        !translate(context, address, width, 0, &physical)) return 0;
    *value = avz_fast_load(context->memory->bytes + physical - RAM_BASE, width);
    return 1;
}

static int slow_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Context *context = opaque;
    uint64_t physical;
    context->slow_writes++;
    if (!avz_fast_width_supported(width) ||
        !translate(context, address, width, 1, &physical)) return 0;
    avz_fast_store_value(context->memory->bytes + physical - RAM_BASE, width, value);
    avz_guest_memory_note_write(context->memory, physical - RAM_BASE, width);
    return 1;
}

static AVZNativeMemoryFastPath *make_path(Context *context) {
    AVZNativeMemoryFastPath *path = avz_native_memory_fast_path_create(
        context->memory->bytes, RAM_BASE, context->memory->size, NULL, context,
        translate, slow_read, slow_write, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL);
    CHECK(path && avz_native_memory_fast_path_set_guest_memory(path, context->memory));
    avz_native_memory_fast_path_set_detailed_statistics_enabled(path, 0);
    return path;
}

static int read_hot(AVZNativeMemoryFastPath *path, uint64_t address,
    uint8_t width, uint64_t *value) {
    return avz_native_fast_memory_try_read_hot(path, address, width, value) ||
        avz_native_fast_memory_read(path, address, width, value);
}

static int write_hot(AVZNativeMemoryFastPath *path, uint64_t address,
    uint8_t width, uint64_t value) {
    return avz_native_fast_memory_try_write_hot(path, address, width, value) ||
        avz_native_fast_memory_write(path, address, width, value);
}

static void enable_block_translation(AVZNativeMemoryFastPath *path) {
    size_t root = path->ram_size - 8192;
    avz_fast_store_value(path->ram + root, 8, RAM_BASE + root + 4096 + 3);
    avz_fast_store_value(path->ram + root + 4096 + 8, 8,
        RAM_BASE | AVZ_STAGE1_ACCESS_FLAG_BIT | 1);
    AVZNativeStage1TranslationState state = {
        .sctlr_el1 = 1, .tcr_el1 = 16, .ttbr0_el1 = RAM_BASE + root, .current_el = 1};
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
}

static uint64_t random_next(uint64_t *state) {
    *state ^= *state << 13; *state ^= *state >> 7; *state ^= *state << 17;
    return *state;
}

static unsigned checks;
static void differential(void) {
    Context actual = {.memory = avz_guest_memory_create(RAM_SIZE)};
    Context reference = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(actual.memory && reference.memory);
    AVZNativeMemoryFastPath *a = make_path(&actual), *b = make_path(&reference);
    uint64_t seed = 0x123456789abcdefULL;
    for (unsigned i = 0; i < 24000; i++) {
        uint8_t width = (uint8_t)(1u << (i % 4));
        size_t offset = i < 64 ? 4096 - 16 + i % 32 :
            random_next(&seed) % (RAM_SIZE - 8);
        uint64_t value = random_next(&seed), x = 0, y = 0;
        CHECK(write_hot(a, RAM_BASE + offset, width, value) ==
            avz_native_fast_memory_write(b, RAM_BASE + offset, width, value));
        CHECK(read_hot(a, RAM_BASE + offset, width, &x));
        CHECK(avz_native_fast_memory_read(b, RAM_BASE + offset, width, &y));
        CHECK(x == y);
        CHECK(x == (value & (UINT64_MAX >> ((8 - width) * 8))));
        if (i % 511 == 0) {
            avz_guest_memory_advance_dirty_epoch(actual.memory);
            avz_guest_memory_advance_dirty_epoch(reference.memory);
        }
        checks++;
    }
    CHECK(memcmp(actual.memory->bytes, reference.memory->bytes, RAM_SIZE) == 0);
    for (size_t i = 0; i < actual.memory->page_count; i++)
        CHECK(atomic_load(&actual.memory->page_epochs[i]) ==
            atomic_load(&reference.memory->page_epochs[i]));
    CHECK(actual.slow_reads == reference.slow_reads);
    CHECK(actual.slow_writes == reference.slow_writes);
    uint64_t value;
    CHECK(!read_hot(a, RAM_BASE + RAM_SIZE - 1, 8, &value));
    CHECK(!write_hot(a, UINT64_MAX, 8, 0));
    CHECK(!avz_native_fast_memory_try_read_hot(a, RAM_BASE, 3, &value));
    CHECK(!avz_native_fast_memory_try_write_hot(NULL, RAM_BASE, 8, 0));
    avz_native_memory_fast_path_destroy(a); avz_native_memory_fast_path_destroy(b);
    avz_guest_memory_destroy(actual.memory); avz_guest_memory_destroy(reference.memory);
}

static void copies(void) {
    Context context = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(context.memory);
    AVZNativeMemoryFastPath *path = make_path(&context);
    uint8_t input[4160], output[4160], expected[4160];
    for (size_t i = 0; i < sizeof(input); i++) input[i] = (uint8_t)(i * 23 + 7);
    const size_t lengths[] = {1, 2, 3, 4, 7, 8, 9, 15, 16, 31, 64, 255, 256, 4096};
    for (unsigned observed = 0; observed < 2; observed++) {
        if (observed) CHECK(avz_guest_memory_register_host_range(context.memory, 0, 16384));
        for (size_t alignment = 0; alignment < 16; alignment++) {
            for (size_t n = 0; n < sizeof(lengths) / sizeof(lengths[0]); n++) {
                size_t count = lengths[n], offset = 4090 + alignment;
                memset(context.memory->bytes, 0xcc, 16384);
                for (size_t written = 0; written < count;) {
                    size_t chunk = count - written < 64 ? count - written : 64;
                    CHECK(avz_native_fast_memory_write_bytes(path, RAM_BASE + offset + written,
                        input + alignment + written, chunk));
                    written += chunk;
                }
                CHECK(memcmp(context.memory->bytes + offset, input + alignment, count) == 0);
                CHECK(context.memory->bytes[offset - 1] == 0xcc);
                CHECK(context.memory->bytes[offset + count] == 0xcc);
                memset(output, 0x77, sizeof(output));
                memcpy(expected, output, sizeof(output));
                memcpy(expected + alignment, input + alignment, count);
                CHECK(avz_native_fast_memory_read_bytes(path, RAM_BASE + offset,
                    output + alignment, count));
                CHECK(memcmp(output, expected, sizeof(output)) == 0);
                checks++;
            }
        }
    }
    CHECK(!avz_native_fast_memory_read_bytes(path, UINT64_MAX, output, 2));
    CHECK(!avz_native_fast_memory_write_bytes(path, RAM_BASE, input, 4097));
    avz_native_memory_fast_path_destroy(path); avz_guest_memory_destroy(context.memory);
}

static void guarded_copies(void) {
    long page_size = sysconf(_SC_PAGESIZE);
    CHECK(page_size >= 4096);
    size_t page = (size_t)page_size;
    uint8_t *source = mmap(NULL, page * 3, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *destination = mmap(NULL, page * 3, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(source != MAP_FAILED && destination != MAP_FAILED);
    CHECK(mprotect(source + page, page, PROT_READ | PROT_WRITE) == 0);
    CHECK(mprotect(destination + page, page, PROT_READ | PROT_WRITE) == 0);
    for (size_t count = 1; count <= 256; count++) {
        for (size_t alignment = 0; alignment < 8; alignment++) {
            uint8_t *from = source + 2 * page - count;
            uint8_t *to = destination + 2 * page - count - alignment;
            memset(from, (int)(count & 255), count);
            memset(to, 0, count);
            avz_fast_atomic_read_bytes(from, to, count);
            CHECK(memcmp(from, to, count) == 0);
            memset(from, 0, count);
            avz_fast_atomic_write_bytes(from, to, count);
            CHECK(memcmp(from, to, count) == 0);
            checks++;
        }
    }
    CHECK(munmap(source, page * 3) == 0);
    CHECK(munmap(destination, page * 3) == 0);
}

static void invalidation(void) {
    Context context = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(context.memory);
    AVZNativeMemoryFastPath *path = make_path(&context);
    uint64_t value;
    CHECK(write_hot(path, RAM_BASE, 8, 11));
    CHECK(write_hot(path, RAM_BASE + 4096, 8, 22));
    CHECK(read_hot(path, RAM_BASE, 8, &value) && value == 11);
    context.bias = 4096;
    avz_guest_memory_publish_tlbi(context.memory, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL});
    CHECK(!avz_native_fast_memory_try_read_hot(path, RAM_BASE, 8, &value));
    CHECK(!avz_native_fast_memory_try_write_hot(path, RAM_BASE, 8, 33));
    CHECK(read_hot(path, RAM_BASE, 8, &value) && value == 22);
    for (unsigned i = 0; i < AVZ_TLBI_JOURNAL_COUNT + 1; i++)
        avz_guest_memory_publish_tlbi(context.memory,
            (AVZNativeTLBI){.kind = AVZ_TLBI_VA_ALL_ASIDS, .virtual_address = RAM_BASE});
    context.bias = 0;
    CHECK(read_hot(path, RAM_BASE, 8, &value) && value == 11);
    AVZNativeStage1TranslationState state = {.current_el = 1};
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
    CHECK(!avz_native_fast_memory_try_read_hot(path, RAM_BASE, 8, &value));
    CHECK(read_hot(path, RAM_BASE, 8, &value) && value == 11);
    state.ttbr0_el1 = UINT64_C(1) << 48;
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
    CHECK(!avz_native_fast_memory_try_read_hot(path, RAM_BASE, 8, &value));
    CHECK(read_hot(path, RAM_BASE, 8, &value));
    state.ttbr0_el1 |= 4096;
    avz_native_memory_fast_path_set_stage1_translation(path, &state, NULL);
    CHECK(!avz_native_fast_memory_try_read_hot(path, RAM_BASE, 8, &value));
    CHECK(read_hot(path, RAM_BASE, 8, &value));
    path->block_cache = (AVZNativeBlockCache *)&context;
    avz_guest_memory_mark_code_page(context.memory, RAM_BASE, RAM_BASE);
    uint64_t epoch = avz_guest_memory_code_mutation_epoch(context.memory);
    uint64_t generation = avz_guest_memory_page_write_generation(context.memory, RAM_BASE, RAM_BASE);
    CHECK(write_hot(path, RAM_BASE, 8, 44));
    CHECK(avz_guest_memory_code_mutation_epoch(context.memory) > epoch);
    CHECK(avz_guest_memory_page_write_generation(context.memory, RAM_BASE, RAM_BASE) > generation);
    CHECK(atomic_load(&code_invalidations) == 1);
    epoch = avz_guest_memory_code_mutation_epoch(context.memory);
    CHECK(avz_native_fast_memory_write_bytes(path, RAM_BASE, &value, sizeof(value)));
    CHECK(avz_guest_memory_code_mutation_epoch(context.memory) > epoch);
    CHECK(atomic_load(&code_invalidations) == 2);
    avz_native_memory_fast_path_apply_tlbi(path, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL});
    CHECK(atomic_load(&mapping_invalidations) != 0);
    avz_native_memory_fast_path_destroy(path); avz_guest_memory_destroy(context.memory);
    checks++;
}

static void observations(void) {
    Context context = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(context.memory);
    AVZNativeMemoryFastPath *path = make_path(&context);
    uint64_t value, generation, second;
    CHECK(write_hot(path, RAM_BASE, 8, 1));
    CHECK(read_hot(path, RAM_BASE, 8, &value));
    CHECK(avz_guest_memory_register_host_range(context.memory, 0, 8));
    CHECK(!avz_native_fast_memory_try_read_hot(path, RAM_BASE, 8, &value));
    CHECK(!avz_native_fast_memory_try_write_hot(path, RAM_BASE, 8, 2));
    CHECK(write_hot(path, RAM_BASE, 8, 2));
    avz_guest_memory_note_bulk_read(context.memory, 0, 8);
    CHECK(avz_native_fast_memory_exclusive_read(path, RAM_BASE, 8, &value, &generation));
    CHECK(value == 2 && atomic_load(&context.memory->page_observation_flags[0]) == 7);
    CHECK(write_hot(path, RAM_BASE, 8, 3));
    CHECK(avz_native_fast_memory_exclusive_write(path, RAM_BASE, 8, 4, generation) == 0);
    CHECK(avz_native_fast_memory_exclusive_read(path, RAM_BASE, 8, &value, &generation));
    CHECK(avz_native_fast_memory_exclusive_write(path, RAM_BASE, 8, 5, generation) == 1);
    CHECK(avz_native_fast_memory_exclusive_read(path, RAM_BASE, 8, &value, &generation));
    CHECK(avz_native_fast_memory_write_bytes(path, RAM_BASE, &value, sizeof(value)));
    CHECK(avz_native_fast_memory_exclusive_write(path, RAM_BASE, 8, 6, generation) == 0);
    CHECK(avz_guest_memory_exclusive_read_pair(context.memory, 16, 8, &value, &second, &generation));
    CHECK(avz_guest_memory_exclusive_write_pair(context.memory, 16, 8, 17, 19, generation) == 1);
    CHECK(avz_guest_memory_exclusive_write_pair(context.memory, 16, 8, 20, 21, generation) == 0);
    avz_guest_memory_clear_host_observations(context.memory);
    CHECK(atomic_load(&context.memory->page_observation_flags[0]) == 4);
    CHECK(!avz_guest_memory_host_range_is_registered(context.memory, 0, 8));
    CHECK(!avz_native_fast_memory_try_write_hot(path, RAM_BASE, 8, 0));
    CHECK(avz_guest_memory_register_host_range(context.memory, 0, 8));
    CHECK(atomic_load(&context.memory->page_observation_flags[0]) == 5);
    CHECK(avz_guest_memory_store_u16_release(context.memory, 32, 0x4321));
    uint16_t small;
    CHECK(avz_guest_memory_load_u16_acquire(context.memory, 32, &small) && small == 0x4321);
    avz_native_memory_fast_path_destroy(path); avz_guest_memory_destroy(context.memory);
    checks++;
}

typedef struct {
    AVZGuestMemory *memory;
    AVZNativeMemoryFastPath *path;
    _Atomic unsigned phase, acknowledged;
} Handoff;

static void *translation_reader(void *opaque) {
    Handoff *handoff = opaque;
    for (unsigned i = 1; i <= 2000; i++) {
        while (atomic_load_explicit(&handoff->phase, memory_order_acquire) != i) {}
        uint64_t value;
        CHECK(!avz_native_fast_memory_try_read_hot(handoff->path, 0, 8, &value));
        CHECK(read_hot(handoff->path, 0, 8, &value));
        CHECK(value == ((i & 1) ? 22 : 11));
        atomic_store_explicit(&handoff->acknowledged, i, memory_order_release);
    }
    return NULL;
}

static void *host_reader(void *opaque) {
    Handoff *handoff = opaque;
    for (unsigned i = 0; i < 10000; i++) {
        uint8_t bytes[64];
        avz_guest_memory_lock_range(handoff->memory, 0, sizeof(bytes));
        memcpy(bytes, handoff->memory->bytes, sizeof(bytes));
        avz_guest_memory_unlock_range(handoff->memory, 0, sizeof(bytes));
        for (size_t n = 1; n < sizeof(bytes); n++) CHECK(bytes[n] == bytes[0]);
    }
    return NULL;
}

static void handoffs(void) {
    Context writer = {.memory = avz_guest_memory_create(RAM_SIZE)};
    CHECK(writer.memory);
    Context reader = {.memory = writer.memory};
    AVZNativeMemoryFastPath *a = make_path(&writer), *b = make_path(&reader);
    Handoff handoff = {.memory = writer.memory, .path = b};
    pthread_t thread;
    CHECK(avz_guest_memory_register_host_range(writer.memory, 0, 64));
    CHECK(pthread_create(&thread, NULL, host_reader, &handoff) == 0);
    for (unsigned i = 0; i < 10000; i++) {
        uint8_t bytes[64]; memset(bytes, (int)(i & 255), sizeof(bytes));
        CHECK(avz_native_fast_memory_write_bytes(a, RAM_BASE, bytes, sizeof(bytes)));
    }
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(write_hot(a, RAM_BASE, 8, 11));
    CHECK(write_hot(a, RAM_BASE + 4096, 8, 22));
    for (size_t level = 0; level < 3; level++)
        CHECK(write_hot(a, RAM_BASE + 0x10000 + level * 4096, 8,
            (RAM_BASE + 0x10000 + (level + 1) * 4096) | 3));
    CHECK(write_hot(a, RAM_BASE + 0x13000, 8, RAM_BASE | 0x403));
    AVZNativeStage1TranslationState state = {
        .sctlr_el1 = 1, .tcr_el1 = 16, .ttbr0_el1 = RAM_BASE + 0x10000, .current_el = 1};
    avz_native_memory_fast_path_set_stage1_translation(b, &state, NULL);
    uint64_t value;
    CHECK(read_hot(b, 0, 8, &value) && value == 11);
    CHECK(pthread_create(&thread, NULL, translation_reader, &handoff) == 0);
    for (unsigned i = 1; i <= 2000; i++) {
        CHECK(write_hot(a, RAM_BASE + 0x13000, 8, (RAM_BASE + (i & 1) * 4096) | 0x403));
        avz_guest_memory_publish_tlbi(writer.memory, (AVZNativeTLBI){
            .kind = i % 3 == 0 ? AVZ_TLBI_ALL : AVZ_TLBI_VA_ALL_ASIDS, .virtual_address = 0});
        atomic_store_explicit(&handoff.phase, i, memory_order_release);
        while (atomic_load_explicit(&handoff.acknowledged, memory_order_acquire) != i) {}
    }
    CHECK(pthread_join(thread, NULL) == 0);
    /* Permission faults must still suppress the callback fallback and writes. */
    CHECK(write_hot(a, RAM_BASE + 0x13000, 8, RAM_BASE | 0x483));
    avz_guest_memory_invalidate_translations(writer.memory);
    CHECK(!write_hot(b, 0, 8, 99));
    CHECK(b->translation_fault_pending && reader.slow_writes == 0);
    CHECK(avz_fast_load(writer.memory->bytes, 8) == 11);
    avz_native_memory_fast_path_destroy(a); avz_native_memory_fast_path_destroy(b);
    avz_guest_memory_destroy(writer.memory);
    checks += 12001;
}

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned arrived, participants;
    int released;
} Gate;

static void gate_wait(Gate *gate) {
    CHECK(pthread_mutex_lock(&gate->mutex) == 0);
    gate->arrived++;
    CHECK(pthread_cond_broadcast(&gate->condition) == 0);
    while (!gate->released) CHECK(pthread_cond_wait(&gate->condition, &gate->mutex) == 0);
    CHECK(pthread_mutex_unlock(&gate->mutex) == 0);
}

typedef struct {
    Context context;
    AVZNativeMemoryFastPath *path;
    Gate *gate;
    const char *mode;
    size_t offset, iterations;
    uint64_t checksum, failures;
    unsigned id;
} Worker;

static void *worker_run(void *opaque) {
    Worker *worker = opaque;
    AVZNativeMemoryFastPath *path = worker->path;
    AVZGuestMemory *memory = worker->context.memory;
    uint64_t sum = 0, value = 0, generation = 0;
    uint8_t buffer[256];
    memset(buffer, (int)worker->id + 1, sizeof(buffer));
    int exclusive = !strcmp(worker->mode, "exclusive");
    int host_copy = !strcmp(worker->mode, "host-copy");
    int metadata = !strcmp(worker->mode, "metadata");
    int byte_copy = !strncmp(worker->mode, "bytes", 5);
    size_t copy_count = byte_copy ? (size_t)strtoul(worker->mode + 5, NULL, 10) : 0;
    int unaligned_copy = !strcmp(worker->mode, "bytes64-unaligned");
    int unaligned = !strcmp(worker->mode, "unaligned");
    int cold = !strcmp(worker->mode, "general");
    int working_set = !strcmp(worker->mode, "working-set");
    int control = !strcmp(worker->mode, "control");
    gate_wait(worker->gate);
    for (size_t i = 0; i < worker->iterations; i++) {
        size_t offset = worker->offset + ((i * 17) & (working_set ? 4095 : 63)) * 64;
        uint64_t address = RAM_BASE + offset;
        if (control) {
            __asm__ volatile("" : "+r"(address));
            sum += address;
        } else if (exclusive) {
            CHECK(avz_native_fast_memory_exclusive_read(path, address, 8, &value, &generation));
            int result = avz_native_fast_memory_exclusive_write(path, address, 8, value + 1, generation);
            CHECK(result >= 0); worker->failures += !result; sum += (uint64_t)result;
        } else if (host_copy) {
            avz_guest_memory_lock_range(memory, offset, sizeof(buffer));
            memcpy(buffer, memory->bytes + offset, sizeof(buffer));
            __asm__ volatile("" : : "r"(buffer) : "memory");
            sum += buffer[i & 255];
            avz_guest_memory_unlock_range(memory, offset, sizeof(buffer));
        } else if (metadata) {
            if (worker->id == 0) avz_guest_memory_note_host_observation(memory, offset, 8);
            else avz_guest_memory_note_bulk_read(memory, offset, 8);
            sum++;
        } else if (byte_copy) {
            size_t count = copy_count;
            if (unaligned_copy) address += 3;
            CHECK(avz_native_fast_memory_read_bytes(path, address, buffer, count));
            for (size_t written = 0; written < count; written += 64) {
                size_t chunk = count - written < 64 ? count - written : 64;
                CHECK(avz_native_fast_memory_write_bytes(path, address + written, buffer + written, chunk));
            }
            sum += buffer[0];
        } else {
            if (unaligned) address += 3;
            if (cold) {
                CHECK(avz_native_fast_memory_read(path, address, 8, &value));
                CHECK(avz_native_fast_memory_write(path, address, 8, value + 1));
            } else {
                CHECK(read_hot(path, address, 8, &value));
                CHECK(write_hot(path, address, 8, value + 1));
            }
            sum += value;
        }
    }
    worker->checksum = sum;
    return NULL;
}

static uint64_t now_ns(void) {
    struct timespec now; CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static void run_workers(const char *mode, unsigned threads, int shared,
    size_t iterations, int print) {
    AVZGuestMemory *memory = avz_guest_memory_create(RAM_SIZE);
    CHECK(memory);
    Gate gate = {.mutex = PTHREAD_MUTEX_INITIALIZER, .condition = PTHREAD_COND_INITIALIZER,
        .participants = threads};
    Worker workers[2] = {0}; pthread_t ids[2];
    for (unsigned t = 0; t < threads; t++) {
        Worker *worker = &workers[t];
        worker->context.memory = memory; worker->path = make_path(&worker->context);
        worker->offset = shared ? 0 : (size_t)t * 1024 * 1024;
        worker->mode = mode; worker->iterations = iterations; worker->gate = &gate; worker->id = t;
        if (!strcmp(mode, "native")) enable_block_translation(worker->path);
        if (!strcmp(mode, "hot-stats"))
            avz_native_memory_fast_path_set_detailed_statistics_enabled(worker->path, 1);
        if (!strcmp(mode, "observed") || !strcmp(mode, "host-copy"))
            CHECK(avz_guest_memory_register_host_range(memory, worker->offset, 8192));
        uint64_t value;
        CHECK(read_hot(worker->path, RAM_BASE + worker->offset, 8, &value));
        CHECK(write_hot(worker->path, RAM_BASE + worker->offset, 8, 0));
    }
    for (unsigned t = 0; t < threads; t++) CHECK(pthread_create(&ids[t], NULL, worker_run, &workers[t]) == 0);
    CHECK(pthread_mutex_lock(&gate.mutex) == 0);
    while (gate.arrived < threads) CHECK(pthread_cond_wait(&gate.condition, &gate.mutex) == 0);
    uint64_t start = now_ns();
    gate.released = 1;
    CHECK(pthread_cond_broadcast(&gate.condition) == 0);
    CHECK(pthread_mutex_unlock(&gate.mutex) == 0);
    for (unsigned t = 0; t < threads; t++) CHECK(pthread_join(ids[t], NULL) == 0);
    uint64_t elapsed = now_ns() - start, checksum = 0, failures = 0;
    for (unsigned t = 0; t < threads; t++) {
        checksum += workers[t].checksum; failures += workers[t].failures;
        avz_native_memory_fast_path_destroy(workers[t].path);
    }
    if (!strcmp(mode, "exclusive")) {
        uint64_t total = 0;
        for (unsigned t = 0; t < (shared ? 1u : threads); t++) {
            for (size_t slot = 0; slot < 64; slot++)
                total += avz_fast_load(memory->bytes + workers[t].offset + slot * 64, 8);
        }
        CHECK(total + failures == iterations * threads);
    }
    if (!strcmp(mode, "metadata")) {
        CHECK((atomic_load(&memory->page_observation_flags[0]) & AVZ_GUEST_PAGE_OBSERVATION_HOST) != 0);
        if (threads == 2) CHECK((atomic_load(&memory->page_observation_flags[workers[1].offset >> 12]) &
            AVZ_GUEST_PAGE_OBSERVATION_BULK_READER) != 0);
    }
    if (print) printf("%s,%u,%s,%zu,%.3f,%" PRIu64 ",%" PRIu64 "\n", mode,
        threads, shared ? "shared" : "split", iterations,
        (double)elapsed / (double)(iterations * threads), checksum, failures);
    CHECK(pthread_cond_destroy(&gate.condition) == 0);
    CHECK(pthread_mutex_destroy(&gate.mutex) == 0);
    avz_guest_memory_destroy(memory);
}

int main(int argc, char **argv) {
    const char *modes[] = {"control", "hot", "hot-stats", "working-set", "native", "general", "observed", "unaligned",
        "bytes1", "bytes7", "bytes8", "bytes16", "bytes64", "bytes64-unaligned",
        "bytes256", "exclusive", "host-copy", "metadata"};
    if (argc >= 2 && !strcmp(argv[1], "--benchmark")) {
        size_t iterations = argc >= 3 ? (size_t)strtoull(argv[2], NULL, 10) : 200000;
        CHECK(iterations > 0);
        for (size_t m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
            if (argc >= 4 && argv[3][0] && strcmp(argv[3], modes[m])) continue;
            run_workers(modes[m], 1, 0, iterations, 1);
            run_workers(modes[m], 2, 0, iterations, 1);
            run_workers(modes[m], 2, 1, iterations, 1);
        }
        return 0;
    }
    differential(); copies(); guarded_copies(); invalidation(); observations(); handoffs();
    for (size_t m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
        run_workers(modes[m], 2, 0, 4000, 0);
        run_workers(modes[m], 2, 1, 4000, 0);
        checks += 2;
    }
    printf("PASS cases=%u threaded_scenarios=%zu\n", checks,
        2 * sizeof(modes) / sizeof(modes[0]) + 2);
    return 0;
}
