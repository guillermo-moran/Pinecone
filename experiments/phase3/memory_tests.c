#include "gadget_internal.h"
#include <execinfo.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "memory line %d: %s\n", __LINE__, #x); abort(); } } while (0)
enum { RAM_SIZE = 0x40000, CODE = 0x1000, DATA = 0x4000, DEVICE = 0x100000 };
enum { NONE, RETIRE, REMAP, TRANSLATE_RETIRE };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache[2];
    AVZNativeMemoryFastPath *path[2];
    AGProgram *program;
    unsigned calls, faults, action;
    int fail, remapped, clobber, unwound;
    uint64_t last_value, device_value;
    unsigned fail_call, preflights, writes;
    uint64_t deny_address, device_writes[2];
} Fixture;
extern uint64_t ag_abi_probe(AGRun *run);
extern void ag_clobber_volatile(void);
extern void ag_code_end(void);

static void action(Fixture *f) {
    unsigned a = f->action;
    f->action = NONE;
    if (a == RETIRE || a == TRANSLATE_RETIRE) {
        ag_destroy(f->program);
        f->program = NULL;
        avz_native_block_cache_clear(f->cache[0]);
    } else if (a == REMAP) {
        f->remapped = 1;
        avz_native_memory_fast_path_invalidate_translation(f->path[0]);
    }
    if (f->clobber) {
        void *stack[32];
        int count = backtrace(stack, 32);
        for (int i = 0; i < count; i++) {
            uintptr_t pc = (uintptr_t)stack[i];
            if (pc >= (uintptr_t)ag_enter && pc < (uintptr_t)ag_code_end) f->unwound = 1;
        }
        ag_clobber_volatile();
    }
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    Fixture *f = opaque; (void)write;
    if (f->action == TRANSLATE_RETIRE && address == DATA) action(f);
    if (address > RAM_SIZE - width) return 0;
    *physical = address + (f->remapped && address >= DATA && address < DATA + 4096 ? 4096 : 0);
    return 1;
}
static int read_memory(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    if (address < DEVICE || address >= DEVICE + 16) {
        CHECK(width <= 8 && address <= RAM_SIZE - width);
        avz_guest_memory_lock_range(f->ram, address, width);
        *value = 0;
        memcpy(value, avz_guest_memory_bytes(f->ram) + address, width);
        avz_guest_memory_unlock_range(f->ram, address, width);
        return 1;
    }
    f->calls++; action(f); *value = address == DEVICE ? f->device_value : 0x7ffffffe;
    return !f->fail && f->calls != f->fail_call;
}
static int write_memory(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    if (address < DEVICE || address >= DEVICE + 16) {
        CHECK(width <= 8 && address <= RAM_SIZE - width);
        avz_guest_memory_lock_range(f->ram, address, width);
        memcpy(avz_guest_memory_bytes(f->ram) + address, &value, width);
        avz_guest_memory_note_write(f->ram, address, width);
        avz_guest_memory_unlock_range(f->ram, address, width);
        return 1;
    }
    f->calls++; f->last_value = value; action(f);
    if (f->fail || f->calls == f->fail_call) return 0;
    f->device_writes[address != DEVICE] = value; f->writes++;
    return 1;
}
static int can_access(void *opaque, uint64_t address, uint8_t width, uint8_t write) {
    Fixture *f = opaque; (void)write; f->preflights++;
    return address != f->deny_address &&
        (address <= RAM_SIZE - width || (address >= DEVICE && address <= DEVICE + 16 - width));
}
static void fault(void *opaque, uint64_t address, uint8_t access,
    uint8_t level, uint8_t status) {
    Fixture *f = opaque; (void)address; (void)access; (void)level; (void)status;
    f->faults++; action(f);
}
static void init(Fixture *f, const uint32_t *words, size_t count) {
    memset(f, 0, sizeof(*f));
    f->device_value = 73;
    f->ram = avz_guest_memory_create(RAM_SIZE); CHECK(f->ram);
    memcpy(avz_guest_memory_bytes(f->ram) + CODE, words, count * 4);
    f->program = ag_create(words, count, CODE); CHECK(f->program);
    avz_guest_memory_mark_code_page(f->ram, CODE, 0);
    for (unsigned i = 0; i < 2; i++) {
        f->cache[i] = avz_native_block_cache_create(); CHECK(f->cache[i]);
        CHECK(avz_native_block_cache_bind_physical_memory(f->cache[i], avz_guest_memory_bytes(f->ram), 0, RAM_SIZE));
        f->path[i] = avz_native_memory_fast_path_create(avz_guest_memory_bytes(f->ram),
            0, RAM_SIZE, f->cache[i], f, translate, read_memory, write_memory,
            can_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        CHECK(f->path[i] && avz_native_memory_fast_path_set_guest_memory(f->path[i], f->ram));
        avz_native_memory_fast_path_set_detailed_statistics_enabled(f->path[i], 0);
    }
}
static void finish(Fixture *f) {
    ag_destroy(f->program);
    for (unsigned i = 0; i < 2; i++) {
        avz_native_memory_fast_path_destroy(f->path[i]);
        avz_native_block_cache_destroy(f->cache[i]);
    }
    avz_guest_memory_destroy(f->ram);
}
static void warm(Fixture *f, unsigned path, uint64_t address, uint8_t width, uint64_t value) {
    uint64_t v;
    CHECK(avz_native_fast_memory_write(f->path[path], address, width, value));
    CHECK(avz_native_fast_memory_read(f->path[path], address, width, &v));
}
static AVZNativeCPU cpu(void) {
    AVZNativeCPU c = {.pc = CODE, .pstate = 5, .sp = DATA,
        .exclusive_valid = 1, .exclusive_size = 8,
        .exclusive_address = DATA, .exclusive_generation = 77};
    c.x[10] = DATA; c.x[11] = DATA + 4096;
    for (unsigned i = 0; i < sizeof(c.v); i++) ((unsigned char *)c.v)[i] = (unsigned char)(i * 7);
    return c;
}
static AVZNativeBlockResult run(Fixture *f, AVZNativeCPU *c, uint64_t budget) {
    return ag_run_memory(f->program, budget, c, NULL, f->path[0]);
}
static void entry_controls(void) {
    const uint32_t words[] = {0xf9400140, 0x91000400, 0xf9000140, 0x17fffffd};
    const unsigned budgets[] = {0, 1, 4, 19};
    for (unsigned kind = 0; kind < 14; kind++)
    for (unsigned b = 0; b < sizeof(budgets) / sizeof(budgets[0]); b++) {
        Fixture f[2]; AVZNativeCPU c[2]; AVZNativeBlockResult r[2];
        uint64_t local = 1; _Atomic uint64_t shared = 2;
        AGGuards g = {.local = &local, .shared = {&shared},
            .expected = {kind == 2 ? 0 : 1, kind == 3 ? 0 : 2}};
        for (unsigned mode = 0; mode < 2; mode++) {
            init(&f[mode], words, 4); c[mode] = cpu();
            if (kind != 1) warm(&f[mode], 0, DATA, 8, 17);
            if (kind == 5) c[mode].halted = 1;
            if (kind == 6) c[mode].pc = CODE + 16;
            if (kind >= 7 && kind <= 9) c[mode].x[10] = DEVICE;
            f[mode].fail = kind == 8;
            f[mode].action = kind == 9 ? RETIRE : NONE;
            if (kind == 12) f[mode].program->retired = 1;
            if (kind == 13) f[mode].program->active_runs = UINT32_MAX;
            const AGProgram *p = kind == 10 ? NULL : f[mode].program;
            AVZNativeCPU *state = kind == 11 ? NULL : &c[mode];
            AVZNativeMemoryFastPath *memory = kind == 4 ? NULL : f[mode].path[0];
            r[mode] = mode ? ag_run_memory_control(p, budgets[b], state, &g, memory) :
                ag_run_memory(p, budgets[b], state, &g, memory);
            if (kind == 13) {
                CHECK(f[mode].program->active_runs == UINT32_MAX);
                f[mode].program->active_runs = 0;
            } else if (f[mode].program) CHECK(!f[mode].program->active_runs);
        }
        CHECK(!memcmp(&r[0], &r[1], sizeof(r[0])));
        CHECK(!memcmp(&c[0], &c[1], sizeof(c[0])));
        CHECK(!memcmp(avz_guest_memory_bytes(f[0].ram), avz_guest_memory_bytes(f[1].ram), RAM_SIZE));
        CHECK(f[0].calls == f[1].calls && f[0].faults == f[1].faults);
        finish(&f[0]); finish(&f[1]);
    }
    puts("PASS entry controls: 56 inline/outline state, RAM, lifetime and exit comparisons");
}
static void hot_differential(void) {
    unsigned cases = 0;
    for (unsigned size = 0; size < 4; size++)
    for (unsigned sp = 0; sp < 2; sp++)
    for (unsigned zero = 0; zero < 2; zero++)
    for (unsigned imm = 0; imm < 2; imm++)
    for (unsigned budget = 0; budget < 24; budget++) {
        unsigned base = sp ? 31 : 10, reg = zero ? 31 : 0;
        uint32_t words[] = {0x39400000 | (size << 30) | (base << 5) | reg | (imm << 10),
            0x91000400, 0x39000000 | (size << 30) | (base << 5) | reg | (imm << 10), 0x17fffffd};
        Fixture a, b; init(&a, words, 4); init(&b, words, 4);
        warm(&a, 0, DATA + (imm << size), 1u << size, UINT64_MAX);
        warm(&b, 0, DATA + (imm << size), 1u << size, UINT64_MAX);
        avz_guest_memory_advance_dirty_epoch(a.ram); avz_guest_memory_advance_dirty_epoch(b.ram);
        AVZNativeCPU actual = cpu(), expected = actual;
        AVZNativeInstruction decoded[4];
        for (unsigned i = 0; i < 4; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
        AVZNativeBlockResult got = run(&a, &actual, budget);
        AVZNativeBlockResult want = ag_reference_memory(decoded, 4, CODE, budget, &expected, b.path[0]);
        if (got.steps != budget || got.status != AVZ_NATIVE_STATUS_MAX_STEPS)
            fprintf(stderr, "hot size=%u sp=%u zero=%u imm=%u budget=%u status=%u steps=%" PRIu64 " pc=%" PRIx64 "\n",
                size, sp, zero, imm, budget, got.status, got.steps, actual.pc);
        CHECK(got.steps == budget && got.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(got.steps == want.steps && got.status == want.status);
        CHECK(!memcmp(&actual, &expected, sizeof(actual)));
        CHECK(!memcmp(avz_guest_memory_bytes(a.ram), avz_guest_memory_bytes(b.ram), RAM_SIZE));
        AVZGuestDirtyRange ar[8], br[8];
        size_t ac = avz_guest_memory_dirty_ranges(a.ram, 0, RAM_SIZE, 0, UINT64_MAX, ar, 8);
        size_t bc = avz_guest_memory_dirty_ranges(b.ram, 0, RAM_SIZE, 0, UINT64_MAX, br, 8);
        CHECK(ac == bc && !memcmp(ar, br, ac * sizeof(*ar)));
        CHECK(!a.calls && !a.faults);
        finish(&a); finish(&b); cases++;
    }
    printf("PASS phase4 hot RAM: %u width/SP/XZR/immediate/budget differential cases\n", cases);
}
static uint32_t scalar_word(unsigned size, unsigned opc, unsigned form,
    int delta, unsigned rn, unsigned rt, unsigned rm, unsigned scaled) {
    uint32_t word = (size << 30) | (opc << 22) | (rn << 5) | rt;
    if (form == 0) return word | 0x39000000 | ((unsigned)delta << 10);
    if (form < 4) {
        unsigned mode = form == 1 ? 0 : form == 2 ? 3 : 1;
        return word | 0x38000000 | (((unsigned)delta & 511) << 12) | (mode << 10);
    }
    const unsigned options[] = {2, 3, 6, 7};
    return word | 0x38200800 | (rm << 16) | (options[form - 4] << 13) | (scaled << 12);
}
static uint64_t scalar_offset(unsigned form, uint64_t value, unsigned shift) {
    if (form == 4) value &= UINT32_MAX;
    if (form == 6) value = ((value & UINT32_MAX) ^ UINT64_C(0x80000000)) - UINT64_C(0x80000000);
    return value << shift;
}
static void address_compare(uint32_t word, AVZNativeCPU start, unsigned width,
    uint64_t target, uint64_t initial_value, unsigned slow) {
    uint32_t words[] = {word, 0xd503201f};
    Fixture a, b; init(&a, words, 2); init(&b, words, 2);
    warm(&a, 0, target, width, initial_value); warm(&b, 0, target, width, initial_value);
    avz_guest_memory_advance_dirty_epoch(a.ram); avz_guest_memory_advance_dirty_epoch(b.ram);
    if (slow == 1) {
        avz_native_memory_fast_path_invalidate_translation(a.path[0]);
        avz_native_memory_fast_path_invalidate_translation(b.path[0]);
    } else if (slow == 2) {
        CHECK(avz_guest_memory_register_host_range(a.ram, target, width));
        CHECK(avz_guest_memory_register_host_range(b.ram, target, width));
    }
    AVZNativeCPU actual = start, expected = start;
    AVZNativeInstruction decoded[2];
    for (unsigned i = 0; i < 2; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
    AVZNativeBlockResult got = run(&a, &actual, 2);
    CHECK(got.steps == (slow ? 1u : 2u));
    CHECK(got.status == (slow ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS));
    AVZNativeBlockResult want = ag_reference_memory(decoded, 2, CODE, got.steps, &expected, b.path[0]);
    if (memcmp(&actual, &expected, sizeof(actual))) fprintf(stderr, "address raw=%08x slow=%u\n", word, slow);
    CHECK(want.steps == got.steps && want.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(!memcmp(&actual, &expected, sizeof(actual)));
    CHECK(!memcmp(avz_guest_memory_bytes(a.ram), avz_guest_memory_bytes(b.ram), RAM_SIZE));
    AVZGuestDirtyRange ar[8], br[8];
    size_t ac = avz_guest_memory_dirty_ranges(a.ram, 0, RAM_SIZE, 0, UINT64_MAX, ar, 8);
    size_t bc = avz_guest_memory_dirty_ranges(b.ram, 0, RAM_SIZE, 0, UINT64_MAX, br, 8);
    CHECK(ac == bc && !memcmp(ar, br, ac * sizeof(*ar)));
    CHECK(!a.calls && !a.faults);
    finish(&a); finish(&b);
}
static void scalar_addresses(void) {
    unsigned checked = 0;
    const int deltas[] = {-256, -8, 0, 8, 255};
    const uint64_t offsets[] = {0, 1, UINT32_MAX, UINT64_C(0xffffffff00000002), UINT64_MAX};
    for (unsigned size = 0; size < 4; size++)
    for (unsigned opc = 0; opc < 4; opc++) {
        if ((opc == 2 && size > 2) || (opc == 3 && size > 1)) continue;
        for (unsigned form = 0; form < 8; form++)
        for (unsigned variant = 0; variant < 5; variant++)
        for (unsigned sp = 0; sp < 2; sp++)
        for (unsigned zero = 0; zero < 2; zero++) {
            unsigned rn = sp ? 31 : 10, rt = zero ? 31 : 0;
            unsigned rm = variant == 0 ? 31 : variant == 1 ? rt : 11;
            unsigned scaled = variant & 1;
            int delta = form == 0 ? (variant == 0 ? 4095 : (int)variant) : deltas[variant];
            uint32_t word = scalar_word(size, opc, form, delta, rn, rt, rm, scaled);
            uint64_t offset = form == 0 ? (uint64_t)delta << size :
                form == 3 ? 0 : form < 4 ? (uint64_t)(int64_t)delta :
                scalar_offset(form, rm == 31 ? 0 : offsets[variant], scaled ? size : 0);
            AVZNativeCPU c = cpu(); c.x[0] = UINT64_C(0x89abcdef01234567);
            if (form >= 4 && rm != 31) c.x[rm] = offsets[variant];
            if (sp) c.sp = DATA - offset; else c.x[10] = DATA - offset;
            uint64_t value = variant & 1 ? UINT64_C(0x8080808080808080) : UINT64_C(0x7f7f7f7f7f7f7f7f);
            address_compare(word, c, 1u << size, DATA, value, 0); checked++;
        }
        // Exercise the same semantics across helper, observer and boundary exits.
        for (unsigned form = 0; form < 8; form++)
        for (unsigned slow = 1; slow <= 4; slow++) {
            if (slow >= 3 && size == 0) continue;
            uint64_t target = DATA + (slow == 3 ? 1 : slow == 4 ? 4095 : 0);
            int delta = form == 0 ? 1 : -8;
            uint32_t word = scalar_word(size, opc, form, delta, 10, 0, 11, 1);
            uint64_t offset = form == 0 ? UINT64_C(1) << size : form == 3 ? 0 :
                form < 4 ? (uint64_t)(int64_t)delta : scalar_offset(form, UINT64_MAX, size);
            AVZNativeCPU c = cpu(); c.x[10] = target - offset; c.x[11] = UINT64_MAX; c.x[0] = UINT64_MAX;
            address_compare(word, c, 1u << size, target, UINT64_MAX, slow); checked++;
        }
    }
    printf("PASS phase6 scalar addressing: %u hot/helper/observer/unaligned/cross-page state and RAM comparisons\n", checked);
}
static void scalar_device_exits(void) {
    unsigned checked = 0;
    for (unsigned opc = 0; opc < 4; opc++)
    for (unsigned form = 0; form < 8; form++)
    for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned retire = 0; retire < 2; retire++) {
        unsigned size = opc == 3 ? 1 : opc == 2 ? 2 : 3;
        int delta = form == 0 ? 1 : -8;
        uint32_t words[] = {scalar_word(size, opc, form, delta, 10, 0, 11, 1), 0x91000421};
        Fixture f; init(&f, words, 2);
        AVZNativeCPU c = cpu(); c.x[0] = UINT64_C(0x89abcdef01234567); c.x[11] = UINT64_MAX;
        uint64_t offset = form == 0 ? UINT64_C(1) << size : form == 3 ? 0 :
            form < 4 ? (uint64_t)(int64_t)delta : scalar_offset(form, UINT64_MAX, size);
        c.x[10] = DEVICE - offset;
        AVZNativeCPU expected = c;
        f.device_value = UINT64_C(1) << ((8u << size) - 1);
        f.fail = fail; f.action = retire ? RETIRE : NONE; f.clobber = 1;
        AVZNativeBlockResult r = run(&f, &c, 2);
        CHECK(f.calls == 1 && f.unwound && r.steps == (fail ? 0u : 1u));
        CHECK(r.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        if (!fail) {
            if (opc == 0) {
                CHECK(f.last_value == c.x[0]);
                expected.exclusive_address = expected.exclusive_generation = 0;
                expected.exclusive_size = expected.exclusive_valid = 0;
            } else expected.x[0] = opc == 3 ? UINT64_C(0xffff8000) :
                opc == 2 ? UINT64_C(0xffffffff80000000) : f.device_value;
            if (form == 2 || form == 3) expected.x[10] -= 8;
            expected.pc += 4;
        }
        CHECK(!memcmp(&c, &expected, sizeof(c)));
        CHECK(!retire || !f.program);
        finish(&f); checked++;
    }
    const uint32_t rejected[] = {
        0xf8400800, 0xf8000800, // LDTR/STTR: unprivileged access
        0xf8408400, 0xf8008c00, // writeback overlaps destination/source
        0x3c400000, 0xf8a00800 // vector/unallocated scalar form
    };
    for (unsigned i = 0; i < sizeof(rejected) / sizeof(*rejected); i++) {
        Fixture f; init(&f, &rejected[i], 1);
        AVZNativeCPU c = cpu(), before = c;
        AVZNativeBlockResult r = run(&f, &c, 1);
        CHECK(r.status == AVZ_NATIVE_STATUS_UNSUPPORTED && !r.steps);
        CHECK(r.unsupported_instruction == rejected[i] && !memcmp(&before, &c, sizeof(c)));
        finish(&f);
    }
    printf("PASS phase6 scalar MMIO: %u success/failure/writeback/retirement/unwind cases and reserved-form exits\n", checked);
}
static void scalar_invalidation(void) {
    unsigned checked = 0;
    for (unsigned form = 0; form < 8; form++)
    for (unsigned load = 0; load < 2; load++)
    for (unsigned mode = 0; mode < 4; mode++) {
        if (load && mode == 3) continue;
        int delta = form == 0 ? 1 : -8;
        uint32_t words[] = {scalar_word(3, load, form, delta, 10, 0, 11, 1), 0x91000421};
        Fixture f; init(&f, words, 2);
        uint64_t offset = form == 0 ? 8 : form == 3 ? 0 :
            form < 4 ? (uint64_t)(int64_t)delta : scalar_offset(form, UINT64_MAX, 3);
        AVZNativeCPU c = cpu(); c.x[10] = DATA - offset; c.x[11] = UINT64_MAX; c.x[0] = 99;
        AVZNativeCPU before = c;
        if (mode < 2) {
            AVZNativeStage1TranslationState s = {.sctlr_el1 = 1, .tcr_el1 = 16,
                .ttbr0_el1 = 0x8000, .current_el = 1};
            if (mode == 1) {
                uint64_t *tables = (uint64_t *)(avz_guest_memory_bytes(f.ram) + 0x8000);
                tables[0] = 0x9003; tables[512] = 0xa003; tables[1024] = 0xb003;
                tables[1536 + (DATA >> 12)] = DATA | 0x483;
            }
            avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
            if (mode == 1 && !load) {
                uint64_t value; CHECK(avz_native_fast_memory_read(f.path[0], DATA, 8, &value));
            }
            f.action = RETIRE;
        } else {
            warm(&f, 0, DATA, 8, 0);
            if (mode == 2) avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
            else avz_guest_memory_mark_code_page(f.ram, DATA, 0);
        }
        uint64_t generation = atomic_load(&f.ram->code_mutation_epoch);
        AVZNativeBlockResult r = run(&f, &c, 2);
        if (mode == 0 || (mode == 1 && !load)) {
            CHECK(r.status == AVZ_TP_STATUS_MEMORY_FAULT && !r.steps && f.faults == 1);
            CHECK(!memcmp(&c, &before, sizeof(c)) && !f.program);
        } else if (mode == 2) {
            CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && !r.steps);
            CHECK(!memcmp(&c, &before, sizeof(c)));
        } else {
            CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 1);
            before.pc += 4;
            if (form == 2 || form == 3) before.x[10] -= 8;
            if (load) before.x[0] = 0;
            else {
                before.exclusive_address = before.exclusive_generation = 0;
                before.exclusive_size = before.exclusive_valid = 0;
                CHECK(avz_guest_memory_bytes(f.ram)[DATA] == 99);
                CHECK(atomic_load(&f.ram->code_mutation_epoch) != generation);
            }
            CHECK(!memcmp(&c, &before, sizeof(c)));
        }
        finish(&f); checked++;
    }
    // Model the terminal post-store helper separately: the RAM store has
    // already happened. Accounting must neither repeat it nor lose writeback.
    for (unsigned form = 0; form < 8; form++) {
        int delta = form == 0 ? 1 : -8;
        uint32_t word = scalar_word(3, 0, form, delta, 10, 0, 11, 1);
        Fixture f; init(&f, &word, 1);
        AVZNativeCPU c = cpu(), before;
        uint64_t offset = form == 0 ? 8 : form == 3 ? 0 :
            form < 4 ? (uint64_t)(int64_t)delta : scalar_offset(form, UINT64_MAX, 3);
        c.x[10] = DATA - offset; c.x[11] = UINT64_MAX; c.x[0] = 99; before = c;
        warm(&f, 0, DATA, 8, 42);
        avz_guest_memory_mark_code_page(f.ram, DATA, 0);
        uint64_t generation = atomic_load(&f.ram->code_mutation_epoch);
        AGRun run_state = {.cpu = &c}; ag_memory_prepare(&run_state.memory, f.path[0]);
        ag_memory_commit(&run_state, f.program->operations, DATA);
        before.pc += 4;
        before.exclusive_address = before.exclusive_generation = 0;
        before.exclusive_size = before.exclusive_valid = 0;
        if (form == 2 || form == 3) before.x[10] -= 8;
        CHECK(!memcmp(&c, &before, sizeof(c)) && avz_guest_memory_bytes(f.ram)[DATA] == 42);
        CHECK(atomic_load(&f.ram->code_mutation_epoch) != generation);
        finish(&f); checked++;
    }
    printf("PASS phase6 scalar invalidation: %u permission/TLBI/code-write/terminal-commit cases\n", checked);
}
static uint32_t pair_word(unsigned kind, unsigned load, unsigned mode, int imm,
    unsigned rn, unsigned rt, unsigned rt2) {
    unsigned opc = kind == 0 ? 0 : kind == 1 ? 2 : 1;
    return 0x28000000 | (opc << 30) | (mode << 23) | (load << 22) |
        (((unsigned)imm & 127) << 15) | (rt2 << 10) | (rn << 5) | rt;
}
static void pair_differential(void) {
    unsigned checked = 0;
    const int deltas[] = {-64, -1, 0, 1, 63};
    for (unsigned kind = 0; kind < 3; kind++)
    for (unsigned load = 0; load < 2; load++)
    for (unsigned mode = 0; mode < 4; mode++) {
        if (kind == 2 && (!load || mode == 0)) continue;
        unsigned width = kind == 1 ? 8 : 4;
        for (unsigned variant = 0; variant < 6; variant++)
        for (unsigned delta = 0; delta < 5; delta++)
        for (unsigned slow = 0; slow < 5; slow++) {
            unsigned rn = variant == 1 ? 31 : 10;
            unsigned rt = variant == 2 ? 31 : 0, rt2 = variant == 3 ? 31 : 1;
            // Non-writeback base/destination aliasing and repeated store sources.
            if (variant == 4 && !(mode & 1)) rt2 = rn;
            if (variant == 5 && !load) rt2 = rt;
            int offset = deltas[delta] * (int)width;
            uint64_t target = DATA + (slow == 3 ? 1 : slow == 4 ? 4096 - width : 0);
            uint32_t words[] = {pair_word(kind, load, mode, deltas[delta], rn, rt, rt2), 0xd503201f};
            Fixture a, b; init(&a, words, 2); init(&b, words, 2);
            warm(&a, 0, target, width, UINT64_C(0x8000000180000001));
            warm(&b, 0, target, width, UINT64_C(0x8000000180000001));
            warm(&a, 0, target + width, width, UINT64_C(0x7ffffffe7ffffffe));
            warm(&b, 0, target + width, width, UINT64_C(0x7ffffffe7ffffffe));
            if (slow == 1) {
                avz_native_memory_fast_path_invalidate_translation(a.path[0]);
                avz_native_memory_fast_path_invalidate_translation(b.path[0]);
            } else if (slow == 2) {
                CHECK(avz_guest_memory_register_host_range(a.ram, target + width, width));
                CHECK(avz_guest_memory_register_host_range(b.ram, target + width, width));
            }
            AVZNativeCPU c = cpu(); c.x[0] = UINT64_MAX; c.x[1] = 0x76543210;
            uint64_t base = target - (mode == 1 ? 0 : (uint64_t)(int64_t)offset);
            if (rn == 31) c.sp = base; else c.x[rn] = base;
            AVZNativeCPU expected = c;
            avz_guest_memory_advance_dirty_epoch(a.ram); avz_guest_memory_advance_dirty_epoch(b.ram);
            AVZNativeBlockResult got = run(&a, &c, 2);
            CHECK(got.steps == (slow ? 1u : 2u));
            CHECK(got.status == (slow ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS));
            AVZNativeInstruction decoded[2];
            for (unsigned i = 0; i < 2; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
            AVZNativeBlockResult want = ag_reference_pair(decoded, 2, CODE, got.steps, &expected, b.path[0]);
            if (memcmp(&c, &expected, sizeof(c))) fprintf(stderr, "pair raw=%08x slow=%u\n", words[0], slow);
            CHECK(want.steps == got.steps && want.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            CHECK(!memcmp(&c, &expected, sizeof(c)));
            CHECK(!memcmp(avz_guest_memory_bytes(a.ram), avz_guest_memory_bytes(b.ram), RAM_SIZE));
            AVZGuestDirtyRange ar[8], br[8];
            size_t ac = avz_guest_memory_dirty_ranges(a.ram, 0, RAM_SIZE, 0, UINT64_MAX, ar, 8);
            size_t bc = avz_guest_memory_dirty_ranges(b.ram, 0, RAM_SIZE, 0, UINT64_MAX, br, 8);
            CHECK(ac == bc && !memcmp(ar, br, ac * sizeof(*ar)));
            finish(&a); finish(&b); checked++;
        }
    }
    printf("PASS phase6 pairs: %u width/sign/address/alias/observer/cross-page CPU/RAM/dirty comparisons\n", checked);
}
static void pair_callbacks(void) {
    unsigned checked = 0;
    for (unsigned kind = 0; kind < 3; kind++)
    for (unsigned load = 0; load < 2; load++)
    for (unsigned mode = 0; mode < 4; mode++) {
        if (kind == 2 && (!load || mode == 0)) continue;
        unsigned width = kind == 1 ? 8 : 4;
        for (unsigned failure = 0; failure < 4; failure++)
        for (unsigned retire = 0; retire < 2; retire++) {
            uint32_t words[] = {pair_word(kind, load, mode, -1, 10, 0, 1), 0x91000442};
            Fixture f; init(&f, words, 2);
            AVZNativeCPU c = cpu(); c.x[10] = DEVICE + (mode == 1 ? 0 : width);
            c.x[0] = UINT64_C(0x8000000180000001); c.x[1] = 0x7ffffffe;
            AVZNativeCPU expected = c;
            f.device_value = kind == 1 ? c.x[0] : 0x80000001;
            f.fail_call = failure < 3 ? failure : 0;
            f.deny_address = failure == 3 ? DEVICE + width : 0;
            f.action = retire ? RETIRE : NONE; f.clobber = 1;
            AVZNativeBlockResult got = run(&f, &c, 2);
            CHECK(got.steps == (failure ? 0u : 1u));
            CHECK(got.status == (failure ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
            CHECK(f.calls == (failure == 3 ? 0u : failure == 1 ? 1u : 2u));
            CHECK(f.preflights == 2);
            if (failure != 3) CHECK(f.unwound && (!retire || !f.program));
            if (!failure) {
                expected.pc += 4;
                if (mode & 1) expected.x[10] -= width;
                if (load) {
                    expected.x[0] = kind == 2 ? UINT64_C(0xffffffff80000001) : f.device_value;
                    expected.x[1] = 0x7ffffffe;
                } else {
                    expected.exclusive_address = expected.exclusive_generation = 0;
                    expected.exclusive_valid = expected.exclusive_size = 0;
                }
            }
            CHECK(!memcmp(&c, &expected, sizeof(c)));
            CHECK(f.writes == (load || failure == 1 || failure == 3 ? 0u : failure == 2 ? 1u : 2u));
            if (f.writes) CHECK(f.device_writes[0] ==
                (kind == 1 ? UINT64_C(0x8000000180000001) : UINT64_C(0x80000001)));
            if (f.writes == 2) CHECK(f.device_writes[1] == 0x7ffffffe);
            finish(&f); checked++;
        }
    }
    // Fail closed rather than selecting an arbitrary constrained-unpredictable result.
    const uint32_t excluded[] = {
        0xa9400000, // LDP with identical destinations
        0xa9c00400, // pre-index load writeback overlaps Rt
        0xa8810400, // post-index store writeback overlaps Rt
        0xad400400, // SIMD pair
        0x68400400  // unallocated LDPSW non-temporal encoding
    };
    for (unsigned i = 0; i < sizeof(excluded) / sizeof(*excluded); i++) {
        Fixture f; init(&f, &excluded[i], 1);
        AVZNativeCPU c = cpu(), before = c;
        AVZNativeBlockResult r = run(&f, &c, 1);
        CHECK(!r.steps && r.status == AVZ_NATIVE_STATUS_UNSUPPORTED && !memcmp(&c, &before, sizeof(c)));
        finish(&f);
    }
    printf("PASS phase6 pair callbacks: %u preflight/partial-store/fault/writeback/retirement cases; excluded encodings\n", checked);
}
static void pair_boundaries(void) {
    unsigned checked = 0;
    for (unsigned width = 4; width <= 8; width *= 2)
    for (unsigned load = 0; load < 2; load++)
    for (unsigned mode = 1; mode < 4; mode++) {
        uint32_t words[] = {pair_word(width == 8, load, mode, -1, 10, 0, 1), 0x91000442};
        for (unsigned fault_kind = 0; fault_kind < 2; fault_kind++) {
            if (load && fault_kind) continue;
            Fixture f; init(&f, words, 2);
            uint64_t target = DATA + 4096 - width;
            warm(&f, 0, target, width, 42); warm(&f, 0, target + width, width, 43);
            uint64_t *tables = (uint64_t *)(avz_guest_memory_bytes(f.ram) + 0x8000);
            tables[0] = 0x9003; tables[512] = 0xa003; tables[1024] = 0xb003;
            tables[1536 + (DATA >> 12)] = DATA | 0x403;
            tables[1536 + (DATA >> 12) + 1] = fault_kind ? (DATA + 4096) | 0x483 : 0;
            AVZNativeStage1TranslationState s = {.sctlr_el1 = 1, .tcr_el1 = 16,
                .ttbr0_el1 = 0x8000, .current_el = 1};
            avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
            if (fault_kind) {
                uint64_t value;
                CHECK(avz_native_fast_memory_read(f.path[0], target + width, width, &value));
            }
            AVZNativeCPU c = cpu(); c.x[10] = target + (mode == 1 ? 0 : width);
            c.x[0] = 99; c.x[1] = 100; AVZNativeCPU before = c;
            f.action = RETIRE;
            AVZNativeBlockResult r = run(&f, &c, 2);
            CHECK(!r.steps && r.status == AVZ_TP_STATUS_MEMORY_FAULT);
            if (memcmp(&c, &before, sizeof(c)) || f.faults != 1 || f.program)
                fprintf(stderr, "pair boundary width=%u load=%u mode=%u fault=%u callbacks=%u cpu_changed=%d retired=%d\n",
                    width, load, mode, fault_kind, f.faults, memcmp(&c, &before, sizeof(c)) != 0, !f.program);
            CHECK(!memcmp(&c, &before, sizeof(c)) && f.faults == 1 && !f.program);
            uint64_t first = 0, second = 0;
            memcpy(&first, avz_guest_memory_bytes(f.ram) + target, width);
            memcpy(&second, avz_guest_memory_bytes(f.ram) + target + width, width);
            CHECK(first == 42 && second == 43); // No first write before second-page permission check.
            finish(&f); checked++;
        }
        for (unsigned pending = 0; pending < 2; pending++) {
            Fixture f; init(&f, words, 2);
            warm(&f, 0, DATA, width, 42); warm(&f, 0, DATA + width, width, 43);
            AVZNativeCPU c = cpu(); c.x[10] += mode == 1 ? 0 : width;
            c.x[0] = 99; c.x[1] = 100; AVZNativeCPU before = c;
            if (pending) avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
            else avz_guest_memory_mark_code_page(f.ram, DATA, 0);
            uint64_t epoch = atomic_load(&f.ram->code_mutation_epoch);
            AVZNativeBlockResult r = run(&f, &c, 2);
            if (pending) {
                CHECK(!r.steps && r.status == AVZ_TP_STATUS_REVALIDATE && !memcmp(&c, &before, sizeof(c)));
            } else if (!load) {
                CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && c.pc == CODE + 4);
                CHECK(atomic_load(&f.ram->code_mutation_epoch) != epoch && !c.x[2]);
                CHECK(avz_guest_memory_bytes(f.ram)[DATA] == 99 && avz_guest_memory_bytes(f.ram)[DATA + width] == 100);
                CHECK(c.x[10] == before.x[10] - ((mode & 1) ? width : 0));
            } else CHECK(r.steps == 2 && c.x[0] == 42 && c.x[1] == 43);
            finish(&f); checked++;
        }
        if (!load) {
            Fixture f; init(&f, words, 2);
            warm(&f, 0, DATA, width, 42); warm(&f, 0, DATA + width, width, 43);
            avz_guest_memory_mark_code_page(f.ram, DATA, 0);
            AVZNativeCPU c = cpu(); c.x[10] += mode == 1 ? 0 : width;
            c.x[0] = 99; c.x[1] = 100; AVZNativeCPU before = c;
            AGRun state = {.cpu = &c}; ag_memory_prepare(&state.memory, f.path[0]);
            uint64_t epoch = atomic_load(&f.ram->code_mutation_epoch);
            ag_memory_commit(&state, f.program->operations, DATA);
            CHECK(c.pc == CODE + 4 && c.x[10] == before.x[10] - ((mode & 1) ? width : 0));
            CHECK(!c.exclusive_valid && atomic_load(&f.ram->code_mutation_epoch) != epoch);
            CHECK(avz_guest_memory_bytes(f.ram)[DATA] == 42 && avz_guest_memory_bytes(f.ram)[DATA + width] == 43);
            finish(&f); checked++;
        }
    }
    printf("PASS phase6 pair boundaries: %u second-page permission/fault/TLBI/code-commit cases\n", checked);
}
static void callbacks(void) {
    unsigned cases = 0;
    for (unsigned store = 0; store < 2; store++)
    for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned physical = 0; physical < 2; physical++)
    for (unsigned act = NONE; act <= REMAP; act++)
    for (unsigned budget = 1; budget <= 3; budget++) {
        uint32_t words[] = {store ? 0xf9000140 : 0xf9400140, 0x91000421, 0x17fffffe};
        Fixture f; init(&f, words, 3);
        if (physical) {
            AVZNativeStage1TranslationState s = {.current_el = 1};
            avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
            avz_native_memory_fast_path_set_physical_memory_callbacks(f.path[0], read_memory, write_memory);
        }
        AVZNativeCPU c = cpu(); c.x[10] = DEVICE; c.x[0] = 0x123456789;
        AVZNativeCPU before = c;
        f.fail = fail; f.action = act; f.clobber = 1;
        AVZNativeBlockResult r = run(&f, &c, budget);
        CHECK(f.calls == 1 && !c.x[1] && f.unwound);
        CHECK(r.steps == (fail ? 0 : 1));
        CHECK(r.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(!fail || !memcmp(&c, &before, sizeof(c)));
        if (!fail) CHECK(c.pc == CODE + 4);
        if (store) CHECK(f.last_value == before.x[0]);
        finish(&f); cases++;
    }
    uint32_t words[] = {0xf9400140, 0x91000421};
    Fixture f; init(&f, words, 2);
    f.action = TRANSLATE_RETIRE;
    AVZNativeCPU c = cpu();
    AVZNativeBlockResult r = run(&f, &c, 2);
    CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1] && !f.program);
    finish(&f);
    for (unsigned fail = 0; fail < 2; fail++) {
        init(&f, words, 2); c = cpu(); c.x[10] = DEVICE;
        f.clobber = 1; f.fail = fail;
        AGRun control = {.cpu = &c, .operation = f.program->operations, .budget = 2};
        ag_memory_prepare(&control.memory, f.path[0]);
        CHECK(ag_abi_probe(&control) == 0);
        CHECK(control.result.steps == (fail ? 0 : 1) && f.unwound);
        finish(&f);
    }
    printf("PASS phase4 callbacks: %u MMIO/retirement/failure cases; ABI clobber, unwind and translation retirement\n", cases);
}
static void hot_proof_failures(void) {
    for (unsigned store = 0; store < 2; store++)
    for (unsigned mode = 0; mode < 12; mode++) {
        uint32_t words[] = {store ? 0xf9000140 : 0xf9400140, 0x91000421};
        Fixture f; init(&f, words, 2); warm(&f, 0, DATA, 8, 73);
        AVZNativeMemoryFastPath *p = f.path[0];
        AVZNativeFastTLBEntry *e = store ? &p->write_hot[DATA >> 12] : &p->read_hot[DATA >> 12];
        switch (mode) {
        case 0: e->valid = 0; break;
        case 1: e->generation++; break;
        case 2: e->virtual_page++; break;
        case 3: e->context_tag++; break;
        case 4: e->contiguous_span = 7; break;
        case 5: e->host_page = NULL; break;
        case 6: e->physical_page = UINT64_MAX; break;
        case 7: e->physical_page = RAM_SIZE - 4; break;
        case 8: e->host_page++; break;
        case 9: p->detailed_statistics_enabled = 1; break;
        case 10: CHECK(avz_guest_memory_register_host_range(f.ram, DATA, 8)); break;
        case 11: avz_native_memory_fast_path_invalidate_translation(p); break;
        }
        AVZNativeCPU c = cpu(); c.x[0] = 73;
        AVZNativeBlockResult r = run(&f, &c, 2);
        CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
        if (mode != 6 && mode != 7 && mode != 8) CHECK(c.x[0] == 73);
        finish(&f);
    }
    puts("PASS phase4 hot proof rejection: 24 invalid tag/context/generation/span/pointer/statistics/observer cases");
}
static void observations(void) {
    for (unsigned store = 0; store < 2; store++)
    for (unsigned size = 0; size < 4; size++)
    for (unsigned mode = 0; mode < 6; mode++) {
        unsigned width = 1u << size;
        uint32_t words[] = {(store ? 0x39000140 : 0x39400140) | (size << 30), 0x91000421};
        Fixture f; init(&f, words, 2);
        uint64_t address = DATA + (mode == 2 ? 1 : mode == 3 ? 4095 : 0);
        warm(&f, 0, address, width, 7);
        uint64_t value, generation = 0;
        if (mode == 0) CHECK(avz_guest_memory_exclusive_read(f.ram, DATA, 8, &value, &generation));
        if (mode == 1) CHECK(avz_guest_memory_register_host_range(f.ram, DATA, 8));
        if (mode == 4) atomic_store(&f.ram->page_observation_flags[DATA >> 12], AVZ_GUEST_PAGE_OBSERVATION_BULK_READER);
        if (mode == 5) avz_guest_memory_mark_code_page(f.ram, DATA, 0);
        AVZNativeCPU c = cpu(); c.x[10] = address; c.x[0] = 7;
        AVZNativeBlockResult r = run(&f, &c, 2);
        int slow = mode == 1 || ((mode == 2 || mode == 3) && width > 1) ||
            (store && (mode == 0 || mode == 4 || mode == 5));
        CHECK(r.steps == (slow ? 1 : 2));
        CHECK(r.status == (slow ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS));
        if (store) {
            CHECK(!c.exclusive_valid && !c.exclusive_generation);
            if (mode == 0) CHECK(!avz_guest_memory_exclusive_write(f.ram, DATA, 8, 9, generation));
        }
        finish(&f);
    }
    puts("PASS phase4 observers: 48 width/load/store/exclusive/host/bulk/code/unaligned/cross-page cases");
}
static void mapping_and_faults(void) {
    uint32_t words[] = {0xf9400140, 0xf9400161, 0x91000442};
    Fixture f; init(&f, words, 3);
    warm(&f, 0, DATA, 8, 11); warm(&f, 0, DATA + 4096, 8, 22);
    AVZNativeCPU c = cpu(); c.x[10] = DEVICE; c.x[11] = DATA;
    f.action = REMAP;
    AVZNativeBlockResult r = run(&f, &c, 3);
    CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
    r = run(&f, &c, 2);
    CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && c.x[1] == 22 && !c.x[2]);
    c.pc = CODE + 4; c.x[1] = 0;
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
    r = run(&f, &c, 2);
    CHECK(!r.steps && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
    avz_native_memory_fast_path_synchronize_translations(f.path[0]);
    r = run(&f, &c, 2);
    CHECK(r.steps == 1 && c.x[1] == 22);
    finish(&f);
    for (unsigned store = 0; store < 2; store++)
    for (unsigned read_only = 0; read_only < 2; read_only++) {
        words[0] = store ? 0xf9000140 : 0xf9400140;
        init(&f, words, 3);
        AVZNativeStage1TranslationState s = {.sctlr_el1 = 1, .tcr_el1 = 16,
            .ttbr0_el1 = 0x8000, .current_el = 1};
        if (read_only) {
            // 4K, 48-bit VA, four levels; EL1 read-only AF=1 leaf.
            uint64_t *tables = (uint64_t *)(avz_guest_memory_bytes(f.ram) + 0x8000);
            tables[0] = 0x9003; tables[512] = 0xa003; tables[1024] = 0xb003;
            tables[1536 + (DATA >> 12)] = DATA | 0x483;
        }
        avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
        if (read_only && store) {
            uint64_t v;
            CHECK(avz_native_fast_memory_read(f.path[0], DATA, 8, &v));
        }
        c = cpu(); c.x[0] = 91; AVZNativeCPU before = c;
        f.action = RETIRE;
        r = run(&f, &c, 3);
        if (read_only && !store) {
            CHECK(r.steps == 1 && r.status == AVZ_TP_STATUS_REVALIDATE && !f.faults);
        } else {
            CHECK(!r.steps && r.status == AVZ_TP_STATUS_MEMORY_FAULT && f.faults == 1);
            CHECK(!memcmp(&c, &before, sizeof(c)) && !f.program);
            CHECK(avz_guest_memory_bytes(f.ram)[DATA] == 0);
        }
        finish(&f);
    }
    puts("PASS phase4 remap/pending TLBI; invalid mappings and read-only store faults (including warmed read TLB)");
}

static void translation_contexts(void) {
    for (unsigned high = 0; high < 2; high++)
    for (unsigned el = 0; el < 2; el++)
    for (unsigned store = 0; store < 2; store++) {
        uint32_t words[] = {store ? 0xf9000140 : 0xf9400140, 0x91000421};
        Fixture f; init(&f, words, 2);
        uint64_t *tables = (uint64_t *)(avz_guest_memory_bytes(f.ram) + 0x8000);
        tables[0] = 0x9003; tables[512] = 0xa003; tables[1024] = 0xb003;
        tables[1536 + (DATA >> 12)] = DATA | 0x443;
        uint64_t address = (high ? UINT64_C(0xffff000000000000) : 0) | DATA;
        AVZNativeStage1TranslationState s = {.sctlr_el1 = 1,
            .tcr_el1 = UINT64_C(16) | (UINT64_C(16) << 16) | (UINT64_C(2) << 30),
            .ttbr0_el1 = 0x8000, .ttbr1_el1 = 0x8000, .current_el = el};
        for (unsigned asid = 1; asid <= 2; asid++) {
            // Same VA, different physical page and ASID on the second run.
            uint64_t physical = DATA + (asid - 1) * 4096;
            tables[1536 + (DATA >> 12)] = physical | 0xc43; // non-global, EL0/EL1 RW
            s.ttbr0_el1 = ((uint64_t)asid << 48) | 0x8000;
            avz_native_memory_fast_path_set_stage1_translation(f.path[0], &s, fault);
            uint64_t value = 70 + asid;
            memcpy(avz_guest_memory_bytes(f.ram) + physical, &value, 8);
            if (store) CHECK(avz_native_fast_memory_write(f.path[0], address, 8, value));
            else CHECK(avz_native_fast_memory_read(f.path[0], address, 8, &value));
            AVZNativeCPU c = cpu(); c.x[10] = address; c.x[0] = store ? value + 1 : 0;
            AVZNativeBlockResult r = run(&f, &c, 2);
            CHECK(r.steps == 2 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS && !f.faults);
            CHECK(c.x[0] == value + store && c.x[1] == 1);
            if (store) CHECK(avz_guest_memory_bytes(f.ram)[physical] == value + 1);
        }
        // Revoke EL0 access to a previously hot mapping, then change context.
        if (!el) {
            tables[1536 + (DATA >> 12)] = DATA | 0xc03;
            avz_native_memory_fast_path_invalidate_translation(f.path[0]);
            AVZNativeCPU c = cpu(); c.x[10] = address; AVZNativeCPU before = c;
            AVZNativeBlockResult r = run(&f, &c, 2);
            CHECK(!r.steps && r.status == AVZ_TP_STATUS_MEMORY_FAULT && f.faults == 1);
            CHECK(!memcmp(&c, &before, sizeof(c)));
        }
        finish(&f);
    }
    puts("PASS phase4 low/high VA, ASID replacement, EL0/EL1 RAM hits and permission revocation");
}

static void code_and_entry(void) {
    const uint32_t words[] = {0xb9000140, 0x91000421};
    for (unsigned peer = 0; peer < 2; peer++) {
        Fixture f; init(&f, words, 2);
        warm(&f, 0, CODE + 4, 4, words[1]);
        AGGuards g = {.shared = {&f.ram->code_mutation_epoch},
            .expected = {0, atomic_load(&f.ram->code_mutation_epoch)}};
        AVZNativeCPU c = cpu(); c.x[10] = CODE + 4; c.x[0] = 0x91000821;
        if (peer) CHECK(avz_native_fast_memory_write(f.path[1], CODE + 4, 4, c.x[0]));
        AVZNativeBlockResult r = ag_run_memory(f.program, 2, &c, &g, f.path[0]);
        CHECK(r.steps == (peer ? 0 : 1) && r.status == AVZ_TP_STATUS_REVALIDATE && !c.x[1]);
        CHECK(*(uint32_t *)(avz_guest_memory_bytes(f.ram) + CODE + 4) == 0x91000821);
        finish(&f);
    }
    Fixture f; init(&f, words, 2);
    AVZNativeCPU c = cpu();
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL});
    CHECK(run(&f, &c, 0).status == AVZ_NATIVE_STATUS_MAX_STEPS);
    c.halted = 1;
    CHECK(run(&f, &c, 1).status == AVZ_NATIVE_STATUS_HALTED);
    c.halted = 0;
    CHECK(run(&f, &c, 1).status == AVZ_TP_STATUS_REVALIDATE);
    finish(&f);
    puts("PASS phase4 self-modifying store, stale code at entry and zero/halt/TLBI precedence");
}

typedef struct { Fixture *f; AVZNativeCPU cpu; AVZNativeBlockResult result; _Atomic int done; AGChain *chain; } Worker;
static void *worker(void *opaque) {
    Worker *w = opaque;
    w->result = w->chain ? ag_chain_run(w->chain,
        (AGLimits){UINT64_C(1000000000), UINT64_C(1000000000), UINT64_MAX, NULL}, &w->cpu, w->f->path[0]) :
        run(w->f, &w->cpu, UINT64_C(1000000000));
    atomic_store(&w->done, 1);
    return NULL;
}
static void concurrent(void) {
    for (unsigned tail = 0; tail < 2; tail++)
    for (unsigned kind = 0; kind < 5; kind++) {
        uint32_t words[] = {0xf9400140, 0xf9000160, 0x17fffffe};
        if (tail) { words[0] = 0xf9000160; words[1] = 0x91000400; words[2] = 0x17ffffff; }
        Fixture f; init(&f, words, 3);
        warm(&f, 0, DATA, 8, 1); warm(&f, 0, DATA + 4096, 8, 0);
        Worker w = {.f = &f, .cpu = cpu()}; w.cpu.x[0] = 1;
        pthread_t thread; CHECK(!pthread_create(&thread, NULL, worker, &w));
        uint64_t *signal = (uint64_t *)(avz_guest_memory_bytes(f.ram) + DATA + 4096);
        while (!__atomic_load_n(signal, __ATOMIC_ACQUIRE) && !atomic_load(&w.done)) sched_yield();
        CHECK(!atomic_load(&w.done));
        if (!kind) CHECK(avz_native_fast_memory_write(f.path[1], CODE, 4, 0xd503201f));
        else {
            AVZNativeTLBI tlbi = {.kind = kind - 1, .broadcast = 1, .virtual_address = DATA};
            avz_native_memory_fast_path_apply_tlbi(f.path[1], tlbi);
            avz_guest_memory_publish_tlbi(f.ram, tlbi);
        }
        CHECK(!pthread_join(thread, NULL));
        CHECK(w.result.status == AVZ_TP_STATUS_REVALIDATE && w.result.steps < UINT64_C(1000000000));
        CHECK(w.result.steps >= (tail ? 1u : 2u));
        finish(&f);
    }
    puts("PASS phase4 two-vCPU code publication and all TLBI scopes, including register-only tails");
    const uint32_t words[] = {0xf9400140, 0xf9000160, 0x17fffffe};
    Fixture f; init(&f, words, 3);
    const uint64_t a = UINT64_C(0x55aa55aa55aa55aa), b = ~a;
    warm(&f, 0, DATA, 8, a); warm(&f, 0, DATA + 4096, 8, 0);
    Worker w = {.f = &f, .cpu = cpu()};
    pthread_t thread; CHECK(!pthread_create(&thread, NULL, worker, &w));
    uint64_t *signal = (uint64_t *)(avz_guest_memory_bytes(f.ram) + DATA + 4096);
    while (!__atomic_load_n(signal, __ATOMIC_ACQUIRE) && !atomic_load(&w.done)) sched_yield();
    CHECK(!atomic_load(&w.done));
    for (unsigned i = 0; i < 100000; i++) {
        CHECK(avz_native_fast_memory_write(f.path[1], DATA, 8, i & 1 ? a : b));
        uint64_t value = __atomic_load_n(signal, __ATOMIC_RELAXED);
        CHECK(value == a || value == b);
    }
    avz_guest_memory_publish_tlbi(f.ram, (AVZNativeTLBI){.kind = AVZ_TLBI_ALL, .broadcast = 1});
    CHECK(!pthread_join(thread, NULL));
    CHECK(w.result.status == AVZ_TP_STATUS_REVALIDATE);
    finish(&f);
    puts("PASS phase4 100,000 concurrent aligned RAM publications without torn values");
}
static AGChain *memory_chain(Fixture *f, const uint32_t *words, size_t count, size_t split, AGChainStats *stats) {
    const _Atomic uint64_t *generation = &f->ram->page_write_generations[CODE >> 12];
    uint64_t expected = atomic_load(generation);
    AGBlock blocks[] = {{words, split, CODE, generation, expected},
        {words + split, count - split, CODE + split * 4, generation, expected}};
    AGGuards proof = {.shared = {&f->ram->code_mutation_epoch, &f->ram->translation_epoch},
        .expected = {0, atomic_load(&f->ram->code_mutation_epoch), atomic_load(&f->ram->translation_epoch)}};
    AGChain *chain = ag_chain_create(blocks, 2, &proof, stats); CHECK(chain); return chain;
}
static void chained_memory(void) {
    const uint32_t words[] = {0xf9400140, 0x91000400, 0xf9000160, 0x14000001,
        0x91000421, 0x91000442, 0xd503201f, 0x17fffff9};
    for (unsigned budget = 1; budget <= 257; budget++) {
        Fixture f, reference; init(&f, words, 8); init(&reference, words, 8);
        warm(&f, 0, DATA, 8, 17); warm(&f, 0, DATA + 4096, 8, 0);
        warm(&reference, 0, DATA, 8, 17); warm(&reference, 0, DATA + 4096, 8, 0);
        AGChain *chain = memory_chain(&f, words, 8, 4, NULL);
        AVZNativeCPU c = cpu(), expected = c;
        AVZNativeInstruction d[8];
        for (unsigned i = 0; i < 8; i++) CHECK(avz_native_decode_instruction(words[i], &d[i]));
        AVZNativeBlockResult r = ag_chain_run(chain, (AGLimits){budget, budget + 1, UINT64_MAX, NULL}, &c, f.path[0]);
        AVZNativeBlockResult e = ag_reference_memory(d, 8, CODE, budget, &expected, reference.path[0]);
        CHECK(r.steps == budget && r.status == AVZ_NATIVE_STATUS_MAX_STEPS && r.steps == e.steps);
        CHECK(!memcmp(&c, &expected, sizeof(c)));
        CHECK(!memcmp(avz_guest_memory_bytes(f.ram), avz_guest_memory_bytes(reference.ram), RAM_SIZE));
        ag_chain_destroy(chain); finish(&f); finish(&reference);
    }
    // Self-modification terminates before the next linked block; a stale chain cannot re-enter.
    Fixture f; init(&f, words, 8); warm(&f, 0, DATA, 8, 0);
    AGChain *chain = memory_chain(&f, words, 8, 4, NULL);
    AVZNativeCPU c = cpu(); c.x[11] = CODE + 16;
    AVZNativeBlockResult r = ag_chain_run(chain, (AGLimits){64, 64, 16, NULL}, &c, f.path[0]);
    CHECK(r.status == AVZ_TP_STATUS_REVALIDATE && r.steps == 3 && c.pc == CODE + 12 && !c.x[1]);
    CHECK(ag_chain_run(chain, (AGLimits){64, 64, 16, NULL}, &c, f.path[0]).steps == 0);
    ag_chain_destroy(chain); finish(&f);
    for (unsigned kind = 0; kind < 5; kind++) {
        const uint32_t tail[] = {0xf9000160, 0x91000400, 0x17ffffff};
        init(&f, tail, 3); warm(&f, 0, DATA + 4096, 8, 0);
        AGChainStats stats = {0}; chain = memory_chain(&f, tail, 3, 1, &stats);
        Worker w = {.f = &f, .cpu = cpu(), .chain = chain}; w.cpu.x[0] = 1;
        pthread_t thread; CHECK(!pthread_create(&thread, NULL, worker, &w));
        uint64_t *signal = (uint64_t *)(avz_guest_memory_bytes(f.ram) + DATA + 4096);
        while (!__atomic_load_n(signal, __ATOMIC_ACQUIRE) && !atomic_load(&w.done)) sched_yield();
        CHECK(!atomic_load(&w.done));
        if (!kind) CHECK(avz_native_fast_memory_write(f.path[1], CODE, 4, 0xd503201f));
        else {
            AVZNativeTLBI tlbi = {.kind = kind - 1, .broadcast = 1, .virtual_address = DATA};
            avz_native_memory_fast_path_apply_tlbi(f.path[1], tlbi);
            avz_guest_memory_publish_tlbi(f.ram, tlbi);
        }
        CHECK(!pthread_join(thread, NULL));
        CHECK(w.result.status == AVZ_TP_STATUS_REVALIDATE && w.result.steps < UINT64_C(1000000000));
        // Owner transfers back only after join; peer publication never frees the live chain.
        ag_chain_destroy(chain); CHECK(stats.reclamations == 1); finish(&f);
    }
    puts("PASS phase5 native-memory chain: 257 RAM differential budgets, self-modification, peer code write and all TLBI scopes");
}
static void chained_addresses(void) {
    const uint32_t words[] = {0xf8408540, 0x91000400, 0xf81f8d40, 0x14000001,
        0x38ab6942, 0x91000421, 0xd503201f, 0x17fffff9};
    for (unsigned budget = 1; budget <= 129; budget++) {
        Fixture f, reference; init(&f, words, 8); init(&reference, words, 8);
        warm(&f, 0, DATA, 8, 17); warm(&reference, 0, DATA, 8, 17);
        AGChainStats stats = {0}; AGChain *chain = memory_chain(&f, words, 8, 4, &stats);
        AVZNativeCPU c = cpu(); c.x[11] = 0; AVZNativeCPU expected = c;
        uint64_t service = budget / 2 + 1;
        AVZNativeBlockResult r = ag_chain_run(chain,
            (AGLimits){budget, service, UINT64_MAX, NULL}, &c, f.path[0]);
        AVZNativeInstruction decoded[8];
        for (unsigned i = 0; i < 8; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
        CHECK(r.steps == service && r.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(ag_reference_memory(decoded, 8, CODE, service, &expected, reference.path[0]).steps == service);
        CHECK(!memcmp(&c, &expected, sizeof(c)));
        CHECK(!memcmp(avz_guest_memory_bytes(f.ram), avz_guest_memory_bytes(reference.ram), RAM_SIZE));
        ag_chain_destroy(chain); finish(&f); finish(&reference);
    }
    puts("PASS phase6 scalar chain: 129 pre/post/register-offset service-boundary comparisons");
}
static void chained_pairs(void) {
    const uint32_t words[] = {
        0xa8c10540, 0x91000400, 0xa9bf0540, 0x14000001, // LDP post16; increment; STP pre-16
        0x69400542, 0x91000484, 0xd503201f, 0x17fffff9}; // LDPSW x2,x1
    for (unsigned budget = 1; budget <= 129; budget++) {
        Fixture f, reference; init(&f, words, 8); init(&reference, words, 8);
        warm(&f, 0, DATA, 8, 17); warm(&reference, 0, DATA, 8, 17);
        warm(&f, 0, DATA + 8, 8, 31); warm(&reference, 0, DATA + 8, 8, 31);
        AGChain *chain = memory_chain(&f, words, 8, 4, NULL);
        AVZNativeCPU c = cpu(), expected = c;
        uint64_t service = budget / 2 + 1;
        AVZNativeBlockResult r = ag_chain_run(chain,
            (AGLimits){budget, service, UINT64_MAX, NULL}, &c, f.path[0]);
        AVZNativeInstruction decoded[8];
        for (unsigned i = 0; i < 8; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
        CHECK(r.steps == service && r.status == AVZ_NATIVE_STATUS_YIELDED);
        CHECK(ag_reference_pair(decoded, 8, CODE, service, &expected, reference.path[0]).steps == service);
        CHECK(!memcmp(&c, &expected, sizeof(c)));
        CHECK(!memcmp(avz_guest_memory_bytes(f.ram), avz_guest_memory_bytes(reference.ram), RAM_SIZE));
        ag_chain_destroy(chain); finish(&f); finish(&reference);
    }
    puts("PASS phase6 pair chains: 129 exact-service-budget CPU/RAM comparisons");
}
void ag_memory_tests(void) {
    entry_controls();
    hot_differential(); callbacks(); hot_proof_failures(); observations(); mapping_and_faults();
    translation_contexts(); code_and_entry(); concurrent(); chained_memory();
    scalar_addresses(); scalar_device_exits(); scalar_invalidation(); chained_addresses();
    pair_differential(); pair_callbacks(); pair_boundaries(); chained_pairs();
}

static uint64_t nanoseconds(clockid_t clock) {
    struct timespec t; CHECK(!clock_gettime(clock, &t));
    return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}
typedef AVZNativeBlockResult (*EntryRunner)(const AGProgram *, uint64_t,
    AVZNativeCPU *, const AGGuards *, AVZNativeMemoryFastPath *);
/* Both variants use this one indirect call site, selected before timing. */
static __attribute__((noinline)) void benchmark_entries(EntryRunner runner,
    Fixture *f, AVZNativeCPU *cpu, const AGGuards *guards, unsigned window) {
    for (unsigned done = 0; done < 1048576; done += window) {
        AVZNativeBlockResult r = runner(f->program, window, cpu, guards, f->path[0]);
        CHECK(r.steps == window && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    }
}
void ag_memory_benchmark(int addressing) {
    const int entry_control = addressing == 3;
    if (entry_control) addressing = 0;
    static const uint32_t loops[][4] = {
        {0xf9400140, 0x8b000021, 0x91000442, 0x17fffffd},
        {0xf9000140, 0x91000400, 0x91000421, 0x17fffffd},
        {0xf9400140, 0x91000400, 0xf9000140, 0x17fffffd},
    };
    static const char *names[] = {"load64", "store64", "mixed64"};
    static const uint32_t address_loops[][4] = {
        {0xf85f8140, 0x91000400, 0xf81f8140, 0x17fffffd},
        {0xf8408540, 0x91000400, 0xf81f8d40, 0x17fffffd},
        {0x38ab6940, 0x91000400, 0x382b6940, 0x17fffffd},
    };
    static const char *address_names[] = {"unscaled64", "indexed64", "register_signed8"};
    static const uint32_t pair_loops[][4] = {
        {0xa9400540, 0x91000400, 0xa9000540, 0x17fffffd},
        {0xa8c10540, 0x91000400, 0xa9bf0540, 0x17fffffd},
        {0x69400540, 0x91000400, 0x29000540, 0x17fffffd},
    };
    static const char *pair_names[] = {"pair64", "pairindexed64", "pairsigned32"};
    AVZNativeBlockResult (*reference_run)(const AVZNativeInstruction *, size_t,
        uint64_t, uint64_t, AVZNativeCPU *, AVZNativeMemoryFastPath *) =
        addressing == 2 ? ag_reference_pair : ag_reference_memory;
    const unsigned windows[] = {4, 64, 256, 4096};
    puts("workload,window,round,mode,steps,wall_ns,cpu_ns,prepare_ns,bytes");
    for (unsigned work = 0; work < 3; work++) {
        const uint32_t *words = addressing == 2 ? pair_loops[work] : addressing ? address_loops[work] : loops[work];
        Fixture f, reference;
        uint64_t t = nanoseconds(CLOCK_MONOTONIC);
        AGProgram *prepared = ag_create(words, 4, CODE); CHECK(prepared);
        uint64_t prepare = nanoseconds(CLOCK_MONOTONIC) - t;
        ag_destroy(prepared);
        init(&f, words, 4); init(&reference, words, 4);
        AVZThreadedPrototype *tp = addressing || entry_control ? NULL : avz_tp_create(words, 4, CODE);
        CHECK(addressing || entry_control || tp);
        AVZNativeInstruction code[4];
        for (unsigned i = 0; i < 4; i++) CHECK(avz_native_decode_instruction(words[i], &code[i]));
        warm(&reference, 0, DATA, 8, 17);
        if (addressing == 2) warm(&reference, 0, DATA + 8, 8, 31);
        AVZNativeCPU start = cpu(); start.x[0] = 17;
        if (addressing == 1 && work == 0) start.x[10] += 8;
        if (addressing == 1 && work == 2) { start.x[10]--; start.x[11] = 1; }
        AVZNativeCPU expected = start;
        CHECK(reference_run(code, 4, CODE, 1048576, &expected, reference.path[0]).steps == 1048576);
        AGGuards g = {
            .local = avz_native_block_cache_code_mutation_epoch_token(f.cache[0]),
            .shared = {(const _Atomic uint64_t *)avz_native_block_cache_shared_code_mutation_epoch_token(f.cache[0])},
            .expected = {avz_native_block_cache_code_mutation_epoch(f.cache[0]),
                avz_native_block_cache_shared_code_mutation_epoch(f.cache[0])},
        };
        for (unsigned w = 0; w < 4; w++)
        for (unsigned round = 0; round < 15; round++)
        for (unsigned slot = 0; slot < (entry_control ? 2u : 3u); slot++) {
            unsigned mode = entry_control ? 2 + (slot + round) % 2 : (slot + round) % 3;
            if (addressing && mode == 1) continue; // Prototype has only unsigned-immediate memory.
            warm(&f, 0, DATA, 8, 17);
            if (addressing == 2) warm(&f, 0, DATA + 8, 8, 31);
            AVZNativeCPU c = start;
            if (mode == 0) (void)reference_run(code, 4, CODE, 8192, &c, f.path[0]);
            else if (mode == 1) (void)avz_tp_run_with_memory(tp, 8192, &c, f.path[0]);
            else if (mode == 3) (void)ag_run_memory_control(f.program, 8192, &c, &g, f.path[0]);
            else if (entry_control) (void)ag_run_memory_uncoalesced(f.program, 8192, &c, &g, f.path[0]);
            else (void)ag_run_memory(f.program, 8192, &c, &g, f.path[0]);
            warm(&f, 0, DATA, 8, 17); c = start;
            if (addressing == 2) warm(&f, 0, DATA + 8, 8, 31);
            avz_guest_memory_advance_dirty_epoch(f.ram);
            /* Keep preparation attribution independent of guard coalescing. */
            EntryRunner entry = mode == 3 ? ag_run_memory_control : ag_run_memory_uncoalesced;
            uint64_t ct = nanoseconds(CLOCK_THREAD_CPUTIME_ID), wt = nanoseconds(CLOCK_MONOTONIC);
            if (entry_control) benchmark_entries(entry, &f, &c, &g, windows[w]);
            else for (unsigned done = 0; done < 1048576; done += windows[w]) {
                AVZNativeBlockResult r = mode == 0 ? reference_run(code, 4, CODE, windows[w], &c, f.path[0]) :
                    mode == 1 ? avz_tp_run_with_memory(tp, windows[w], &c, f.path[0]) :
                    ag_run_memory(f.program, windows[w], &c, &g, f.path[0]);
                CHECK(r.steps == windows[w] && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            }
            wt = nanoseconds(CLOCK_MONOTONIC) - wt; ct = nanoseconds(CLOCK_THREAD_CPUTIME_ID) - ct;
            CHECK(!memcmp(&c, &expected, sizeof(c)));
            CHECK(!memcmp(avz_guest_memory_bytes(f.ram), avz_guest_memory_bytes(reference.ram), RAM_SIZE));
            CHECK(!f.calls && !f.faults);
            printf("%s,%u,%u,%u,1048576,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%zu\n",
                addressing == 2 ? pair_names[work] : addressing ? address_names[work] : names[work], windows[w], round, mode,
                wt, ct, prepare, ag_program_bytes(f.program));
        }
        avz_tp_destroy(tp); finish(&f); finish(&reference);
    }
}
