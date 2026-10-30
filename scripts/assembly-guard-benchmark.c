/* Same-binary guard experiment, not the production entry. Coalescing is not
 * shipped. No callbacks, allocation, assertions or state comparisons in the
 * timed loop; result capture is identical for both experimental entries. */
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Require explicit experiment/control entries, not production ag_run_memory.
 * Never substitute the out-of-line ag_run_memory_control: that would also
 * change memory-view preparation. */
extern AVZNativeBlockResult ag_run_memory_uncoalesced(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);
extern AVZNativeBlockResult ag_run_memory_coalesced(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);

#define CHECK(x) do { if (!(x)) { \
    fprintf(stderr, "guard benchmark line %d: %s\n", __LINE__, #x); exit(1); \
} } while (0)

enum { RAM_SIZE = 0x10000, CODE = 0x1000, DATA = 0x4000, WARMUP = 4096 };
typedef AVZNativeBlockResult (*Runner)(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *path;
    AGProgram *program;
    unsigned translations, callbacks;
} Fixture;
typedef struct { uint64_t wall_ns, cpu_ns; } Timing;

static const struct {
    const char *name;
    uint32_t words[4];
} workloads[] = {
    {"register_attached", {0x91000400, 0x91000821, 0x91000c42, 0x17fffffd}},
    {"load64", {0xf9400140, 0x8b000021, 0x91000442, 0x17fffffd}},
    {"store64", {0xf9000140, 0x91000400, 0x91000421, 0x17fffffd}},
};

static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque;
    (void)write;
    f->translations++;
    if (address > RAM_SIZE - (uint64_t)width) return 0;
    *physical = address;
    return 1;
}
static int slow_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    (void)address; (void)width; (void)value;
    f->callbacks++;
    return 0;
}
static int slow_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    (void)address; (void)width; (void)value;
    f->callbacks++;
    return 0;
}
static void init(Fixture *f, const uint32_t *words) {
    memset(f, 0, sizeof(*f));
    f->ram = avz_guest_memory_create(RAM_SIZE);
    f->cache = avz_native_block_cache_create();
    CHECK(f->ram && f->cache);
    memcpy(avz_guest_memory_bytes(f->ram) + CODE, words, 4 * sizeof(*words));
    avz_guest_memory_mark_code_page(f->ram, CODE, 0);
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache,
        avz_guest_memory_bytes(f->ram), 0, RAM_SIZE));
    f->path = avz_native_memory_fast_path_create(avz_guest_memory_bytes(f->ram),
        0, RAM_SIZE, f->cache, f, translate, slow_read, slow_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->path && avz_native_memory_fast_path_set_guest_memory(f->path, f->ram));
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->path, 0);
    f->program = ag_create(words, 4, CODE);
    CHECK(f->program);
}
static void finish(Fixture *f) {
    ag_destroy(f->program);
    avz_native_memory_fast_path_destroy(f->path);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->ram);
}
static void initial_cpu(AVZNativeCPU *cpu) {
    memset(cpu, 0, sizeof(*cpu));
    cpu->pc = CODE;
    cpu->sp = DATA + 128;
    cpu->pstate = 5;
    cpu->x[0] = 17;
    cpu->x[10] = DATA;
    cpu->x[30] = UINT64_C(0x123456789abcdef0);
    cpu->exclusive_address = DATA;
    cpu->exclusive_generation = 77;
    cpu->exclusive_size = 8;
    cpu->exclusive_valid = 1;
    for (size_t i = 0; i < sizeof(cpu->v); i++)
        ((unsigned char *)cpu->v)[i] = (unsigned char)(i * 7);
}
static uint64_t reset(Fixture *f, const unsigned char *initial_ram, AVZNativeCPU *cpu) {
    /* Single-owner fixture only. Restore the exact bytes and warm both hot TLBs
     * outside timing, then use a fresh dirty epoch for each measured sample. */
    memcpy(avz_guest_memory_bytes(f->ram), initial_ram, RAM_SIZE);
    uint64_t value;
    CHECK(avz_native_fast_memory_write(f->path, DATA, 8, 17));
    CHECK(avz_native_fast_memory_read(f->path, DATA, 8, &value) && value == 17);
    initial_cpu(cpu);
    f->translations = f->callbacks = 0;
    avz_guest_memory_advance_dirty_epoch(f->ram);
    return atomic_load_explicit(&f->ram->current_epoch, memory_order_acquire);
}
static void check_cpu(const AVZNativeCPU *a, const AVZNativeCPU *b) {
    CHECK(!memcmp(a->x, b->x, sizeof(a->x)));
    CHECK(!memcmp(a->v, b->v, sizeof(a->v)));
    CHECK(a->sp == b->sp && a->pc == b->pc && a->pstate == b->pstate);
    CHECK(a->fpcr == b->fpcr && a->fpsr == b->fpsr);
    CHECK(a->exclusive_address == b->exclusive_address);
    CHECK(a->exclusive_generation == b->exclusive_generation);
    CHECK(a->exclusive_size == b->exclusive_size);
    CHECK(a->exclusive_valid == b->exclusive_valid && a->halted == b->halted);
}
static void check_results(const AVZNativeBlockResult *results, size_t calls, unsigned window) {
    for (size_t i = 0; i < calls; i++) {
        const AVZNativeBlockResult *r = &results[i];
        CHECK(r->steps == window && r->generic_dispatches == window);
        CHECK(!r->fast_path_steps && !r->fast_path_hits && !r->mapped_blocks);
        CHECK(r->status == AVZ_NATIVE_STATUS_MAX_STEPS && !r->unsupported_instruction);
    }
}
static uint64_t nanoseconds(clockid_t clock) {
    struct timespec t;
    CHECK(clock_gettime(clock, &t) == 0);
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static __attribute__((noinline)) void execute(Runner runner, Fixture *f,
    AVZNativeCPU *cpu, const AGGuards *guards, unsigned window, size_t calls,
    AVZNativeBlockResult *results) {
    for (size_t i = 0; i < calls; i++)
        results[i] = runner(f->program, window, cpu, guards, f->path);
}
static Timing timed(Runner runner, Fixture *f, AVZNativeCPU *cpu,
    const AGGuards *guards, unsigned window, size_t calls, AVZNativeBlockResult *results) {
    uint64_t cpu_start = nanoseconds(CLOCK_THREAD_CPUTIME_ID);
    uint64_t wall_start = nanoseconds(CLOCK_MONOTONIC);
    execute(runner, f, cpu, guards, window, calls, results);
    uint64_t wall_end = nanoseconds(CLOCK_MONOTONIC);
    uint64_t cpu_end = nanoseconds(CLOCK_THREAD_CPUTIME_ID);
    return (Timing){wall_end - wall_start, cpu_end - cpu_start};
}
static unsigned number(const char *text, unsigned maximum) {
    char *end;
    errno = 0;
    unsigned long n = strtoul(text, &end, 10);
    CHECK(!errno && *text && !*end && n && n <= maximum);
    return (unsigned)n;
}
int main(int argc, char **argv) {
    unsigned rounds = 15, steps = 65536;
    for (int i = 1; i < argc; i += 2) {
        CHECK(i + 1 < argc);
        if (!strcmp(argv[i], "--rounds")) rounds = number(argv[i + 1], 101);
        else if (!strcmp(argv[i], "--steps")) steps = number(argv[i + 1], 1048576);
        else { fprintf(stderr, "usage: %s [--rounds N] [--steps N]\n", argv[0]); return 2; }
    }
    CHECK(steps >= 16 && steps % 16 == 0 && ag_available());
    AVZNativeBlockResult *results = calloc(steps > WARMUP ? steps : WARMUP, sizeof(*results));
    unsigned char *initial_ram = malloc(RAM_SIZE);
    CHECK(results && initial_ram);
    const unsigned windows[] = {1, 4, 16};
    Runner runners[] = {ag_run_memory_uncoalesced, ag_run_memory_coalesced};
    const char *modes[] = {"uncoalesced", "coalesced"};
    fprintf(stderr, "guard experiment (not production): rounds=%u steps=%u warmup=%u; "
        "same fixture and indirect call site, all checks outside timing; "
        "timings include result-buffer stores\n", rounds, steps, WARMUP);
    puts("workload,guard,window,round,order,mode,steps,calls,wall_ns,cpu_ns,validated");
    for (unsigned work = 0; work < sizeof(workloads) / sizeof(workloads[0]); work++) {
        Fixture f, reference;
        init(&f, workloads[work].words);
        init(&reference, workloads[work].words);
        CHECK(ag_program_capabilities(f.program) == (work == 0 ? 1u : 2u));
        memcpy(initial_ram, avz_guest_memory_bytes(f.ram), RAM_SIZE);
        AVZNativeInstruction decoded[4];
        for (unsigned i = 0; i < 4; i++)
            CHECK(avz_native_decode_instruction(workloads[work].words[i], &decoded[i]));
        AVZNativeCPU expected;
        reset(&reference, initial_ram, &expected);
        AVZNativeBlockResult expected_result = ag_reference_memory(decoded, 4, CODE,
            steps, &expected, reference.path);
        CHECK(expected_result.steps == steps && expected_result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(!reference.callbacks);
        const uint64_t code_epoch = avz_guest_memory_code_mutation_epoch(f.ram);
        const uint64_t translation_epoch = avz_guest_memory_translation_epoch(f.ram);
        _Atomic uint64_t nonalias;
        atomic_init(&nonalias, code_epoch);
        AGGuards guards = {
            .local = avz_native_block_cache_code_mutation_epoch_token(f.cache),
            .expected = {avz_native_block_cache_code_mutation_epoch(f.cache), code_epoch},
        };
        CHECK(avz_native_block_cache_shared_code_mutation_epoch_token(f.cache) ==
            (const uint64_t *)&f.ram->code_mutation_epoch);
        for (unsigned alias = 0; alias < 2; alias++) {
            guards.shared[0] = alias ? &f.ram->code_mutation_epoch : &nonalias;
            CHECK(!guards.shared[1] && !guards.shared[2]);
            for (unsigned w = 0; w < sizeof(windows) / sizeof(windows[0]); w++) {
                unsigned window = windows[w];
                size_t calls = steps / window;
                for (unsigned round = 0; round < rounds; round++) {
                    Timing samples[2];
                    for (unsigned order = 0; order < 2; order++) {
                        unsigned mode = (round + work + alias + w + order) % 2;
                        AVZNativeCPU cpu;
                        reset(&f, initial_ram, &cpu);
                        execute(runners[mode], &f, &cpu, &guards, window, WARMUP / window, results);
                        check_results(results, WARMUP / window, window);
                        CHECK(!f.callbacks && !f.translations);
                        uint64_t epoch = reset(&f, initial_ram, &cpu);
                        memset(results, 0, calls * sizeof(*results));
                        samples[mode] = timed(runners[mode], &f, &cpu, &guards, window, calls, results);
                        check_results(results, calls, window);
                        check_cpu(&cpu, &expected);
                        CHECK(!memcmp(avz_guest_memory_bytes(f.ram),
                            avz_guest_memory_bytes(reference.ram), RAM_SIZE));
                        CHECK(!f.callbacks && !f.translations);
                        CHECK(avz_guest_memory_code_mutation_epoch(f.ram) == code_epoch);
                        CHECK(avz_guest_memory_translation_epoch(f.ram) == translation_epoch);
                        CHECK(*guards.local == guards.expected[0]);
                        CHECK(guards.shared[0] == (alias ? &f.ram->code_mutation_epoch : &nonalias));
                        CHECK(!guards.shared[1] && !guards.shared[2]);
                        CHECK(guards.expected[1] == code_epoch && !guards.expected[2] && !guards.expected[3]);
                        for (size_t page = 0; page < f.ram->page_count; page++) {
                            uint64_t dirty = atomic_load_explicit(&f.ram->page_epochs[page], memory_order_acquire);
                            CHECK(work == 2 && page == (DATA >> AVZ_FAST_PAGE_SHIFT)
                                ? dirty == epoch : dirty < epoch);
                        }
                    }
                    /* Emit only after both sides pass, with no I/O between the pair. */
                    for (unsigned order = 0; order < 2; order++) {
                        unsigned mode = (round + work + alias + w + order) % 2;
                        printf("%s,%s,%u,%u,%u,%s,%u,%zu,%" PRIu64 ",%" PRIu64 ",1\n",
                            workloads[work].name, alias ? "alias" : "nonalias", window,
                            round, order, modes[mode], steps, calls,
                            samples[mode].wall_ns, samples[mode].cpu_ns);
                    }
                }
            }
        }
        finish(&reference);
        finish(&f);
    }
    free(initial_ram);
    free(results);
    return 0;
}
