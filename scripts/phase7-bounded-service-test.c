/* Reuse the isolated fixture, not its every-visit callback or assertions. */
#define main generic_service_test_main
#include "phase7-chain-service-test.c"
#undef main

#if defined(AG_BOUNDED_ALLOC_TEST) && AG_BOUNDED_ALLOC_TEST
static long bounded_alloc_failure = -1;
static size_t bounded_alloc_calls;
/* Only service_chain.c is compiled with this malloc substitution. No hooks,
 * mutable allocator state or fault-injection branches enter production. */
void *ag_bounded_test_malloc(size_t size) {
    bounded_alloc_calls++;
    if (!bounded_alloc_failure) return NULL;
    if (bounded_alloc_failure > 0) bounded_alloc_failure--;
    return malloc(size);
}
#endif

static AGServiceDecision bounded_callback(void *opaque, const AGServiceBoundary *b,
    const AVZNativeCPU *cpu) {
    Fixture *f = opaque;
    CHECK(f->charged + b->retired_delta == b->total_steps);
    CHECK(f->calls < 32);
    f->boundaries[f->calls] = *b;
    f->boundary_pcs[f->calls++] = cpu->pc;
    f->charged += b->retired_delta;
    UnwindAudit audit = {0};
    _Unwind_Backtrace(audit_frame, &audit);
    if (audit.frames) {
        CHECK(audit.frames == 1 && audit.after && audit.cfa);
        f->resident_visits++;
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
            AGServiceResult r = ag_service_chain_run_bounded(f->chain, limits(8), &copy,
                bounded_callback, f);
            CHECK(r.stop == AG_SERVICE_STOP_INVALID && !r.visits);
            CHECK(!memcmp(cpu, &copy, sizeof(copy))); break;
        }
        default: break;
        }
    }
    ag_clobber_volatile();
    if (irq) return (AGServiceDecision){0, AG_SERVICE_IRQ};
    if (!b->initial && f->stop_action && f->helper_calls >= f->stop_after_visits)
        return (AGServiceDecision){0, f->stop_action};
    return (AGServiceDecision){(!b->initial && f->zero_after_visit) ? 0 : f->cap,
        AG_SERVICE_CONTINUE};
}

static AGServiceResult bounded_run(Fixture *f, AGServiceLimits l, AVZNativeCPU *cpu) {
    f->calls = f->charged = f->resident_visits = 0;
    l.events = &f->events;
    AGServiceResult r = ag_service_chain_run_bounded(f->chain, l, cpu, bounded_callback, f);
    CHECK(r.timer_accounted_steps == r.architectural.steps && f->charged == r.architectural.steps);
    return r;
}

static void bounded_budgets(void) {
    Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
    f.cap = 5;
    for (uint64_t s = 1; s <= 8; s++) for (uint64_t c = 1; c <= 8; c++)
    for (uint64_t v = 1; v <= 3; v++) for (uint64_t cv = 1; cv <= 3; cv++) {
        uint64_t n = s < c ? s : c;
        if (n > f.cap) n = f.cap;
        if (n > 2 * v) n = 2 * v;
        if (n > 2 * cv) n = 2 * cv;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        unsigned validations = f.validation_calls;
        AGServiceResult r = bounded_run(&f, (AGServiceLimits){s, c, v, cv, NULL}, &cpu);
        CHECK(r.architectural.steps == n && r.visits == (n + 1) / 2);
        CHECK(f.calls == 2 && !f.resident_visits && f.validation_calls == validations + 6);
        CHECK(f.boundaries[1].retired_delta == n && f.boundaries[1].visits == r.visits);
        CHECK(r.has_last_member && r.last_member_serial == 1);
        CHECK(r.last_member_base == (r.visits % 2 ? BASE : NEXT));
        CHECK(cpu.x[0] == (n + 3) / 4 && cpu.x[1] == (n + 1) / 4);
        AGServiceStop expected = n == s ? AG_SERVICE_STOP_STEPS :
            n == c || r.visits == cv ? AG_SERVICE_STOP_CHECKPOINT :
            r.visits == v ? AG_SERVICE_STOP_VISITS : AG_SERVICE_STOP_ALLOWANCE;
        CHECK(r.stop == expected && r.service_action == AG_SERVICE_CONTINUE);
    }
    f.cap = UINT64_MAX;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = bounded_run(&f, limits(257), &cpu);
    CHECK(r.visits == 129 && f.calls == 2 && f.boundaries[1].retired_delta == 257);
    /* The same graph still uses the original every-visit API without mutation. */
    cpu.pc = BASE;
    r = run(&f, limits(8), &cpu);
    CHECK(r.visits == 4 && f.calls == 5);
    finish(&f);
    puts("PASS bounded budgets, constant callback/validation counts, last-member and generic reuse");
}

static void bounded_targets(void) {
    for (unsigned form = 0; form < 6; form++) for (unsigned take = 0; take < 2; take++) {
        Fixture f; init(&f); f.blocks[1].base = BASE + 8;
        const uint32_t last[] = {0x54000040, 0xb4000044, 0x36000044,
            0xd503201f, 0xd61f0140, 0xd63f03c0};
        f.words[0][1] = last[form];
        f.words[1][1] = branch(BASE + 12, BASE + 4);
        f.chain = create(&f, 2); CHECK(f.chain);
        AGProgram *ordinary[] = {ag_create(f.words[0], 2, BASE),
            ag_create(f.words[1], 2, BASE + 8)};
        CHECK(ordinary[0] && ordinary[1]);
        for (uint64_t budget = 1; budget <= 12; budget++) {
            AVZNativeCPU cpu = {.pc = BASE, .pstate = take ? 0x40000005 : 5};
            cpu.x[4] = !take; cpu.x[10] = BASE + 12; cpu.x[30] = BASE + 12;
            AVZNativeCPU expected = cpu;
            uint64_t steps = 0, visits = 0;
            while (steps < budget) {
                unsigned i = expected.pc >= BASE + 8;
                uint64_t n = 2 - (expected.pc - f.blocks[i].base) / 4;
                if (n > budget - steps) n = budget - steps;
                AVZNativeBlockResult p = ag_run_memory(ordinary[i], n, &expected, &f.proof, f.memory);
                CHECK(p.steps == n);
                steps += n; visits++;
            }
            AGServiceResult r = bounded_run(&f, limits(budget), &cpu);
            CHECK(!memcmp(&cpu, &expected, sizeof(cpu)) && r.visits == visits);
            CHECK(r.architectural.steps == steps && f.calls == 2);
        }
        ag_destroy(ordinary[0]); ag_destroy(ordinary[1]); finish(&f);
    }
    puts("PASS bounded conditional, fallthrough, suffix, BR and BLR-x30 differential cases");
}

static int timed_read(void *opaque, uint64_t address, uint8_t width, uint64_t *value) {
    Fixture *f = opaque;
    AVZNativeArchitecturalState state;
    avz_native_memory_fast_path_get_architectural_state(f->memory, &state);
    CHECK(f->calls == 2 && state.counter_ticks == f->charged * 7);
    CHECK(f->boundaries[1].status == AVZ_NATIVE_STATUS_MAX_STEPS);
    return read_device(opaque, address, width, value);
}
static int timed_write(void *opaque, uint64_t address, uint8_t width, uint64_t value) {
    Fixture *f = opaque;
    uint64_t ignored;
    int ok = timed_read(opaque, address, width, &ignored);
    if (ok) f->writes[(address - DEVICE) / 8] = value;
    return ok;
}
static void timed_fixture(Fixture *f) {
    init(f);
    f->memory->slow_read = timed_read; f->memory->slow_write = timed_write;
    AVZNativeArchitecturalState state = {.timer_cycles_per_instruction = 7};
    avz_native_memory_fast_path_set_architectural_state(f->memory, &state);
}

static AGServiceDecision changing_veto(void *opaque, const AGServiceBoundary *b,
    const AVZNativeCPU *cpu) {
    Fixture *f = opaque;
    AGServiceDecision d = bounded_callback(opaque, b, cpu);
    if (f->calls == 2) return (AGServiceDecision){0,
        f->deadline ? AG_SERVICE_CONTINUE : AG_SERVICE_IRQ};
    if (f->calls == 3 && f->deadline) return (AGServiceDecision){0, AG_SERVICE_IRQ};
    return d;
}

static void bounded_helpers(void) {
    for (unsigned pair = 0; pair < 2; pair++) for (unsigned fail = 0; fail < 2; fail++)
    for (unsigned retirement = 0; retirement < 2; retirement++) {
        Fixture f; timed_fixture(&f);
        f.words[1][1] = pair ? 0xa8810540 : 0xf8008540;
        f.chain = create(&f, 2); CHECK(f.chain);
        f.fail_at = fail ? (pair ? 2 : 1) : 0; f.helper_retire = retirement;
        f.stop_action = AG_SERVICE_PREEMPT; f.stop_after_visits = 1;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
        cpu.x[0] = 8; cpu.x[1] = 16; cpu.x[10] = DEVICE;
        AGServiceResult r = bounded_run(&f, limits(8), &cpu);
        CHECK(r.architectural.steps == (fail ? 3u : 4u) && r.visits == 2);
        CHECK(r.architectural.status == (fail ? AVZ_TP_STATUS_MEMORY_FAULT : AVZ_TP_STATUS_REVALIDATE));
        CHECK(r.stop == AG_SERVICE_STOP_EXECUTOR && r.service_action == AG_SERVICE_PREEMPT);
        CHECK(f.calls == 3 && f.resident_visits == 1);
        CHECK(f.boundaries[1].retired_delta == 3 && f.boundaries[2].retired_delta == !fail);
        CHECK(f.helper_calls == (pair ? 2u : 1u));
        CHECK(cpu.x[10] == DEVICE + (fail ? 0 : pair ? 16 : 8));
        if (pair || !fail) CHECK(f.writes[0] == 9);
        if (pair && !fail) CHECK(f.writes[1] == 17);
        CHECK(r.last_member_base == NEXT);
        finish(&f);
    }
    /* Veto before the helper, including no retired instruction in its member. */
    for (unsigned prefix = 0; prefix <= 3; prefix++) for (unsigned veto = 0; veto < 5; veto++) {
        Fixture f; timed_fixture(&f);
        f.words[1][prefix == 3] = 0xf9400142;
        f.chain = create(&f, 2); CHECK(f.chain);
        if (veto == 0) f.stop_action = AG_SERVICE_IRQ;
        if (veto == 1) f.action = SHARED_PAGE;
        if (veto == 2) f.action = EVENT;
        if (veto == 3) f.action = RETIRE;
        if (veto == 4) f.zero_after_visit = 1;
        AVZNativeCPU cpu = {.pc = prefix < 2 ? NEXT : BASE, .pstate = 5};
        cpu.x[10] = DEVICE;
        AGServiceResult r = bounded_run(&f, limits(8), &cpu);
        uint64_t steps = prefix < 2 ? 0 : prefix;
        CHECK(r.architectural.steps == steps && !f.helper_calls && f.calls == 3);
        CHECK(r.visits == (steps ? steps == 2 ? 1u : 2u : 0u));
        CHECK(r.has_last_member == (steps != 0));
        if (steps) CHECK(r.last_member_base == (steps == 2 ? BASE : NEXT));
        CHECK(f.boundaries[2].retired_delta == 0 && cpu.x[2] == 0);
        if (veto == 0) CHECK(r.service_action == AG_SERVICE_IRQ && r.stop == AG_SERVICE_STOP_CALLBACK);
        if (veto == 4) CHECK(r.stop == AG_SERVICE_STOP_ALLOWANCE);
        finish(&f);
    }
    Fixture f; timed_fixture(&f); f.words[0][0] = 0xf9400140;
    f.chain = create(&f, 1); CHECK(f.chain); f.fail_at = 1;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[10] = DEVICE;
    AGServiceResult r = bounded_run(&f, limits(8), &cpu);
    CHECK(!r.architectural.steps && r.visits == 1 && r.last_member_base == BASE);
    CHECK(r.architectural.status == AVZ_TP_STATUS_MEMORY_FAULT && f.helper_calls == 1);
    CHECK(f.boundaries[1].visits == 0 && f.boundaries[2].visits == 1);
    finish(&f);
    for (unsigned late = 0; late < 2; late++) {
        timed_fixture(&f); f.words[0][0] = 0xf9400140;
        f.chain = create(&f, 1); CHECK(f.chain); f.deadline = late;
        cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5}; cpu.x[10] = DEVICE;
        r = ag_service_chain_run_bounded(f.chain, limits(8), &cpu, changing_veto, &f);
        CHECK(r.stop == AG_SERVICE_STOP_CALLBACK && r.service_action == AG_SERVICE_IRQ);
        CHECK(!r.architectural.steps && !r.visits && !f.helper_calls && f.calls == 3);
        finish(&f);
    }
    puts("PASS pre-helper time, veto/no replay, fault precedence, partial pair stores, pins and residual charge");
}

static void bounded_zero_entries(void) {
    Fixture f; init(&f); f.chain = create(&f, 2); CHECK(f.chain);
    for (unsigned zero = 0; zero < 4; zero++) {
        AGServiceLimits l = limits(8);
        if (zero == 0) l.steps = 0;
        if (zero == 1) l.checkpoint_steps = 0;
        if (zero == 2) l.visits = 0;
        if (zero == 3) l.checkpoint_visits = 0;
        AVZNativeCPU cpu = {.pc = BASE};
        AGServiceResult r = bounded_run(&f, l, &cpu);
        CHECK(r.stop == AG_SERVICE_STOP_INVALID && !r.visits && !f.calls);
    }
    AVZNativeCPU cpu = {.pc = BASE, .halted = 1};
    AGServiceResult r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.architectural.status == AVZ_NATIVE_STATUS_HALTED && !f.calls);
    cpu.halted = 0; f.cap = 0;
    r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.stop == AG_SERVICE_STOP_ALLOWANCE && !r.visits && f.calls == 1);
    f.cap = UINT64_MAX; cpu.pc = DATA;
    r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.stop == AG_SERVICE_STOP_OUTSIDE && !r.visits && f.calls == 1);
    cpu.pc = BASE; atomic_store(&f.events, 1);
    r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.stop == AG_SERVICE_STOP_EVENT && !r.visits && f.calls == 1);
    atomic_store(&f.events, 0); f.serial[1]++;
    r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.stop == AG_SERVICE_STOP_PROOF && !r.visits && !f.calls);
    finish(&f);
    puts("PASS zero limits, halt, zero allowance, outside/event/proof rejection");
}

#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
extern void ag_bounded_boundary(void);
/* Deliberately bypass C validation to prove the assembly gate checks every
 * token, including an unrelated member's page before any global epoch moves. */
static void bounded_gate_proofs(void) {
    uint32_t words[] = {0x91000400, 0x17ffffff};
    AGProgram *p = ag_create(words, 2, BASE); CHECK(p);
    uint64_t serial[8], local[8];
    _Atomic uint64_t shared[8], event = 0;
    AGBoundedProof proofs[8];
    for (unsigned i = 0; i < 8; i++) {
        serial[i] = local[i] = 1; atomic_init(&shared[i], 1);
        proofs[i] = (AGBoundedProof){&serial[i], 1, &local[i], 1, &shared[i], 1};
    }
    AGOperation gate = {.handler = ag_bounded_boundary, .immediate = 0,
        .taken = &p->operations[0]};
    p->operations[1].taken = &gate;
    for (unsigned member = 0; member < 8; member++) for (unsigned kind = 0; kind < 3; kind++) {
        if (kind == 0) serial[member]++;
        if (kind == 1) local[member]++;
        if (kind == 2) atomic_fetch_add(&shared[member], 1);
        AVZNativeCPU cpu = {.pc = BASE};
        AGBoundedControl c = {.chain = {.events = &event, .remaining = 8},
            .proofs = proofs, .count = 8};
        AGRun r = {.cpu = &cpu, .operation = &gate, .budget = 13, .chain = &c.chain};
        CHECK(!ag_abi_probe(&r));
        CHECK(r.result.status == AVZ_TP_STATUS_REVALIDATE && !r.result.steps);
        CHECK(!c.chain.entries && !cpu.x[0] && cpu.pc == BASE);
        serial[member] = local[member] = 1; atomic_store(&shared[member], 1);
    }
    for (unsigned kind = 0; kind < 3; kind++) {
        AVZNativeCPU cpu = {.pc = BASE};
        AGBoundedControl c = {.chain = {.events = &event, .remaining = kind == 1 ? 0 : 8},
            .proofs = proofs, .count = 8};
        atomic_store(&event, kind == 2);
        AGRun r = {.cpu = &cpu, .operation = &gate, .budget = 13, .chain = &c.chain};
        CHECK(!ag_abi_probe(&r));
        CHECK(r.result.steps == (kind == 0 ? 13u : 0u));
        CHECK(c.chain.entries == (kind == 0 ? 7u : 0u));
        if (!kind) CHECK(c.last_member == 0 && c.member_start == 12 && cpu.x[0] == 7);
    }
    ag_destroy(p);
    puts("PASS assembly-only all-eight-member serial/local/shared proofs, page-before-global and ABI");
}
#endif

static int bounded_graph_validator(void *opaque) {
    ((Fixture *)opaque)->validation_calls++;
    return 1;
}
static void bounded_maximum_graph(void) {
    Fixture f; init(&f);
    AGServiceBlock blocks[8]; uint32_t words[8][16];
    for (unsigned i = 0; i < 8; i++) {
        for (unsigned j = 0; j < 15; j++) words[i][j] = 0x91000400;
        uint64_t base = BASE + i * 4096;
        words[i][15] = branch(base + 60, BASE + ((i + 1) % 8) * 4096);
        blocks[i] = f.blocks[0]; blocks[i].base = base;
        blocks[i].words = words[i]; blocks[i].count = 16;
    }
#if defined(AG_BOUNDED_ALLOC_TEST) && AG_BOUNDED_ALLOC_TEST
    bounded_alloc_failure = 0;
    size_t allocations = bounded_alloc_calls;
#endif
    f.chain = ag_service_chain_create_graph(blocks, 8, &f.proof, NULL, bounded_graph_validator, &f);
    CHECK(f.chain && ag_service_chain_bytes(f.chain) == 20776);
    CHECK(ag_service_chain_bytes(f.chain) <= AG_SERVICE_MAX_BYTES);
#if defined(AG_BOUNDED_ALLOC_TEST) && AG_BOUNDED_ALLOC_TEST
    CHECK(bounded_alloc_calls == allocations);
    for (long failure = 0; failure < 8; failure++) {
        bounded_alloc_failure = failure;
        allocations = bounded_alloc_calls;
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}, before = cpu;
        AGServiceResult r = bounded_run(&f, limits(256), &cpu);
        CHECK(r.stop == AG_SERVICE_STOP_PREPARATION && r.architectural.status == AVZ_TP_STATUS_REVALIDATE);
        CHECK(!r.visits && !r.architectural.steps && !f.calls && !memcmp(&cpu, &before, sizeof(cpu)));
        CHECK(ag_service_chain_bytes(f.chain) == 20776);
        CHECK(bounded_alloc_calls == allocations + (size_t)failure + 1);
        allocations = bounded_alloc_calls;
        r = run(&f, limits(64), &cpu);
        CHECK(r.architectural.steps == 64 && r.visits == 4 && f.calls == 5);
        CHECK(bounded_alloc_calls == allocations && ag_service_chain_bytes(f.chain) == 20776);
    }
    bounded_alloc_failure = -1;
#endif
    unsigned validations = f.validation_calls;
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5};
    AGServiceResult r = bounded_run(&f, limits(256), &cpu);
    CHECK(r.architectural.steps == 256 && r.visits == 16 && cpu.x[0] == 240);
    CHECK(r.last_member_base == BASE + 7 * 4096 && f.calls == 2);
    CHECK(f.validation_calls == validations + 3);
    CHECK(ag_service_chain_bytes(f.chain) == 27624);
#if defined(AG_BOUNDED_ALLOC_TEST) && AG_BOUNDED_ALLOC_TEST
    allocations = bounded_alloc_calls;
    bounded_alloc_failure = 0;
    cpu = (AVZNativeCPU){.pc = BASE, .pstate = 5};
    r = bounded_run(&f, limits(256), &cpu);
    CHECK(r.architectural.steps == 256 && r.visits == 16 && bounded_alloc_calls == allocations);
    bounded_alloc_failure = -1;
#endif
    finish(&f);
    puts("PASS lazy maximum graph size, eight allocation-failure rollbacks, generic survival, retry and allocation-free reuse");
}

static void bounded_hot_memory(void) {
    const uint32_t ops[] = {0xf9400142, 0xf9000140, 0xf86b6942, 0xf82b6940,
        0xf8400542, 0xf8000540, 0xa9400d42, 0xa9000540};
    for (unsigned i = 0; i < sizeof(ops) / sizeof(*ops); i++) {
        Fixture f; init(&f);
        CHECK(avz_native_fast_memory_write(f.memory, DATA, 8, 19));
        uint64_t value; CHECK(avz_native_fast_memory_read(f.memory, DATA, 8, &value));
        f.words[0][0] = ops[i]; f.words[1][0] = ops[i];
        f.chain = create(&f, 2); CHECK(f.chain);
        AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[10] = DATA; cpu.x[0] = 23;
        AGServiceResult r = bounded_run(&f, limits(17), &cpu);
        CHECK(r.architectural.steps == 17 && r.visits == 9 && f.calls == 2);
        CHECK(!f.resident_visits && !f.helper_calls && cpu.x[10] == DATA);
        CHECK(r.stop == AG_SERVICE_STOP_STEPS);
        finish(&f);
    }
    Fixture f; init(&f);
    CHECK(avz_native_fast_memory_write(f.memory, DATA, 8, 19));
    avz_guest_memory_mark_code_page(f.ram, DATA, 0);
    f.words[0][1] = 0xf8008540;
    f.chain = create(&f, 1); CHECK(f.chain);
    AVZNativeCPU cpu = {.pc = BASE, .pstate = 5}; cpu.x[0] = 23; cpu.x[10] = DATA;
    AGServiceResult r = bounded_run(&f, limits(8), &cpu);
    CHECK(r.architectural.steps == 2 && r.stop == AG_SERVICE_STOP_EXECUTOR);
    CHECK(r.architectural.status == AVZ_TP_STATUS_REVALIDATE && f.calls == 3);
    CHECK(cpu.pc == BASE + 8 && cpu.x[10] == DATA + 8);
    uint64_t stored; memcpy(&stored, avz_guest_memory_bytes(f.ram) + DATA, sizeof(stored));
    CHECK(stored == 24 && f.boundaries[1].retired_delta == 1 && f.boundaries[2].retired_delta == 1);
    finish(&f);
    puts("PASS hot scalar/register/writeback/pair memory without service and tracked-store terminal publication");
}

int main(void) {
#if !defined(AG_SERVICE_CHAIN_ENABLE) || !AG_SERVICE_CHAIN_ENABLE
    const int disabled = 1;
#else
    const int disabled = !ag_available();
#endif
    if (disabled) {
        AGServiceResult r = ag_service_chain_run_bounded(NULL, limits(1), NULL, NULL, NULL);
        CHECK(r.stop == AG_SERVICE_STOP_DISABLED && r.architectural.status == AVZ_TP_STATUS_DISABLED);
        return generic_service_test_main();
    }
    bounded_budgets(); bounded_targets(); bounded_helpers(); bounded_zero_entries();
#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
    bounded_gate_proofs();
#endif
    bounded_maximum_graph(); bounded_hot_memory();
    puts("PASS isolated bounded service runtime correctness");
    return 0;
}
