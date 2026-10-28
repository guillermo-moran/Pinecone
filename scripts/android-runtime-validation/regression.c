#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

/* Same standalone adapter as existing native regression scripts. Expectations
 * below come from byte models and real hardware, never another interpreter. */
#include "../../Sources/ARM64VizNative/ARM64VizNative.c"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
enum { SIZE = 16384, BASE = 0x100000, ENTRY = 0x8000, EXIT_PC = 0x9000 };
static unsigned cases, failures;
static uint64_t steps;
static double seconds(void) {
    struct timespec t; CHECK(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

extern size_t av_strlen(const void *);
extern void av_copy(void *, const void *, size_t);
extern void av_move(void *, const void *, size_t);
extern int av_compare(const void *, const void *, size_t);
extern void av_increment(uint64_t *);
extern const uint32_t av_strlen_end[], av_copy_end[], av_move_end[], av_compare_end[], av_increment_end[];
extern const uint32_t av_pair_words[];
typedef struct { AVZNativeInstruction d[256]; size_t n; } Program;
static Program program(const void *start, const void *end) {
    Program p = {0};
    p.n = ((uintptr_t)end - (uintptr_t)start) / 4;
    CHECK(p.n > 0 && p.n <= 256);
    for (size_t i = 0; i < p.n; i++) {
        uint32_t raw; memcpy(&raw, (const uint8_t *)start + 4 * i, 4);
        if (!avz_native_decode_instruction(raw, &p.d[i])) {
            fprintf(stderr, "decode rejected static instruction %08x\n", raw); exit(1);
        }
    }
    return p;
}
static Program word(uint32_t raw) { return program(&raw, &raw + 1); }
static AVZNativeCPU cpu(void) {
    AVZNativeCPU c = {0}; c.pc = ENTRY; c.x[30] = EXIT_PC; c.pstate = 5; return c;
}
typedef struct {
    uint8_t bytes[SIZE];
    size_t read_low, read_high, write_low, write_high;
    unsigned reads, writes, faults;
    uint64_t fault_address;
} Memory;
static int access_range(uint64_t address, uint8_t width, size_t low, size_t high) {
    return width && width <= 8 && address >= BASE + low && address <= BASE + high && width <= BASE + high - address;
}
static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Memory *m = opaque; m->reads++;
    if (!access_range(address, width, m->read_low, m->read_high)) {
        m->faults++; m->fault_address = address; return 0;
    }
    *value = 0; memcpy(value, m->bytes + (address - BASE), width); return 1;
}
static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Memory *m = opaque; m->writes++;
    if (!access_range(address, width, m->write_low, m->write_high)) {
        m->faults++; m->fault_address = address; return 0;
    }
    memcpy(m->bytes + (address - BASE), &value, width); return 1;
}
static int can_access_memory(void *opaque, uint64_t address, uint8_t width, uint8_t write) {
    Memory *m = opaque;
    return access_range(address, width, write ? m->write_low : m->read_low,
        write ? m->write_high : m->read_high);
}
static AVZNativeBlockResult run(const Program *p, AVZNativeCPU *c, void *m, int fast, uint64_t budget) {
    return avz_native_run_threaded_decoded_block_cpu_impl(p->d, p->n, ENTRY, budget, c,
        fast ? avz_native_fast_memory_read : read_memory,
        fast ? avz_native_fast_memory_write : write_memory,
        fast ? avz_native_fast_memory_can_access : can_access_memory,
        NULL, NULL, NULL, fast ? avz_native_fast_execute_system_instruction : NULL,
        NULL, NULL, NULL, m, NULL, fast);
}
static void complete(const Program *p, AVZNativeCPU *c, void *m, int fast) {
    AVZNativeBlockResult r = run(p, c, m, fast, 100000);
    if (r.status != AVZ_NATIVE_STATUS_OUTSIDE_BLOCK || c->pc != EXIT_PC)
        fprintf(stderr, "status=%u pc=%" PRIx64 " unsupported=%08x steps=%" PRIu64 " x0=%" PRIx64 " x1=%" PRIx64 " x2=%" PRIx64 "\n", r.status, c->pc, r.unsupported_instruction, r.steps, c->x[0], c->x[1], c->x[2]);
    CHECK(r.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK && c->pc == EXIT_PC);
}
static void pattern(uint8_t *bytes) {
    for (unsigned i = 0; i < SIZE; i++) bytes[i] = (uint8_t)(i * 37 + i / 7);
}
static void memory_cases(void) {
    Program len = program(av_strlen, av_strlen_end), copy = program(av_copy, av_copy_end);
    Program move = program(av_move, av_move_end), compare = program(av_compare, av_compare_end);
    const size_t lengths[] = {0,1,2,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257};
    for (unsigned l = 0; l < sizeof(lengths)/sizeof(*lengths); l++) {
        size_t n = lengths[l];
        for (size_t align = 0; align < 32; align++) {
            /* Includes a terminator exactly at byte 4095, and every SIMD alignment. */
            size_t src = 4095 - n - align, dst = 8192 + ((align * 7) % 32);
            Memory m = {.read_low = src, .read_high = src + n + 1};
            pattern(m.bytes); memset(m.bytes + src, 0xa5, n); m.bytes[src + n] = 0;
            AVZNativeCPU c = cpu(); c.x[0] = BASE + src;
            CHECK(av_strlen(m.bytes + src) == n);
            complete(&len, &c, &m, 0); CHECK(c.x[0] == n && !m.faults && m.reads == n + 1); cases++;

            pattern(m.bytes); m.read_high = src + n; m.write_low = dst; m.write_high = dst + n;
            uint8_t expected[SIZE]; memcpy(expected, m.bytes, SIZE);
            av_copy(expected + dst, expected + src, n);
            for (size_t i = 0; i < n; i++) CHECK(expected[dst + i] == m.bytes[src + i]);
            c = cpu(); c.x[0] = BASE + dst; c.x[1] = BASE + src; c.x[2] = n;
            complete(&copy, &c, &m, 0); CHECK(!m.faults && memcmp(expected, m.bytes, SIZE) == 0); cases++;

            for (int delta = -17; delta <= 17; delta++) {
                size_t from = 4096 - n / 2, to = from + delta;
                pattern(m.bytes); memcpy(expected, m.bytes, SIZE);
                uint8_t snapshot[257]; memcpy(snapshot, expected + from, n);
                for (size_t i = 0; i < n; i++) expected[to + i] = snapshot[i];
                uint8_t native[SIZE]; memcpy(native, m.bytes, SIZE); av_move(native + to, native + from, n);
                CHECK(memcmp(native, expected, SIZE) == 0);
                m.read_low = from; m.read_high = from + n; m.write_low = to; m.write_high = to + n;
                c = cpu(); c.x[0] = BASE + to; c.x[1] = BASE + from; c.x[2] = n;
                complete(&move, &c, &m, 0); CHECK(!m.faults && memcmp(expected, m.bytes, SIZE) == 0); cases++;
            }
            /* Every mismatch position, including high-bit bytes and equality. */
            for (size_t mismatch = 0; mismatch <= n; mismatch++) {
                pattern(m.bytes); memcpy(m.bytes + dst, m.bytes + src, n);
                if (mismatch < n) { m.bytes[src + mismatch] = 0x80; m.bytes[dst + mismatch] = 0x7f; }
                m.read_low = 0; m.read_high = SIZE;
                c = cpu(); c.x[0] = BASE + src; c.x[1] = BASE + dst; c.x[2] = n;
                int wanted = mismatch == n ? 0 : 1;
                CHECK(av_compare(m.bytes + src, m.bytes + dst, n) == wanted);
                complete(&compare, &c, &m, 0); CHECK((int32_t)c.x[0] == wanted && !m.faults); cases++;
            }
        }
    }
    /* Exact callback fault boundary: load post-index must not retire or update x1. */
    for (size_t n = 0; n <= 32; n++) {
        Memory m = {.read_low = 4096 - n, .read_high = 4096};
        memset(m.bytes, 0xa5, SIZE);
        AVZNativeCPU c = cpu(); c.x[0] = BASE + 4096 - n;
        AVZNativeBlockResult r = run(&len, &c, &m, 0, 1000);
        CHECK(r.steps == 1 + 2 * n && c.pc == ENTRY + 4);
        CHECK(c.x[1] == BASE + 4096 && m.faults == 1 && m.fault_address == BASE + 4096);
        CHECK(r.status != AVZ_NATIVE_STATUS_MAX_STEPS); cases++;
    }
    printf("memory cases=%u\n", cases);
}

typedef uint64_t (*Reference)(const void *, const void *, void *, uint64_t, uint64_t);
#define DECL_FP(name) extern uint64_t name(const void *, const void *, void *, uint64_t, uint64_t); extern const uint32_t name##_op[]
DECL_FP(av_fadd); DECL_FP(av_fdiv); DECL_FP(av_vfadd); DECL_FP(av_cmeq); DECL_FP(av_umaxv); DECL_FP(av_uqadd);
static void fp_cases(void) {
    const struct { const char *name; Reference fn; const uint32_t *op; } tests[] = {
        {"fadd.d", av_fadd, av_fadd_op}, {"fdiv.d", av_fdiv, av_fdiv_op},
        {"fadd.4s", av_vfadd, av_vfadd_op}, {"cmeq.16b", av_cmeq, av_cmeq_op},
        {"umaxv.16b", av_umaxv, av_umaxv_op}, {"uqadd.16b", av_uqadd, av_uqadd_op}
    };
    const uint64_t values[] = {0, UINT64_C(0x8000000000000000), UINT64_C(0x3ff0000000000000),
        UINT64_C(0xbff0000000000000), UINT64_C(0x3ca0000000000000), 1,
        UINT64_C(0x0010000000000000), UINT64_C(0x7fefffffffffffff), UINT64_C(0x7ff0000000000000),
        UINT64_C(0xfff0000000000000), UINT64_C(0x7ff8000000001234), UINT64_C(0x7ff0000000000001),
        UINT64_C(0x3f80000000000001), UINT64_C(0x7f8000007fc00001), UINT64_C(0x7f80000180000000),
        UINT64_C(0xffffffffffffffff)};
    for (size_t t = 0; t < sizeof(tests)/sizeof(*tests); t++) {
        unsigned failed = 0, total = 0, bit_failures = 0, flag_failures = 0;
        AVZNativeInstruction d;
        if (!avz_native_decode_instruction(*tests[t].op, &d)) {
            fprintf(stderr, "FAIL advertised FP/ASIMD instruction %s raw=%08x not decoded\n", tests[t].name, *tests[t].op);
            failures++; continue;
        }
        Program p = word(*tests[t].op);
        for (unsigned mode = 0; mode < 16; mode++)
        for (unsigned a = 0; a < sizeof(values)/sizeof(*values); a++)
        for (unsigned b = 0; b < sizeof(values)/sizeof(*values); b++) {
            uint64_t fpcr = ((uint64_t)(mode & 3) << 22) | ((uint64_t)(mode >> 2) << 24);
            AVZNativeVectorRegister va = {values[a], values[(a+3)%16]}, vb = {values[b], values[(b+7)%16]}, expected;
            uint64_t initial_fpsr = (a & 1) ? UINT64_C(0x08000010) : 0;
            uint64_t expected_fpsr = tests[t].fn(&va, &vb, &expected, fpcr, initial_fpsr);
            AVZNativeCPU c = cpu(); c.v[0].low = c.v[0].high = UINT64_MAX;
            c.v[1] = va; c.v[2] = vb; c.fpcr = fpcr; c.fpsr = initial_fpsr;
            AVZNativeBlockResult r = run(&p, &c, NULL, 0, 1);
            if (memcmp(&c.v[0], &expected, 16)) {
                if (bit_failures < 2) fprintf(stderr, "BITS %s fpcr=%08" PRIx64 " a=%016" PRIx64 " b=%016" PRIx64 " actual=%016" PRIx64 ":%016" PRIx64 " expected=%016" PRIx64 ":%016" PRIx64 "\n", tests[t].name, fpcr, va.low, vb.low, c.v[0].high, c.v[0].low, expected.high, expected.low);
                bit_failures++;
            }
            if (c.fpsr != expected_fpsr) flag_failures++;
            if (r.steps != 1 || memcmp(&c.v[0], &expected, 16) || c.fpsr != expected_fpsr || c.fpcr != fpcr || c.pc != ENTRY + 4) {
                if (failed < 3) fprintf(stderr, "FAIL %s raw=%08x fpcr=%08" PRIx64 " a=%016" PRIx64 " b=%016" PRIx64 " result=%016" PRIx64 ":%016" PRIx64 " expected=%016" PRIx64 ":%016" PRIx64 " fpsr=%08" PRIx64 "/%08" PRIx64 " steps=%" PRIu64 "\n", tests[t].name, *tests[t].op, fpcr, va.low, vb.low, c.v[0].high, c.v[0].low, expected.high, expected.low, c.fpsr, expected_fpsr, r.steps);
                failed++;
            }
            total++;
        }
        cases += total; failures += failed;
        printf("fp/neon op=%s cases=%u failures=%u result_bits=%u fpsr=%u\n", tests[t].name, total, failed, bit_failures, flag_failures);
    }
}

typedef struct { AVZNativeBlockCache *cache; AVZNativeMemoryFastPath *fast; } VCPU;
static int translate(void *opaque, uint64_t address, uint8_t width, uint8_t write, uint64_t *physical) {
    (void)opaque; (void)write;
    if (address < BASE || address > BASE + SIZE || width > BASE + SIZE - address) return 0;
    *physical = address; return 1;
}
static int shared_can_access(void *opaque, uint64_t address, uint8_t width, uint8_t write) {
    (void)opaque; (void)write; return access_range(address, width, 0, SIZE);
}
static int shared_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    AVZGuestMemory *m = opaque;
    if (!shared_can_access(m, address, width, 0)) return 0;
    size_t offset = address - BASE;
    avz_guest_memory_lock_range(m, offset, width);
    *value = 0; memcpy(value, avz_guest_memory_bytes(m) + offset, width);
    avz_guest_memory_unlock_range(m, offset, width); return 1;
}
static int shared_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    AVZGuestMemory *m = opaque;
    if (!shared_can_access(m, address, width, 1)) return 0;
    size_t offset = address - BASE;
    avz_guest_memory_lock_range(m, offset, width);
    memcpy(avz_guest_memory_bytes(m) + offset, &value, width);
    avz_guest_memory_note_write(m, offset, width);
    avz_guest_memory_unlock_range(m, offset, width); return 1;
}
static VCPU vcpu(AVZGuestMemory *memory) {
    VCPU v = {.cache = avz_native_block_cache_create()}; CHECK(v.cache);
    v.fast = avz_native_memory_fast_path_create(avz_guest_memory_bytes(memory), BASE, SIZE,
        v.cache, memory, translate, shared_read, shared_write, shared_can_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(v.fast && avz_native_memory_fast_path_set_guest_memory(v.fast, memory));
    avz_native_memory_fast_path_set_instruction_translator(v.fast, translate); return v;
}
static void destroy(VCPU v) { avz_native_memory_fast_path_destroy(v.fast); avz_native_block_cache_destroy(v.cache); }
static void fast_memory_cases(void) {
    AVZGuestMemory *m = avz_guest_memory_create(SIZE); CHECK(m);
    VCPU v = vcpu(m); uint8_t *bytes = avz_guest_memory_bytes(m), expected[SIZE];
    Program copy = program(av_copy, av_copy_end), move = program(av_move, av_move_end), len = program(av_strlen, av_strlen_end);
    const unsigned lengths[] = {0,1,15,16,17,63,64,65,255,256,257,4095};
    unsigned total = 0;
    for (unsigned l = 0; l < sizeof(lengths)/sizeof(*lengths); l++)
    for (unsigned align = 0; align < 32; align++) {
        unsigned n = lengths[l], src = 4096 + align, dst = 9000 + align;
        pattern(bytes); memcpy(expected, bytes, SIZE); memcpy(expected + dst, expected + src, n);
        avz_guest_memory_note_write(m, 0, SIZE);
        AVZNativeCPU c = cpu(); c.x[0] = BASE + dst; c.x[1] = BASE + src; c.x[2] = n;
        complete(&copy, &c, v.fast, 1); CHECK(memcmp(bytes, expected, SIZE) == 0); total++;
        for (int delta = -17; delta <= 17; delta += 17) {
            pattern(bytes); memcpy(expected, bytes, SIZE); memmove(expected + src + delta, expected + src, n);
            avz_guest_memory_note_write(m, 0, SIZE);
            c = cpu(); c.x[0] = BASE + src + delta; c.x[1] = BASE + src; c.x[2] = n;
            complete(&move, &c, v.fast, 1); CHECK(memcmp(bytes, expected, SIZE) == 0); total++;
        }
        memset(bytes + src, 0xff, n); bytes[src + n] = 0;
        avz_guest_memory_note_write(m, src, n + 1);
        c = cpu(); c.x[0] = BASE + src;
        complete(&len, &c, v.fast, 1); CHECK(c.x[0] == n); total++;
    }
    cases += total; printf("fast_memory cases=%u\n", total);
    destroy(v); avz_guest_memory_destroy(m);
}
static void single(uint32_t raw, AVZNativeCPU *c, VCPU v) {
    Program p = word(raw); c->pc = ENTRY;
    AVZNativeBlockResult r = run(&p, c, v.fast, 1, 1);
    CHECK(r.steps == 1 && c->pc == ENTRY + 4);
}
typedef struct { VCPU v; unsigned role; uint64_t retired; } Worker;
static void *increment_worker(void *opaque) {
    Worker *w = opaque; Program p = program(av_increment, av_increment_end);
    for (unsigned i = 0; i < 2000; i++) {
        AVZNativeCPU c = cpu(); c.x[0] = BASE + 4096;
        AVZNativeBlockResult r = run(&p, &c, w->v.fast, 1, 100000);
        CHECK(c.pc == EXIT_PC && r.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        w->retired += r.steps;
    }
    return NULL;
}
static void *message_worker(void *opaque) {
    Worker *w = opaque; AVZNativeCPU c = cpu();
    /* x0 is the release/acquire flag, x3 is the payload. No host per-message sync. */
    c.x[0] = BASE + 8192; c.x[3] = BASE + 8256;
    double deadline = seconds() + 15;
    for (unsigned i = 1; i <= 2000; i++) {
        unsigned polls = 0;
        do {
            single(0xc8dffc01, &c, w->v); /* ldar x1, [x0] */
            if ((++polls & 4095) == 0) CHECK(seconds() < deadline);
        } while (c.x[1] != w->role);
        if (!w->role) {
            c.x[2] = UINT64_C(0x1234567800000000) + i;
            single(0xf9000062, &c, w->v); /* str x2, [x3] */
            c.x[1] = 1;
        } else {
            single(0xf9400062, &c, w->v); /* ldr x2, [x3] */
            CHECK(c.x[2] == UINT64_C(0x1234567800000000) + i);
            c.x[1] = 0;
        }
        single(0xc89ffc01, &c, w->v); /* stlr x1, [x0] */
    }
    return NULL;
}
static void atomic_cases(void) {
    AVZGuestMemory *m = avz_guest_memory_create(SIZE); CHECK(m);
    VCPU a = vcpu(m), b = vcpu(m);
    /* All scalar widths; same-value remote writes must invalidate reservations. */
    for (unsigned size = 0; size < 4; size++) {
        unsigned width = 1u << size;
        for (unsigned aba = 0; aba < 3; aba++) {
            CHECK(avz_native_fast_memory_write(a.fast, BASE + 4096, width, 17));
            AVZNativeCPU c = cpu(); c.x[0] = BASE + 4096;
            single(0x085ffc01 | (size << 30), &c, a); /* ldaxr[b/h] w/x1, [x0] */
            CHECK(c.x[1] == 17 && c.exclusive_valid);
            if (aba) CHECK(avz_native_fast_memory_write(b.fast, c.x[0], width, aba == 1 ? 17 : 18));
            if (aba == 2) CHECK(avz_native_fast_memory_write(b.fast, c.x[0], width, 17));
            c.x[1] = 23;
            single(0x0802fc01 | (size << 30), &c, a); /* stlxr[b/h] w2, w/x1, [x0] */
            CHECK(c.x[2] == (aba != 0) && !c.exclusive_valid);
            uint64_t value; CHECK(avz_native_fast_memory_read(b.fast, BASE + 4096, width, &value));
            CHECK(value == (aba ? 17 : 23)); cases++;
        }
    }
    for (unsigned size = 2; size <= 3; size++)
    for (unsigned boundary = 0; boundary < 2; boundary++)
    for (unsigned remote = 0; remote < 3; remote++) {
        unsigned width = 1u << size;
        uint64_t address = BASE + 4096 - (boundary ? 2 * width : 0);
        CHECK(avz_native_fast_memory_write(a.fast, address, width, 17));
        CHECK(avz_native_fast_memory_write(a.fast, address + width, width, 29));
        AVZNativeCPU c = cpu(); c.x[0] = address;
        uint32_t load = (av_pair_words[0] & 0x3fffffff) | (size << 30);
        uint32_t store = (av_pair_words[1] & 0x3fffffff) | (size << 30);
        single(load, &c, a); CHECK(c.x[1] == 17 && c.x[2] == 29);
        if (remote) CHECK(avz_native_fast_memory_write(b.fast, address + (remote - 1) * width, width, remote == 1 ? 17 : 29));
        c.x[1] = 31; c.x[2] = 43;
        single(store, &c, a); CHECK(c.x[3] == (remote != 0) && !c.exclusive_valid);
        uint64_t first, second;
        CHECK(avz_native_fast_memory_read(b.fast, address, width, &first));
        CHECK(avz_native_fast_memory_read(b.fast, address + width, width, &second));
        CHECK(first == (remote ? 17 : 31) && second == (remote ? 29 : 43)); cases++;
    }
    AVZNativeInstruction clrex;
    if (!avz_native_decode_instruction(0xd5033f5f, &clrex)) {
        fprintf(stderr, "FAIL native coverage: CLREX d5033f5f is not decoded; no fallback enabled\n");
        failures++;
    } else {
        AVZNativeCPU c = cpu(); c.x[0] = BASE + 4096;
        single(0xc85ffc01, &c, a); single(0xd5033f5f, &c, a);
        single(0xc802fc01, &c, a); CHECK(c.x[2] == 1 && !c.exclusive_valid);
    }
    cases++;
    CHECK(avz_native_fast_memory_write(a.fast, BASE + 4096, 8, 0));
    Worker workers[2] = {{a, 0, 0}, {b, 1, 0}}; pthread_t threads[2];
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_create(&threads[i], NULL, increment_worker, &workers[i]) == 0);
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    uint64_t value; CHECK(avz_native_fast_memory_read(a.fast, BASE + 4096, 8, &value)); CHECK(value == 4000);
    uint64_t native = 0; for (unsigned i = 0; i < 4000; i++) av_increment(&native); CHECK(native == value);
    steps += workers[0].retired + workers[1].retired; cases++;
    CHECK(avz_native_fast_memory_write(a.fast, BASE + 8192, 8, 0));
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_create(&threads[i], NULL, message_worker, &workers[i]) == 0);
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    cases += 2000;
    printf("atomic counter=%" PRIu64 " increment_steps=%" PRIu64 " messages=2000 deterministic_reservations=25\n", value, steps);
    destroy(a); destroy(b); avz_guest_memory_destroy(m);
}

static uint64_t execute_cached(VCPU v, uint64_t pc) {
    AVZNativeBlockKey key = {.pc = pc, .current_el = 1};
    uint32_t status, unsupported;
    const AVZNativeDecodedBlock *block = avz_native_block_cache_get_or_decode(v.cache, &key,
        avz_native_fast_fetch_instruction, v.fast, &status, &unsupported);
    CHECK(block && status == AVZ_NATIVE_BLOCK_DECODE_OK);
    Program p = {.n = avz_native_decoded_block_instruction_count(block)}; CHECK(p.n <= 64);
    memcpy(p.d, avz_native_decoded_block_instructions(block), p.n * sizeof(*p.d));
    AVZNativeCPU c = cpu(); c.pc = pc;
    AVZNativeBlockResult r = avz_native_run_threaded_decoded_block_cpu_impl(p.d, p.n, pc, 100,
        &c, avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, avz_native_fast_execute_system_instruction, NULL, NULL, NULL, v.fast, NULL, 1);
    CHECK(r.steps == 2 && c.pc == EXIT_PC); return c.x[0];
}
static void *publication_worker(void *opaque) {
    Worker *w = opaque;
    AVZNativeCPU c = cpu(); c.x[0] = BASE + 12288;
    const uint64_t entry = BASE + 4092;
    double deadline = seconds() + 15;
    for (unsigned generation = 1; generation <= 1000; generation++) {
        unsigned polls = 0;
        do {
            single(0xc8dffc01, &c, w->v);
            if ((++polls & 4095) == 0) CHECK(seconds() < deadline);
        } while (w->role ? c.x[1] == 0 : c.x[1] != 0);
        if (!w->role) {
            CHECK(avz_native_fast_memory_write(w->v.fast, entry, 4, 0xd2800000 | (generation << 5)));
            AVZNativeCPU maintenance = cpu(); maintenance.x[0] = entry;
            single(0xd50b7b20, &maintenance, w->v);
            single(0xd5033b9f, &maintenance, w->v);
            single(0xd50b7520, &maintenance, w->v);
            single(0xd5033b9f, &maintenance, w->v);
            c.x[1] = generation;
        } else {
            CHECK(c.x[1] == generation);
            single(0xd5033fdf, &c, w->v);
            CHECK(execute_cached(w->v, entry) == generation);
            c.x[1] = 0;
        }
        single(0xc89ffc01, &c, w->v);
    }
    return NULL;
}
static void publication_cases(void) {
    AVZGuestMemory *m = avz_guest_memory_create(SIZE); CHECK(m);
    VCPU a = vcpu(m), b = vcpu(m);
    const uint64_t locations[] = {BASE + 256, BASE + 4092, BASE + 8192};
    for (unsigned loc = 0; loc < 3; loc++) {
        uint64_t pc = locations[loc];
        CHECK(avz_native_fast_memory_write(a.fast, pc + 4, 4, 0xd65f03c0)); /* ret */
        for (unsigned generation = 1; generation <= 200; generation++) {
            uint32_t raw = 0xd2800000 | (generation << 5); /* movz x0, #generation */
            CHECK(avz_native_fast_memory_write(a.fast, pc, 4, raw));
            /* These are guest cache-maintenance instructions, never host generated code. */
            AVZNativeCPU c = cpu(); c.x[0] = pc;
            single(0xd50b7b20, &c, a); /* dc cvau, x0 */
            single(0xd5033b9f, &c, a); /* dsb ish */
            single(0xd50b7520, &c, a); /* ic ivau, x0 */
            single(0xd5033b9f, &c, a);
            single(0xd5033fdf, &c, b); /* consumer isb */
            CHECK(execute_cached(a, pc) == generation);
            CHECK(execute_cached(b, pc) == generation);
            CHECK(execute_cached(b, pc) == generation); /* warm cache hit */
            cases++;
        }
    }
    printf("publication generations=600 cached_executions=1800 vcpus=2 page_straddling_entries=1\n");
    CHECK(avz_native_fast_memory_write(a.fast, BASE + 12288, 8, 0));
    Worker workers[2] = {{a, 0, 0}, {b, 1, 0}}; pthread_t threads[2];
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_create(&threads[i], NULL, publication_worker, &workers[i]) == 0);
    for (unsigned i = 0; i < 2; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    cases += 1000;
    puts("concurrent_publication generations=1000 guest_release_acquire_handshake=1");
    destroy(a); destroy(b); avz_guest_memory_destroy(m);
}
#ifdef AVZ_BIONIC_REFERENCE
extern size_t av_bionic_strlen(const void *);
extern const uint32_t av_bionic_strlen_end[];
static void bionic_cases(void) {
    Program p = program(av_bionic_strlen, av_bionic_strlen_end);
    /* Match native and guest page offsets. Native memory is padded, while guest
     * callbacks reject any access outside the 4 KiB page containing the string. */
    _Alignas(4096) uint8_t native[SIZE];
    Memory m = {.read_low = 0, .read_high = 4096};
    const unsigned lengths[] = {0,1,2,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,1023};
    for (unsigned l = 0; l < sizeof(lengths)/sizeof(*lengths); l++)
    for (unsigned tail = 0; tail < 64; tail++)
    for (unsigned pattern = 0; pattern < 4; pattern++) {
        unsigned n = lengths[l], start = 4095 - tail - n;
        memset(m.bytes, 0, SIZE);
        for (unsigned i = 0; i < n; i++) {
            const uint8_t samples[] = {0x01, 0x7f, 0x80, 0xff};
            m.bytes[start + i] = samples[(i + pattern) % 4];
            if (pattern == 0) m.bytes[start + i] = 'A';
        }
        memcpy(native, m.bytes, SIZE);
        CHECK(av_bionic_strlen(native + start) == n);
        AVZNativeCPU c = cpu(); c.x[0] = BASE + start;
        AVZNativeBlockResult r = run(&p, &c, &m, 0, 100000);
        if (c.pc != EXIT_PC) fprintf(stderr, "BIONIC n=%u start=%u pc=%" PRIx64 " x0=%" PRIx64 " x1=%" PRIx64 " reads=%u faults=%u address=%" PRIx64 " status=%u steps=%" PRIu64 "\n", n, start, c.pc, c.x[0], c.x[1], m.reads, m.faults, m.fault_address, r.status, r.steps);
        CHECK(c.pc == EXIT_PC && r.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        CHECK(c.x[0] == n && m.faults == 0 && m.writes == 0); cases++;
    }
    printf("PINNED_BIONIC strlen cases=%u instructions=%zu failures=0 full_runtime_conformance=0\n", cases, p.n);
}
#endif
int main(int argc, char **argv) {
    CHECK(argc == 2); setbuf(stdout, NULL); alarm(120); double start = seconds();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "memory")) { memory_cases(); fast_memory_cases(); }
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "fp")) fp_cases();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "atomic")) atomic_cases();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "publication")) publication_cases();
#ifdef AVZ_BIONIC_REFERENCE
    if (!strcmp(argv[1], "bionic")) { bionic_cases(); return 0; }
#endif
    printf("SUMMARY cases=%u failures=%u seconds=%.6f synthetic_only=1\n", cases, failures, seconds() - start);
    return failures ? 1 : 0;
}
