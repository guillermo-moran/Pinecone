/* Isolated service runtime tests, not production graph/cache integration. */
#include "../Sources/ARM64VizNative/Assembly/service_chain.h"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unwind.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "chain service line %d: %s\n", \
    __LINE__, #x); abort(); } } while (0)
enum { BASE = 0x1000, NEXT = 0x2000, DATA = 0x4000, RAM_SIZE = 0x8000, DEVICE = 0x100000 };
enum { NONE, SERIAL, LOCAL_PAGE, SHARED_PAGE, LOCAL_EPOCH, CODE_EPOCH, TLBI_EPOCH,
       RETIRE, REENTER, REJECT, EVENT };
typedef struct {
    AVZGuestMemory *ram;
    AVZNativeBlockCache *cache;
    AVZNativeMemoryFastPath *memory;
    AGServiceChain *chain;
    AGGuards proof;
    AGServiceBlock blocks[2];
    uint32_t words[2][16];
    uint64_t local, serial[2], generation[2], charged, calls, cap, reject, deadline;
    uintptr_t resident_frame;
    uint64_t resident_visits;
    AGServiceBoundary boundaries[32];
    uint64_t boundary_pcs[32];
    _Atomic uint64_t shared_page[2], events;
    unsigned action, helper_calls, fail_at, helper_retire, validation_calls, mutate_at;
    unsigned access_calls, deny_access;
    uint64_t writes[2];
    AGServiceAction stop_action;
    uint64_t stop_after_visits;
    int zero_after_visit;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned rendezvous, published, peer_kind;
} Fixture;

extern const char ag_code_end[];
extern uint64_t ag_abi_probe(AGRun *run);
extern void ag_clobber_volatile(void);
typedef struct { unsigned frames, after; uintptr_t cfa; } UnwindAudit;
static _Unwind_Reason_Code audit_frame(struct _Unwind_Context *context, void *opaque) {
    UnwindAudit *audit = opaque;
    uintptr_t ip = _Unwind_GetIP(context);
    if (ip >= (uintptr_t)ag_enter && ip < (uintptr_t)ag_code_end) {
        audit->frames++;
        audit->cfa = _Unwind_GetCFA(context);
    } else if (audit->frames) audit->after++;
    return _URC_NO_REASON;
}

static uint32_t branch(uint64_t from, uint64_t to) {
    return 0x14000000u | ((uint32_t)(((int64_t)to - (int64_t)from) / 4) & 0x3ffffffu);
}
static int translate(void *opaque, uint64_t address, uint8_t width,
    uint8_t write, uint64_t *physical) {
    (void)opaque; (void)write;
    if (address > RAM_SIZE - width) return 0;
    *physical = address; return 1;
}
static void retire(Fixture *f) {
    AGServiceChain *c = f->chain;
    CHECK(c && ag_service_chain_bytes(c) > 0);
    ag_service_chain_destroy(c);
    /* Still pinned during service/helper, and repeated retirement is harmless. */
    CHECK(ag_service_chain_bytes(c) > 0);
    ag_service_chain_destroy(c);
    f->chain = NULL;
}
static int read_device(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    CHECK(address == DEVICE || address == DEVICE + 8);
    CHECK(width == 8);
    f->helper_calls++;
    if (f->helper_retire && f->chain) retire(f);
    *value = 73;
    return f->helper_calls != f->fail_at;
}
static int write_device(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    uint64_t ignored;
    int ok = read_device(opaque, address, width, &ignored);
    if (ok) f->writes[(address - DEVICE) / 8] = value;
    return ok;
}
static int can_access_device(void *opaque, uint64_t address, uint8_t width, uint8_t write) {
    Fixture *f = opaque;
    (void)write;
    f->access_calls++;
    return !f->deny_access && width == 8 && (address == DEVICE || address == DEVICE + 8);
}
static int validate_owner(void *opaque, uint64_t base, size_t count, uint64_t serial) {
    Fixture *f = opaque;
    size_t i = base == f->blocks[0].base ? 0 : 1;
    CHECK(base == f->blocks[i].base);
    CHECK(count == f->blocks[i].count && serial == f->blocks[i].expected_serial);
    f->validation_calls++;
    if (f->mutate_at == f->validation_calls) f->serial[i]++;
    return f->reject != base;
}
static AGServiceChain *create(Fixture *f, size_t count) {
    return ag_service_chain_create(f->blocks, count, &f->proof, f->memory, validate_owner, f);
}
static void init(Fixture *f) {
    memset(f, 0, sizeof(*f));
    f->local = 1; f->cap = UINT64_MAX;
    CHECK(!pthread_mutex_init(&f->mutex, NULL));
    CHECK(!pthread_cond_init(&f->condition, NULL));
    f->ram = avz_guest_memory_create(RAM_SIZE);
    f->cache = avz_native_block_cache_create();
    CHECK(f->ram && f->cache);
    uint8_t *bytes = avz_guest_memory_bytes(f->ram);
    CHECK(avz_native_block_cache_bind_physical_memory(f->cache, bytes, 0, RAM_SIZE));
    f->memory = avz_native_memory_fast_path_create(bytes, 0, RAM_SIZE, f->cache, f,
        translate, read_device, write_device, can_access_device, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    CHECK(f->memory && avz_native_memory_fast_path_set_guest_memory(f->memory, f->ram));
    avz_native_memory_fast_path_set_instruction_translator(f->memory, translate);
    avz_native_memory_fast_path_set_detailed_statistics_enabled(f->memory, 0);
    f->proof = (AGGuards){.local = &f->local,
        .shared = {&f->ram->code_mutation_epoch, &f->ram->translation_epoch},
        .expected = {1, atomic_load(&f->ram->code_mutation_epoch), atomic_load(&f->ram->translation_epoch)}};
    atomic_init(&f->events, 0);
    for (unsigned i = 0; i < 2; i++) {
        f->serial[i] = f->generation[i] = 1;
        atomic_init(&f->shared_page[i], 1);
        uint64_t base = i ? NEXT : BASE;
        f->words[i][0] = i ? 0x91000421 : 0x91000400;
        f->words[i][1] = branch(base + 4, i ? BASE : NEXT);
        f->blocks[i] = (AGServiceBlock){.words = f->words[i], .count = 2, .base = base,
            .serial = &f->serial[i], .expected_serial = 1,
            .local_generation = &f->generation[i], .expected_local_generation = 1,
            .shared_generation = &f->shared_page[i], .expected_shared_generation = 1};
    }
}
static void finish(Fixture *f) {
    ag_service_chain_destroy(f->chain);
    avz_native_memory_fast_path_destroy(f->memory);
    avz_native_block_cache_destroy(f->cache);
    avz_guest_memory_destroy(f->ram);
    CHECK(!pthread_cond_destroy(&f->condition));
    CHECK(!pthread_mutex_destroy(&f->mutex));
}
static AGServiceLimits limits(uint64_t steps) {
    return (AGServiceLimits){steps, steps, steps, steps, NULL};
}
static AGServiceDecision service(void *opaque, const AGServiceBoundary *b, const AVZNativeCPU *cpu) {
    Fixture *f = opaque;
    uintptr_t sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    CHECK(!(sp & 15));
    UnwindAudit audit = {0};
    _Unwind_Backtrace(audit_frame, &audit);
    unsigned resident = !b->initial && b->status == AVZ_NATIVE_STATUS_MAX_STEPS;
    CHECK(audit.frames == resident);
    if (resident) {
        CHECK(audit.after && audit.cfa);
        CHECK(!f->resident_frame || f->resident_frame == audit.cfa);
        f->resident_frame = audit.cfa;
        f->resident_visits++;
    }
    CHECK(b->retired_delta <= 16);
    CHECK(f->charged + b->retired_delta == b->total_steps);
    if (f->calls < 32) {
        f->boundaries[f->calls] = *b;
        f->boundary_pcs[f->calls] = cpu->pc;
    }
    f->calls++; f->charged += b->retired_delta;
    if (!b->initial && f->peer_kind) {
        CHECK(!pthread_mutex_lock(&f->mutex));
        f->rendezvous = 1;
        CHECK(!pthread_cond_signal(&f->condition));
        while (!f->published) CHECK(!pthread_cond_wait(&f->condition, &f->mutex));
        CHECK(!pthread_mutex_unlock(&f->mutex));
    }
    int irq = avz_native_memory_fast_path_advance_time(f->memory, b->retired_delta, cpu->pstate);
    if (!b->initial) {
        unsigned action = f->action; f->action = NONE;
        switch (action) {
        case SERIAL: f->serial[1]++; break;
        case LOCAL_PAGE: f->generation[1]++; break;
        case SHARED_PAGE: atomic_fetch_add(&f->shared_page[1], 1); break;
        case LOCAL_EPOCH: f->local++; break;
        case CODE_EPOCH: atomic_fetch_add(&f->ram->code_mutation_epoch, 1); break;
        case TLBI_EPOCH: avz_guest_memory_invalidate_translations(f->ram); break;
        case RETIRE: retire(f); break;
        case REJECT: f->reject = NEXT; break;
        case EVENT: atomic_store(&f->events, 1); break;
        case REENTER: {
            AVZNativeCPU copy = *cpu;
            AGServiceResult r = ag_service_chain_run(f->chain, limits(8), &copy, service, f);
            CHECK(r.stop == AG_SERVICE_STOP_INVALID && !r.architectural.steps && !r.visits);
            CHECK(!memcmp(&copy, cpu, sizeof(copy))); break;
        }
        default: break;
        }
    }
    ag_clobber_volatile();
    if (irq) return (AGServiceDecision){0, AG_SERVICE_IRQ};
    if (!b->initial && f->stop_action && b->visits >= f->stop_after_visits)
        return (AGServiceDecision){0, f->stop_action};
    uint64_t cap = (!b->initial && f->zero_after_visit) ? 0 : f->cap;
    if (f->deadline) {
        if (b->total_steps >= f->deadline) return (AGServiceDecision){0, AG_SERVICE_DEADLINE};
        if (cap > f->deadline - b->total_steps) cap = f->deadline - b->total_steps;
    }
    /* Test adapter uses the real native timer state and checked ceil division.
     * Production owns this policy; it is not duplicated in the runtime. */
    AVZNativeArchitecturalState state;
    avz_native_memory_fast_path_get_architectural_state(f->memory, &state);
    if (!(cpu->pstate & 0x80) && state.timer_cycles_per_instruction) {
        uint64_t controls[] = {state.cntp_ctl_el0, state.cntv_ctl_el0};
        uint64_t compares[] = {state.cntp_cval_el0, state.cntv_cval_el0};
        for (unsigned i = 0; i < 2; i++) if ((controls[i] & 3) == 1) {
            CHECK(compares[i] > state.counter_ticks);
            uint64_t delta = compares[i] - state.counter_ticks;
            uint64_t cycles = state.timer_cycles_per_instruction;
            uint64_t remaining = delta / cycles + (delta % cycles != 0);
            if (remaining < cap) cap = remaining;
        }
    }
    return (AGServiceDecision){cap, AG_SERVICE_CONTINUE};
}
static AGServiceResult run(Fixture *f, AGServiceLimits l, AVZNativeCPU *cpu) {
    f->charged = f->calls = 0;
    f->resident_frame = f->resident_visits = 0;
    l.events = &f->events;
    AGServiceResult r = ag_service_chain_run(f->chain, l, cpu, service, f);
    CHECK(r.timer_accounted_steps == r.architectural.steps && f->charged == r.architectural.steps);
    CHECK(!r.architectural.mapped_blocks && !r.architectural.fast_path_hits);
    CHECK(r.architectural.generic_dispatches == r.architectural.steps);
    return r;
}

typedef struct { AGRun run; AGProgram *program; unsigned calls; } ABIVisit;
static int abi_boundary(AGRun *run) {
    ABIVisit *visit = (ABIVisit *)run;
    CHECK(run->result.steps == 1 && run->result.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    ag_clobber_volatile();
    if (++visit->calls == 4) return 0;
    run->operation = visit->program->operations;
    run->budget = 1;
    run->result = (AVZNativeBlockResult){0};
    return 1;
}
static void abi(int resident) {
    const uint32_t add = 0x91000400;
    AGProgram *program = ag_create(&add, 1, BASE); CHECK(program);
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 0xa0000005};
    AGChainControl control = {.service = abi_boundary};
    ABIVisit visit = {.run = {.cpu = &cpu, .operation = program->operations, .budget = 1,
        .chain = resident ? &control : NULL}, .program = program};
    CHECK(!ag_abi_probe(&visit.run));
    CHECK(cpu.x[0] == (resident ? 4u : 1u) && cpu.pstate == 0xa0000005);
    CHECK(visit.calls == (resident ? 4u : 0u));
    ag_destroy(program);
    puts(resident ? "PASS resident ABI GPR/d8-d15/FP/SP preservation across clobbering callbacks" :
        "PASS ordinary same-build entry ABI and chain-disabled execution");
}

static void suffix_flags(void) {
    for (unsigned suffix = 0; suffix < 2; suffix++) {
        Fixture f; init(&f);
        f.blocks[0].count = 3;
        f.words[0][0] = 0xb1000400; /* ADDS x0,x0,#1 */
        f.words[0][1] = 0x9a1f0021; /* ADC x1,x1,xzr */
        f.words[0][2] = branch(BASE + 8, BASE + 4);
        f.chain = create(&f, 1); CHECK(f.chain);
        AVZNativeCPU cpu = {.pc = BASE + suffix * 4, .pstate = 0x60000005};
        cpu.x[0] = UINT64_MAX;
        AVZNativeCPU expected = cpu;
        AGProgram *ordinary = ag_create(f.words[0], 3, BASE); CHECK(ordinary);
        uint64_t steps = 0, visits = 0;
        /* Same-build old per-visit entry control, including exact suffix caps. */
        while (steps < 9) {
            uint64_t n = 3 - (expected.pc - BASE) / 4;
            if (n > 9 - steps) n = 9 - steps;
            AVZNativeBlockResult part = ag_run_memory(ordinary, n, &expected, &f.proof, f.memory);
            CHECK(part.steps == n && part.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            steps += n; visits++;
        }
        unsigned validations = f.validation_calls;
        AGServiceResult r = run(&f, limits(9), &cpu);
        CHECK(!memcmp(&cpu, &expected, sizeof(cpu)));
        CHECK(r.architectural.steps == steps && r.visits == visits);
        CHECK(f.resident_visits == visits && visits == (suffix ? 5u : 4u));
        CHECK(f.validation_calls - validations == 2 + visits);
        CHECK(f.calls == visits + 1 && f.boundaries[0].initial);
        CHECK(f.boundaries[1].retired_delta == (suffix ? 2u : 3u));
        CHECK(cpu.x[1] == (suffix ? 5u : 4u) && cpu.pstate == 0x60000005);
        for (uint64_t i = 1; i < visits; i++) {
            CHECK(f.boundary_pcs[i] == BASE + 4);
            CHECK(f.boundaries[i].visits == i);
        }
        ag_destroy(ordinary);
        finish(&f);
    }
    /* Carry crosses a service call, followed by a direct cross-member suffix. */
    Fixture f; init(&f);
    f.words[0][0] = 0xb1000400;
    f.words[1][0] = 0x9a1f0021;
    f.words[1][1] = branch(NEXT + 4, BASE + 4);
    f.chain = create(&f, 2); CHECK(f.chain);
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[0] = UINT64_MAX;
    AGServiceResult r = run(&f, limits(8), &cpu);
    CHECK(r.visits == 5 && cpu.x[0] == 0 && cpu.x[1] == 2 && cpu.pstate == 0x60000005);
    CHECK(f.boundaries[3].retired_delta == 1 && f.boundaries[5].retired_delta == 1);
    CHECK(f.resident_visits == 5);
    finish(&f);
    puts("PASS exact internal/cross-member suffix visits and flags versus same-build per-visit entry");
}

static void conditional_fallthrough(void) {
    for (unsigned form = 0; form < 4; form++) for (unsigned take = 0; take < 2; take++) {
        Fixture f; init(&f);
        f.blocks[1].base = BASE + 8;
        /* Taken edges enter the suffix; untaken edges use the linked sentinel. */
        const uint32_t last[] = {0x54000040, 0xb4000044, 0x36000044, 0xd503201f};
        f.words[0][1] = last[form]; /* B.EQ / CBZ x4 / TBZ x4,#0 / NOP */
        f.words[1][1] = branch(BASE + 12, BASE);
        f.chain = create(&f, 2); CHECK(f.chain);
        AGProgram *ordinary[] = {ag_create(f.words[0], 2, BASE),
            ag_create(f.words[1], 2, BASE + 8)};
        CHECK(ordinary[0] && ordinary[1]);
        for (uint64_t budget = 1; budget <= 10; budget++) {
            AVZNativeCPU cpu = {.pc = BASE, .pstate = take ? 0x40000005 : 5};
            cpu.x[4] = !take;
            AVZNativeCPU expected = cpu;
            uint64_t steps = 0, visits = 0;
            while (steps < budget) {
                unsigned index = expected.pc >= BASE + 8;
                uint64_t count = 2 - (expected.pc - f.blocks[index].base) / 4;
                if (count > budget - steps) count = budget - steps;
                AVZNativeBlockResult part = ag_run_memory(ordinary[index], count, &expected, &f.proof, f.memory);
                CHECK(part.steps == count && part.status == AVZ_NATIVE_STATUS_MAX_STEPS);
                steps += count; visits++;
            }
            AGServiceResult r = run(&f, limits(budget), &cpu);
            CHECK(!memcmp(&cpu, &expected, sizeof(cpu)));
            CHECK(r.architectural.steps == steps && r.visits == visits && f.resident_visits == visits);
        }
        ag_destroy(ordinary[0]); ag_destroy(ordinary[1]); finish(&f);
    }
    puts("PASS 80 conditional/interior/fallthrough cases versus same-build ordinary entry");
}

static void budgets(void) {
    Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
    CHECK(ag_service_chain_bytes(f.chain) <= AG_SERVICE_MAX_BYTES);
    unsigned cases = 0;
    for (uint64_t s = 1; s <= 6; s++) for (uint64_t c = 1; c <= 6; c++)
    for (uint64_t v = 1; v <= 3; v++) for (uint64_t cv = 1; cv <= 3; cv++) {
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        uint64_t n = s < c ? s : c;
        if (n > 2 * v) n = 2 * v;
        if (n > 2 * cv) n = 2 * cv;
        AGServiceResult r = run(&f, (AGServiceLimits){s, c, v, cv, NULL}, &cpu);
        CHECK(r.architectural.steps == n && r.visits == (n + 1) / 2);
        CHECK(f.calls == r.visits + 1 && r.has_last_member);
        CHECK(cpu.x[0] == (n + 3) / 4 && cpu.x[1] == (n + 1) / 4);
        uint64_t pcs[] = {BASE, BASE + 4, NEXT, NEXT + 4}; CHECK(cpu.pc == pcs[n % 4]);
        CHECK(r.architectural.status == (n == s ? AVZ_NATIVE_STATUS_MAX_STEPS : AVZ_NATIVE_STATUS_YIELDED));
        cases++;
    }
    for (unsigned zero = 0; zero < 4; zero++) {
        AGServiceLimits l = limits(8);
        if (zero == 0) l.steps = 0;
        if (zero == 1) l.checkpoint_steps = 0;
        if (zero == 2) l.visits = 0;
        if (zero == 3) l.checkpoint_visits = 0;
        AVZNativeCPU cpu = {.pc = BASE}, before = cpu;
        AGServiceResult r = run(&f, l, &cpu);
        CHECK(r.stop == AG_SERVICE_STOP_INVALID && !r.visits && !f.calls);
        CHECK(!memcmp(&cpu, &before, sizeof(cpu)));
    }
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = run(&f, (AGServiceLimits){UINT64_MAX, UINT64_MAX, 1, 1, NULL}, &cpu);
    CHECK(r.architectural.steps == 2 && r.visits == 1);
    f.cap = 1; cpu.pc = BASE;
    r = run(&f, limits(5), &cpu); CHECK(r.architectural.steps == 5 && r.visits == 5);
    f.cap = 0; cpu.pc = BASE;
    r = run(&f, limits(5), &cpu); CHECK(!r.visits && r.stop == AG_SERVICE_STOP_ALLOWANCE);
    f.cap = 16; f.zero_after_visit = 1;
    r = run(&f, limits(8), &cpu); CHECK(r.architectural.steps == 2 && r.stop == AG_SERVICE_STOP_ALLOWANCE);
    f.zero_after_visit = 0;
    r = run(&f, limits(3), &cpu); CHECK(r.architectural.steps == 3 && r.visits == 2);
    atomic_store(&f.events, 1);
    r = run(&f, limits(8), &cpu); CHECK(!r.visits && r.stop == AG_SERVICE_STOP_EVENT && atomic_load(&f.events));
    finish(&f);
    printf("PASS %u budget/visit combinations, zero/UINT64_MAX limits, zero-service/fresh resume, events\n", cases);
}

static void admission_and_targets(void) {
    Fixture f; init(&f);
    f.reject = NEXT; CHECK(!create(&f, 2)); /* Whole semantic target excluded. */
    f.chain = create(&f, 1); CHECK(f.chain);
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = run(&f, limits(8), &cpu);
    CHECK(r.stop == AG_SERVICE_STOP_OUTSIDE && r.architectural.steps == 2 && !cpu.x[1]);
    ag_service_chain_destroy(f.chain); f.chain = NULL; f.reject = 0;
    f.mutate_at = f.validation_calls + 3; CHECK(!create(&f, 2)); /* Post-copy proof check. */
    f.mutate_at = 0; f.serial[0] = f.serial[1] = 1;
    f.words[0][0] = branch(BASE, NEXT); CHECK(!create(&f, 2)); /* Branch must end member. */
    f.words[0][0] = 0xd503207f; CHECK(!create(&f, 2)); /* WFI remains C. */
    f.words[0][0] = 0x91000400;
    f.blocks[0].base = 0x1ffc; CHECK(!create(&f, 2)); f.blocks[0].base = BASE;
    CHECK(!ag_service_chain_create(f.blocks, 9, &f.proof, f.memory, validate_owner, &f));
    CHECK(!ag_service_chain_create(f.blocks, 2, &f.proof, f.memory, NULL, &f));
    f.words[0][1] = branch(BASE + 4, BASE); /* Repeat same member, then enter suffix. */
    f.chain = create(&f, 1); CHECK(f.chain);
    cpu = (AVZNativeCPU){.pc = BASE + 4, .pstate = 5};
    r = run(&f, limits(7), &cpu); CHECK(r.architectural.steps == 7 && r.visits == 4 && cpu.x[0] == 3);
    ag_service_chain_destroy(f.chain);
    f.words[0][1] = 0xd61f0140; /* BR x10 to interior of another member. */
    f.chain = create(&f, 2); CHECK(f.chain);
    memset(f.words, 0, sizeof(f.words)); /* Private immutable copies. */
    cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5}; cpu.x[10] = NEXT + 4;
    r = run(&f, limits(5), &cpu); CHECK(r.visits == 3 && cpu.pc == NEXT + 4 && !cpu.x[1]);
    finish(&f);
    puts("PASS admission/post-copy proof checks, whole-target rejection, private copies, direct/indirect suffix loops");
}

static void timers_and_stops(void) {
    for (uint64_t deadline = 1; deadline <= 7; deadline++) {
        Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
        f.deadline = deadline;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        AGServiceResult r = run(&f, limits(20), &cpu);
        CHECK(r.stop == AG_SERVICE_STOP_CALLBACK && r.service_action == AG_SERVICE_DEADLINE);
        CHECK(r.architectural.steps == deadline && r.visits == (deadline + 1) / 2);
        CHECK(f.resident_visits == r.visits && f.calls == r.visits + 1);
        finish(&f);
    }
    for (unsigned kind = 0; kind < 6; kind++) {
        Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
        AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 2};
        if (kind == 0 || kind == 3) { state.cntp_ctl_el0 = 1; state.cntp_cval_el0 = 3; }
        if (kind == 1) { state.cntv_ctl_el0 = 1; state.cntv_cval_el0 = 5; }
        if (kind == 2) state.pending_irq = 1;
        if (kind == 4) { state.cntp_ctl_el0 = 3; state.cntp_cval_el0 = 1; }
        if (kind == 5) { state.timer_cycles_per_instruction = 0; state.cntp_ctl_el0 = 1; state.cntp_cval_el0 = 1; }
        avz_native_memory_fast_path_set_architectural_state(f.memory, &state);
        AVZNativeCPU cpu = {.pc = BASE, .pstate = kind == 3 ? 0x85 : 5};
        AGServiceResult r = run(&f, limits(8), &cpu);
        uint64_t expected = kind == 0 ? 2 : kind == 1 ? 3 : kind == 2 ? 0 : 8;
        CHECK(r.architectural.steps == expected);
        CHECK((r.service_action == AG_SERVICE_IRQ) == (kind < 3));
        avz_native_memory_fast_path_get_architectural_state(f.memory, &state);
        CHECK(state.counter_ticks == expected * state.timer_cycles_per_instruction);
        finish(&f);
    }
    for (AGServiceAction action = AG_SERVICE_DEADLINE; action <= AG_SERVICE_REVALIDATE; action++) {
        Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain); f.stop_action = action;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        AGServiceResult r = run(&f, limits(8), &cpu);
        CHECK(r.architectural.steps == 2 && r.visits == 1 && r.service_action == action);
        CHECK(r.architectural.status == (action == AG_SERVICE_REVALIDATE ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_YIELDED));
        finish(&f);
    }
    Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
    AVZNativeCounterClock clock; CHECK(avz_native_counter_clock_initialize(&clock, 0, 1000000));
    avz_native_memory_fast_path_set_counter_clock(f.memory, &clock);
    f.memory->counter_refresh_instructions = 1023;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = run(&f, limits(4), &cpu);
    CHECK(r.visits == 2 && f.calls == 3 && f.memory->counter_refresh_instructions < 1024);
    finish(&f);
    puts("PASS physical/virtual timers, pending/masked IRQ, zero cycles, deadline/checkpoint stops and native host-clock refresh");
}

static void invalidation(void) {
    for (unsigned action = SERIAL; action <= EVENT; action++) {
        Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain); f.action = action;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        AGServiceResult r = run(&f, limits(8), &cpu);
        if (action == REENTER) CHECK(r.architectural.steps == 8 && r.visits == 4);
        else {
            CHECK(r.architectural.steps == 2 && r.visits == 1 && !cpu.x[1]);
            CHECK(r.architectural.status == (action == EVENT ? AVZ_NATIVE_STATUS_YIELDED : AVZ_TP_STATUS_REVALIDATE));
        }
        finish(&f);
    }
    Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
    f.serial[0]++;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = run(&f, limits(8), &cpu); CHECK(!r.visits && !f.calls);
    finish(&f);
    puts("PASS strict serial/local/shared proof invalidation, retirement pins, reentry denial and pre-entry rejection");
}

static void helpers(void) {
    for (unsigned fail = 0; fail < 2; fail++) for (unsigned retirement = 0; retirement < 2; retirement++) {
        Fixture f; init(&f);
        f.words[1][1] = 0xf9400142; /* LDR x2,[x10], after a resident predecessor. */
        f.chain = create(&f, 2); CHECK(f.chain);
        f.fail_at = fail; f.helper_retire = retirement;
        f.stop_action = AG_SERVICE_DEADLINE; f.stop_after_visits = 2;
        AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 7};
        avz_native_memory_fast_path_set_architectural_state(f.memory, &state);
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[10] = DEVICE; cpu.x[2] = 99;
        AGServiceResult r = run(&f, limits(8), &cpu);
        CHECK(r.architectural.steps == (fail ? 3u : 4u) && r.visits == 2);
        CHECK(r.architectural.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(r.stop == AG_SERVICE_STOP_EXECUTOR && r.service_action == AG_SERVICE_DEADLINE);
        CHECK(cpu.pc == NEXT + (fail ? 4u : 8u) && cpu.x[2] == (fail ? 99u : 73u));
        CHECK(f.helper_calls == 1 && f.calls == 3 && f.resident_visits == 1);
        CHECK(f.boundaries[1].retired_delta == 2 && f.boundaries[2].retired_delta == (fail ? 1u : 2u));
        avz_native_memory_fast_path_get_architectural_state(f.memory, &state);
        CHECK(state.counter_ticks == r.architectural.steps * 7);
        finish(&f);
    }
    for (unsigned pair = 0; pair < 2; pair++) for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned retirement = 0; retirement < 2; retirement++) {
        Fixture f; init(&f);
        f.words[0][1] = pair ? 0xa8810540 : 0xf8008540; /* STP x0,x1,[x10],#16 / STR x0,[x10],#8 */
        f.chain = create(&f, 1); CHECK(f.chain);
        f.helper_retire = retirement; f.fail_at = fail ? (pair ? 2 : 1) : 0;
        f.stop_action = AG_SERVICE_PREEMPT;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[0] = 8; cpu.x[1] = 17; cpu.x[10] = DEVICE;
        AGServiceResult r = run(&f, limits(2), &cpu);
        CHECK(r.architectural.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(r.architectural.steps == (fail ? 1u : 2u) && r.visits == 1);
        CHECK(cpu.pc == BASE + (fail ? 4u : 8u));
        CHECK(cpu.x[10] == DEVICE + (fail ? 0u : pair ? 16u : 8u));
        CHECK(f.helper_calls == (pair ? 2u : 1u));
        CHECK(f.access_calls == (pair ? 2u : 0u));
        CHECK(r.stop == AG_SERVICE_STOP_EXECUTOR && r.service_action == AG_SERVICE_PREEMPT);
        if (pair || !fail) CHECK(f.writes[0] == 9);
        if (pair && !fail) CHECK(f.writes[1] == 17);
        finish(&f);
    }
    Fixture f; init(&f); f.words[0][0] = 0xf9400140; /* fault on first instruction */
    f.chain = create(&f, 1); CHECK(f.chain); f.fail_at = 1;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[10] = DEVICE;
    AGServiceResult r = run(&f, limits(2), &cpu);
    CHECK(r.architectural.status == AVZ_TP_STATUS_MEMORY_FAULT && !r.architectural.steps && r.visits == 1);
    finish(&f);
    init(&f); f.words[0][1] = 0xa8810540;
    f.chain = create(&f, 1); CHECK(f.chain); f.deny_access = 1;
    f.stop_action = AG_SERVICE_PREEMPT;
    cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5}; cpu.x[10] = DEVICE;
    r = run(&f, limits(2), &cpu);
    CHECK(r.architectural.status == AVZ_TP_STATUS_MEMORY_FAULT && r.architectural.steps == 1);
    CHECK(r.visits == 1 && f.access_calls == 1 && !f.helper_calls);
    CHECK(cpu.pc == BASE + 4 && cpu.x[10] == DEVICE && !f.writes[0] && !f.writes[1]);
    CHECK(r.stop == AG_SERVICE_STOP_EXECUTOR && r.service_action == AG_SERVICE_PREEMPT);
    finish(&f);
    puts("PASS terminal helpers after resident visits, residual charge, faults/writeback, pair partial stores, deadline/preemption precedence, retirement");
}

static void *publish_peer(void *opaque) {
    Fixture *f = opaque;
    CHECK(!pthread_mutex_lock(&f->mutex));
    while (!f->rendezvous) CHECK(!pthread_cond_wait(&f->condition, &f->mutex));
    if (f->peer_kind == 1) {
        uint32_t nop = 0xd503201f;
        avz_guest_memory_lock_range(f->ram, NEXT, 4);
        memcpy(avz_guest_memory_bytes(f->ram) + NEXT, &nop, 4);
        avz_guest_memory_note_write(f->ram, NEXT, 4);
        avz_guest_memory_unlock_range(f->ram, NEXT, 4);
    } else {
        unsigned count = f->peer_kind == 6 ? 65 : 1;
        for (unsigned i = 0; i < count; i++) {
            AVZNativeTLBI tlbi = {.kind = f->peer_kind == 6 ? 0 : f->peer_kind - 2,
                .broadcast = 1, .virtual_address = NEXT};
            avz_guest_memory_publish_tlbi(f->ram, tlbi);
        }
    }
    f->published = 1;
    CHECK(!pthread_cond_signal(&f->condition));
    CHECK(!pthread_mutex_unlock(&f->mutex));
    return NULL;
}
static void peer_publication(void) {
    for (unsigned kind = 1; kind <= 6; kind++) {
        Fixture f; init(&f);
        avz_guest_memory_mark_code_page(f.ram, NEXT, 0);
        f.chain = create(&f, 2); CHECK(f.chain); f.peer_kind = kind;
        pthread_t peer; CHECK(!pthread_create(&peer, NULL, publish_peer, &f));
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        AGServiceResult r = run(&f, limits(8), &cpu);
        CHECK(!pthread_join(peer, NULL));
        CHECK(r.architectural.status == AVZ_TP_STATUS_REVALIDATE && r.architectural.steps == 2 && !cpu.x[1]);
        CHECK(f.memory->observed_shared_translation_epoch == atomic_load(&f.ram->translation_epoch));
        finish(&f);
    }
    puts("PASS rendezvous peer SMC and four TLBI scopes/journal overflow before successor, native catch-up, no stale successor");
}

int main(void) {
#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
    const int service_disabled = 0;
#else
    const int service_disabled = 1;
#endif
    if (service_disabled || !ag_available()) {
        AGServiceResult r = ag_service_chain_run(NULL, limits(1), NULL, NULL, NULL);
        CHECK(r.architectural.status == AVZ_TP_STATUS_DISABLED && !r.visits);
        CHECK(!ag_service_chain_create(NULL, 0, NULL, NULL, NULL, NULL));
        if (ag_available()) abi(0);
        puts(service_disabled ? "PASS default-off chain-service stubs" :
            "PASS assembly-disabled chain-service API"); return 0;
    }
    abi(0); abi(1); budgets(); suffix_flags(); conditional_fallthrough(); admission_and_targets();
    timers_and_stops(); invalidation(); helpers(); peer_publication();
    puts("PASS isolated chain-service prerequisites; no production graph wiring or speedup claimed");
    return 0;
}
