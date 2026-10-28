#define _POSIX_C_SOURCE 200809L
#include "ARM64VizGuestMemoryInternal.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
enum { BASE = 0x40000000, SIZE = 256 * 1024, CODE = 0x8000, TABLE = 0x10000 };
static uint64_t digest = UINT64_C(14695981039346656037), cases;
static void hash(const void *bytes, size_t count) {
    const uint8_t *p = bytes;
    for (size_t i = 0; i < count; i++) { digest ^= p[i]; digest *= UINT64_C(1099511628211); }
}
static void hash64(uint64_t value) { hash(&value, sizeof(value)); }
static uint64_t load(const uint8_t *p, uint8_t width) {
    uint64_t value = 0; memcpy(&value, p, width); return value;
}
static void store(uint8_t *p, uint8_t width, uint64_t value) { memcpy(p, &value, width); }

typedef struct {
    AVZGuestMemory *memory;
    AVZNativeMemoryFastPath *path;
    AVZNativeBlockCache *cache;
    unsigned faults, slow_calls, walks;
    uint64_t fault_address;
    uint8_t fault_access, fault_level, fault_status;
    int owns_memory;
} Fixture;

static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque; (void)write; f->walks++;
    if (address < BASE || address - BASE >= f->memory->size ||
        width > f->memory->size - (address - BASE)) return 0;
    *physical = address; return 1;
}
static int slow_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque; (void)address; (void)width; (void)value; f->slow_calls++; return 0;
}
static int slow_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque; (void)address; (void)width; (void)value; f->slow_calls++; return 0;
}
static void fault(void *opaque, uint64_t address, uint8_t access, uint8_t level, uint8_t status) {
    Fixture *f = opaque; f->faults++; f->fault_address = address;
    f->fault_access = access; f->fault_level = level; f->fault_status = status;
}
static void init(Fixture *f, AVZGuestMemory *shared, size_t size) {
    memset(f, 0, sizeof(*f));
    f->owns_memory = shared == NULL;
    f->memory = shared ? shared : avz_guest_memory_create(size);
    f->cache = avz_native_block_cache_create();
    CHECK(f->memory && f->cache);
    f->path = avz_native_memory_fast_path_create(f->memory->bytes, BASE, f->memory->size,
        f->cache, f, translate, slow_read, slow_write, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->path && avz_native_memory_fast_path_set_guest_memory(f->path, f->memory));
    avz_native_memory_fast_path_set_instruction_translator(f->path, translate);
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->path, 0);
}
static void destroy(Fixture *f) {
    avz_native_memory_fast_path_destroy(f->path);
    avz_native_block_cache_destroy(f->cache);
    if (f->owns_memory) avz_guest_memory_destroy(f->memory);
}
static void native_mapping(Fixture *f, int second_page) {
    for (unsigned i = 0; i < 3; i++)
        store(f->memory->bytes + TABLE + i * 4096, 8, (BASE + TABLE + (i + 1) * 4096) | 3);
    store(f->memory->bytes + TABLE + 3 * 4096, 8, (BASE + 0x2000) | 0xc03);
    store(f->memory->bytes + TABLE + 3 * 4096 + 8, 8,
        second_page == 2 ? 0 : ((BASE + 0x6000) | 0xc03 | (second_page == 1 ? 0x80 : 0)));
    AVZNativeStage1TranslationState state = {.sctlr_el1 = 1, .tcr_el1 = 16,
        .ttbr0_el1 = BASE + TABLE, .current_el = 1};
    avz_native_memory_fast_path_set_stage1_translation(f->path, &state, fault);
}
static void reset_fault(Fixture *f) {
    f->faults = 0; f->fault_address = 0; f->slow_calls = 0;
    f->fault_access = f->fault_level = f->fault_status = 0;
    avz_native_memory_fast_path_clear_translation_fault(f->path);
}
static void hash_fault(Fixture *f) {
    hash64(f->faults); hash64(f->fault_address); hash64(f->fault_access);
    hash64(f->fault_level); hash64(f->fault_status); hash64(f->path->translation_fault_pending);
}

static void boundary_cases(void) {
    for (int mapping = 0; mapping < 4; mapping++)
    for (int observed = 0; observed < 2; observed++)
    for (int code = 0; code < 2; code++) {
        Fixture f; init(&f, NULL, SIZE);
        if (mapping) native_mapping(&f, mapping - 1);
        if (observed) CHECK(avz_guest_memory_register_host_range(f.memory, 0, SIZE));
        if (code) {
            avz_guest_memory_mark_code_page(f.memory, BASE + (mapping ? 0x2000 : 0), BASE);
            avz_guest_memory_mark_code_page(f.memory, BASE + (mapping ? 0x6000 : 4096), BASE);
        }
        for (unsigned width = 4; width <= 8; width *= 2)
        for (unsigned warm = 0; warm < 2; warm++)
        for (unsigned slot = 0; slot < 64; slot++) {
            size_t offset = slot < 32 ? slot : 4072 + slot - 32;
            uint64_t address = (mapping ? 0 : BASE) + offset;
            size_t first = mapping ? (offset < 4096 ? 0x2000 : 0x6000) + offset % 4096 : offset;
            size_t next = offset + width;
            size_t second = mapping ? (next < 4096 ? 0x2000 : 0x6000) + next % 4096 : next;
            int aligned_pages = offset % 4096 + width <= 4096 && next % 4096 + width <= 4096;
            int readable = aligned_pages && !(mapping == 3 && next >= 4096);
            int writable = readable && !(mapping == 2 && next >= 4096);
            avz_native_memory_fast_path_invalidate_translation(f.path);
            if (warm) {
                uint64_t value;
                (void)avz_native_fast_memory_read(f.path, address, (uint8_t)width, &value);
                (void)avz_native_fast_memory_write(f.path, address, (uint8_t)width, 0);
            }
            memset(f.memory->bytes, 0xa5, CODE);
            uint8_t expected[CODE]; memcpy(expected, f.memory->bytes, sizeof(expected));
            uint64_t one = UINT64_C(0x123456789abcdef0), two = UINT64_C(0xfedcba9876543210);
            reset_fault(&f);
            int result = avz_native_fast_memory_write_pair(f.path, address, (uint8_t)width, one, two);
            CHECK(result == writable);
            CHECK(f.slow_calls == 0);
            if (writable) { store(expected + first, (uint8_t)width, one); store(expected + second, (uint8_t)width, two); }
            CHECK(memcmp(expected, f.memory->bytes, sizeof(expected)) == 0);
            hash64(result); hash_fault(&f);
            reset_fault(&f);
            one = UINT64_C(0x1122334455667788); two = UINT64_C(0x8877665544332211);
            result = avz_native_fast_memory_read_pair(f.path, address, (uint8_t)width, &one, &two);
            CHECK(result == readable);
            if (readable) {
                CHECK(one == load(expected + first, (uint8_t)width));
                CHECK(two == load(expected + second, (uint8_t)width));
            } else {
                CHECK(one == UINT64_C(0x1122334455667788) && two == UINT64_C(0x8877665544332211));
            }
            CHECK(f.slow_calls == 0);
            hash64(result); hash64(one); hash64(two); hash_fault(&f);
            hash(f.memory->bytes, CODE);
            hash64(avz_guest_memory_code_mutation_epoch(f.memory));
            hash64(atomic_load(&f.memory->current_write_generation));
            cases++;
        }
        destroy(&f);
    }
}

static void guards_and_contexts(void) {
    Fixture f; init(&f, NULL, 8192 + 8);
    memset(f.memory->bytes, 0xa5, f.memory->size);
    uint64_t a, b;
    CHECK(avz_native_fast_memory_read(f.path, BASE + 8192, 8, &a));
    CHECK(avz_native_fast_memory_write(f.path, BASE + 8192, 8, a));
    CHECK(!avz_native_fast_memory_read_pair(f.path, BASE + 8192, 8, &a, &b));
    CHECK(!avz_native_fast_memory_write_pair(f.path, BASE + 8192, 8, 0, 0));
    CHECK(load(f.memory->bytes + 8192, 8) == UINT64_C(0xa5a5a5a5a5a5a5a5));
    CHECK(!avz_native_fast_memory_read_pair(f.path, UINT64_MAX - 3, 8, &a, &b));
    CHECK(!avz_native_fast_memory_write_pair(f.path, BASE, 16, 0, 0));
    CHECK(!avz_native_fast_memory_read_pair(f.path, BASE, 8, NULL, &b));
    CHECK(!avz_native_fast_memory_write_pair(NULL, BASE, 8, 0, 0));
    destroy(&f);

    init(&f, NULL, SIZE); native_mapping(&f, 0);
    store(f.memory->bytes + 0x2000, 8, 11); store(f.memory->bytes + 0x2008, 8, 12);
    store(f.memory->bytes + 0x6000, 8, 21); store(f.memory->bytes + 0x6008, 8, 22);
    CHECK(avz_native_fast_memory_read_pair(f.path, 0, 8, &a, &b) && a == 11 && b == 12);
    AVZNativeStage1TranslationState state = f.path->translation_state;
    state.ttbr0_el1 |= UINT64_C(1) << 48;
    avz_native_memory_fast_path_set_stage1_translation(f.path, &state, fault);
    CHECK(avz_native_fast_memory_read_pair(f.path, 0, 8, &a, &b) && a == 11 && b == 12);
    memcpy(f.memory->bytes + TABLE + 4 * 4096, f.memory->bytes + TABLE, 4 * 4096);
    store(f.memory->bytes + TABLE + 4 * 4096, 8, (BASE + TABLE + 5 * 4096) | 3);
    store(f.memory->bytes + TABLE + 5 * 4096, 8, (BASE + TABLE + 6 * 4096) | 3);
    store(f.memory->bytes + TABLE + 6 * 4096, 8, (BASE + TABLE + 7 * 4096) | 3);
    store(f.memory->bytes + TABLE + 7 * 4096, 8, (BASE + 0x6000) | 0xc03);
    state.ttbr0_el1 = (UINT64_C(1) << 48) | (BASE + TABLE + 4 * 4096);
    avz_native_memory_fast_path_set_stage1_translation(f.path, &state, fault);
    CHECK(avz_native_fast_memory_read_pair(f.path, 0, 8, &a, &b) && a == 21 && b == 22);
    const uint64_t high_address = UINT64_C(0xffff000000000000);
    state.tcr_el1 |= UINT64_C(16) << 16;
    state.ttbr1_el1 = BASE + TABLE;
    avz_native_memory_fast_path_set_stage1_translation(f.path, &state, fault);
    CHECK(avz_native_fast_memory_read_pair(f.path, high_address, 8, &a, &b) && a == 11 && b == 12);
    state.ttbr1_el1 = BASE + TABLE + 4 * 4096;
    avz_native_memory_fast_path_set_stage1_translation(f.path, &state, fault);
    CHECK(avz_native_fast_memory_read_pair(f.path, high_address, 8, &a, &b) && a == 21 && b == 22);
    store(f.memory->bytes + TABLE + 7 * 4096, 8, (BASE + 0x2000) | 0xc03);
    avz_guest_memory_publish_tlbi(f.memory, (AVZNativeTLBI){.kind = AVZ_TLBI_ASID, .asid = 1});
    CHECK(avz_native_fast_memory_read_pair(f.path, high_address, 8, &a, &b) && a == 11 && b == 12);
    store(f.memory->bytes + TABLE + 7 * 4096, 8, (BASE + 0x6000) | 0xc03);
    for (unsigned i = 0; i < 65; i++) avz_guest_memory_publish_tlbi(f.memory,
        (AVZNativeTLBI){.kind = AVZ_TLBI_VA_ALL_ASIDS, .virtual_address = 0});
    CHECK(avz_native_fast_memory_read_pair(f.path, high_address, 8, &a, &b) && a == 21 && b == 22);
    hash64(a); hash64(b); cases += 2;
    destroy(&f);
}

typedef struct { Fixture *reader; _Atomic unsigned phase, ack; } Handoff;
static void *tlbi_reader(void *opaque) {
    Handoff *h = opaque;
    for (unsigned i = 1; i <= 1000; i++) {
        while (atomic_load_explicit(&h->phase, memory_order_acquire) != i) {}
        uint64_t a, b;
        CHECK(avz_native_fast_memory_read_pair(h->reader->path, 0, 8, &a, &b));
        CHECK(a == ((i & 1) ? 21u : 11u) && b == a + 1);
        atomic_store_explicit(&h->ack, i, memory_order_release);
    }
    return NULL;
}
static void *host_reader(void *opaque) {
    Fixture *f = opaque;
    for (unsigned i = 0; i < 4000; i++) {
        uint64_t values[2];
        avz_guest_memory_lock_range(f->memory, 0, sizeof(values));
        memcpy(values, f->memory->bytes, sizeof(values));
        avz_guest_memory_unlock_range(f->memory, 0, sizeof(values));
        CHECK(values[0] == ~values[1]);
    }
    return NULL;
}
typedef struct { Fixture *fixture; unsigned id; } AtomicWorker;
static void *atomic_worker(void *opaque) {
    AtomicWorker *worker = opaque;
    Fixture *f = worker->fixture;
    for (unsigned i = 0; i < 2000; i++) {
        uint64_t value, generation;
        unsigned attempts = 0;
        for (;;) {
            CHECK(++attempts < 1000000);
            CHECK(avz_native_fast_memory_exclusive_read(f->path, BASE + 256, 8, &value, &generation));
            int result = avz_native_fast_memory_exclusive_write(f->path, BASE + 256, 8, value + 1, generation);
            CHECK(result >= 0);
            if (result) break;
        }
        CHECK(avz_native_fast_memory_write_pair(f->path, BASE + 512 + worker->id * 64, 8, i, ~((uint64_t)i)));
    }
    return NULL;
}
static void concurrency(void) {
    Fixture a, b; init(&a, NULL, SIZE); init(&b, a.memory, SIZE);
    CHECK(avz_guest_memory_register_host_range(a.memory, 0, 16));
    CHECK(avz_native_fast_memory_write_pair(a.path, BASE, 8, 0, UINT64_MAX));
    pthread_t thread; CHECK(pthread_create(&thread, NULL, host_reader, &b) == 0);
    for (unsigned i = 0; i < 4000; i++)
        CHECK(avz_native_fast_memory_write_pair(a.path, BASE, 8, i, ~(uint64_t)i));
    CHECK(pthread_join(thread, NULL) == 0);
    for (uint8_t width = 4; width <= 8; width *= 2) {
        uint64_t first, second, generation;
        CHECK(avz_native_fast_memory_exclusive_read_pair(b.path, BASE, width, &first, &second, &generation));
        CHECK(avz_native_fast_memory_write_pair(a.path, BASE, width, first, second));
        CHECK(avz_native_fast_memory_exclusive_write_pair(b.path, BASE, width, first, second, generation) == 0);
        CHECK(avz_native_fast_memory_exclusive_read_pair(b.path, BASE, width, &first, &second, &generation));
        CHECK(avz_native_fast_memory_exclusive_write_pair(b.path, BASE, width, first, second, generation) == 1);
    }
    AtomicWorker workers[] = {{&a, 0}, {&b, 1}};
    pthread_t ids[2];
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_create(&ids[i], NULL, atomic_worker, &workers[i]) == 0);
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_join(ids[i], NULL) == 0);
    CHECK(load(a.memory->bytes + 256, 8) == 4000);
    for (unsigned i = 0; i < 2; i++) {
        CHECK(load(a.memory->bytes + 512 + i * 64, 8) == 1999);
        CHECK(load(a.memory->bytes + 520 + i * 64, 8) == ~UINT64_C(1999));
    }
    native_mapping(&b, 0);
    store(a.memory->bytes + 0x2000, 8, 11); store(a.memory->bytes + 0x2008, 8, 12);
    store(a.memory->bytes + 0x6000, 8, 21); store(a.memory->bytes + 0x6008, 8, 22);
    uint64_t first, second;
    CHECK(avz_native_fast_memory_read_pair(b.path, 0, 8, &first, &second));
    Handoff h = {.reader = &b};
    CHECK(pthread_create(&thread, NULL, tlbi_reader, &h) == 0);
    for (unsigned i = 1; i <= 1000; i++) {
        CHECK(avz_native_fast_memory_write(a.path, BASE + TABLE + 3 * 4096, 8,
            (BASE + ((i & 1) ? 0x6000 : 0x2000)) | 0xc03));
        avz_guest_memory_publish_tlbi(a.memory, (AVZNativeTLBI){
            .kind = i % 3 == 0 ? AVZ_TLBI_ALL : AVZ_TLBI_VA_ALL_ASIDS, .virtual_address = 0});
        atomic_store_explicit(&h.phase, i, memory_order_release);
        while (atomic_load_explicit(&h.ack, memory_order_acquire) != i) {}
    }
    CHECK(pthread_join(thread, NULL) == 0);
    hash64(atomic_load(&h.ack)); hash64(load(a.memory->bytes + 256, 8)); cases += 9004;
    destroy(&b); destroy(&a);
}

static uint64_t nanos(void) {
    struct timespec t; CHECK(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static uint64_t checkpoint(void *opaque, uint64_t steps, uint64_t blocks,
    uint64_t total, uint64_t pc, uint64_t pstate, uint64_t remaining) {
    (void)steps; (void)blocks; (void)total; (void)pc; (void)pstate; (void)remaining;
    (*(uint64_t *)opaque)++;
    return 64;
}

static void chain(uint64_t steps, int timed) {
    Fixture f; init(&f, NULL, SIZE);
    AVZNativeExecutionContext *context = avz_native_execution_context_create(); CHECK(context);
    const uint32_t block[] = {0xa9400540, 0x91000400, 0x91000c21, 0xa9000540,
        0xf9400942, 0x91000442, 0xf9000942, 0x14000001};
    for (unsigned b = 0; b < 4; b++) {
        memcpy(f.memory->bytes + CODE + b * sizeof(block), block, sizeof(block));
        if (b == 3) store(f.memory->bytes + CODE + b * sizeof(block) + 28, 4, 0x17ffffe1);
    }
    uint64_t x[31] = {0}; x[10] = BASE;
    uint64_t physical; uint32_t instruction;
    CHECK(avz_native_fast_fetch_instruction(f.path, BASE + CODE, &physical, &instruction));
    CHECK(physical == BASE + CODE && instruction == block[0]);
    avz_native_execution_context_load(context, x, NULL, NULL, 0, BASE + CODE, 5, 0, 0, 0, 0, 0, 0);
    AVZNativeBlockKey key = {.current_el = 1};
    uint64_t checkpoints = 0;
    uint64_t start = nanos();
    AVZNativeChainResult result = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
        context, f.cache, &key, 64, steps, steps, 64, checkpoint, &checkpoints,
        avz_native_fast_fetch_instruction, f.path, avz_native_fast_memory_read, avz_native_fast_memory_write,
        avz_native_fast_memory_can_access, avz_native_fast_memory_fill,
        NULL, NULL, NULL, NULL, NULL, NULL, f.path);
    uint64_t elapsed = nanos() - start;
    if (result.steps != steps || result.status != AVZ_NATIVE_STATUS_MAX_STEPS)
        fprintf(stderr, "chain steps=%" PRIu64 " status=%u decode=%u unsupported=%08x pc=%" PRIx64 "\n",
            result.steps, result.status, result.decode_status, result.unsupported_instruction,
            avz_native_execution_context_pc(context));
    CHECK(result.steps == steps && result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(result.superblock_dispatches > 0 && checkpoints > 0);
    uint64_t cycles = steps / 8;
    CHECK(load(f.memory->bytes, 8) == cycles);
    CHECK(load(f.memory->bytes + 8, 8) == cycles * 3);
    CHECK(load(f.memory->bytes + 16, 8) == cycles);
    avz_native_execution_context_store(context, x, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    uint64_t checksum = x[0] ^ x[1] ^ x[2] ^ avz_native_execution_context_pc(context);
    if (timed) printf("workload=cached-chain steps=%" PRIu64 " ns=%" PRIu64 " checksum=%" PRIu64
        " blocks=%" PRIu64 " superblock_dispatches=%" PRIu64 " checkpoints=%" PRIu64 "\n", steps, elapsed, checksum,
        result.blocks, result.superblock_dispatches, checkpoints);
    else { hash64(checksum); hash64(result.blocks); hash64(result.superblock_dispatches); hash64(checkpoints); cases++; }
    avz_native_execution_context_destroy(context); destroy(&f);
}

static void probe(void) {
    Fixture f; init(&f, NULL, SIZE);
    uint64_t a, b;
    CHECK(avz_native_fast_memory_write_pair(f.path, BASE, 8, 1, 2));
    CHECK(avz_native_fast_memory_read_pair(f.path, BASE, 8, &a, &b));
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f.path, 1);
    unsigned walks = f.walks;
    for (unsigned i = 0; i < 1000; i++) {
        CHECK(avz_native_fast_memory_read_pair(f.path, BASE, 8, &a, &b));
        CHECK(avz_native_fast_memory_write_pair(f.path, BASE, 8, a, b));
    }
    AVZNativeMemoryFastPathStatistics s = avz_native_memory_fast_path_statistics(f.path);
    printf("read_tlb_hits=%" PRIu64 " write_tlb_hits=%" PRIu64 " read_hits=%" PRIu64
        " write_hits=%" PRIu64 " new_walks=%u\n", s.read_tlb_hits, s.write_tlb_hits,
        s.read_hits, s.write_hits, f.walks - walks);
    destroy(&f);
}

static void mixed(uint64_t iterations, const char *mode, int timed) {
    Fixture f; init(&f, NULL, SIZE);
    int observed = !strcmp(mode, "observed"), cross = !strcmp(mode, "cross-page");
    int unaligned = !strcmp(mode, "unaligned"), cold = !strcmp(mode, "cold");
    uint8_t width = !strcmp(mode, "pair32") ? 4 : 8;
    if (observed) CHECK(avz_guest_memory_register_host_range(f.memory, 0, 32768));
    uint64_t checksum = 0, start = nanos();
    for (uint64_t i = 0; i < iterations; i++) {
        uint64_t address = BASE + ((i * 17) & 255) * 64 + (unaligned ? 3 : 0);
        if (cross) address = BASE + 4096 - width;
        if (cold) avz_native_memory_fast_path_invalidate_translation(f.path);
        uint64_t a, b, scalar;
        CHECK(avz_native_fast_memory_read_pair(f.path, address, width, &a, &b));
        CHECK(avz_native_fast_memory_write_pair(f.path, address, width, a + 1, b + 3));
        CHECK(avz_native_fast_memory_read(f.path, address + 32, 8, &scalar));
        CHECK(avz_native_fast_memory_write(f.path, address + 32, 8, scalar + 1));
        checksum += a ^ b ^ scalar;
    }
    uint64_t elapsed = nanos() - start;
    if (timed) printf("workload=%s steps=%" PRIu64 " ns=%" PRIu64 " checksum=%" PRIu64 "\n",
        mode, iterations, elapsed, checksum);
    else { hash64(checksum); cases++; }
    destroy(&f);
}

int main(int argc, char **argv) {
    const char *modes[] = {"pair64", "pair32", "unaligned", "observed", "cross-page", "cold"};
    if (argc == 2 && !strcmp(argv[1], "--probe")) { probe(); return 0; }
    if (argc == 3 && !strcmp(argv[1], "--benchmark")) {
        uint64_t steps = strtoull(argv[2], NULL, 10); CHECK(steps >= 1024 && steps % 8 == 0);
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) mixed(steps / 8, modes[i], 1);
        chain(steps, 1); return 0;
    }
    CHECK(argc == 1);
    boundary_cases(); guards_and_contexts(); concurrency(); chain(8192, 0);
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) mixed(256, modes[i], 0);
    printf("PASS cases=%" PRIu64 " digest=%016" PRIx64 "\n", cases, digest);
    return 0;
}
