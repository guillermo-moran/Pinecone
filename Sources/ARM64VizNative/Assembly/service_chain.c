#include "service_chain.h"
#include "gadget_internal.h"
#include "boundary_profile.h"
#include <stdlib.h>
#include <string.h>

#if defined(AG_BOUNDARY_PROFILE) && AG_BOUNDARY_PROFILE
_Thread_local AGBoundaryProfile ag_boundary_profile;
#endif

#if defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE && \
    defined(AG_ENABLE) && AG_ENABLE && defined(__APPLE__) && \
    defined(__aarch64__) && !defined(__arm64e__)
extern void ag_service_boundary(void);
extern void ag_outside(void);
extern void ag_bounded_boundary(void);
extern const AGHandler ag_bounded_memory_map[][2];
extern const AGHandler ag_bounded_memory_map_end[][2];
typedef struct {
    AGServiceBlock proof;
    AGProgram *program;
    AGOperation gates[16];
    AGProgram *bounded_program;
    AGOperation bounded_gates[16];
} AGServiceMember;
struct AGServiceChain {
    AGGuards proof;
    AVZNativeMemoryFastPath *memory;
    AGServiceValidate validate;
    AGServiceValidateGraph validate_graph;
    void *owner;
    size_t count, bytes;
    unsigned active, retired;
    AGOperation outside;
    AGTargetRange targets[AG_SERVICE_MAX_MEMBERS];
    AGTargetRange bounded_targets[AG_SERVICE_MAX_MEMBERS];
    AGBoundedProof bounded_proofs[AG_SERVICE_MAX_MEMBERS];
    AGServiceMember members[AG_SERVICE_MAX_MEMBERS];
};
_Static_assert(sizeof(AGServiceChain) + 2 * AG_SERVICE_MAX_MEMBERS *
    (sizeof(AGProgram) + 17 * sizeof(AGOperation)) <= AG_SERVICE_MAX_BYTES,
    "maximum generic plus bounded graph must fit allocation cap");

static size_t member_at(const AGServiceChain *c, uint64_t pc) {
    if (!(pc & 3)) for (size_t i = 0; i < c->count; i++) {
        const AGServiceBlock *b = &c->members[i].proof;
        if (pc >= b->base && pc - b->base < b->count * 4) return i;
    }
    return c->count;
}

static const AGOperation *gate_at(const AGServiceChain *c, uint64_t pc) {
    size_t i = member_at(c, pc);
    return i == c->count ? &c->outside :
        &c->members[i].gates[(pc - c->members[i].proof.base) / 4];
}

static const AGOperation *bounded_gate_at(const AGServiceChain *c, uint64_t pc) {
    size_t i = member_at(c, pc);
    return i == c->count ? &c->outside :
        &c->members[i].bounded_gates[(pc - c->members[i].proof.base) / 4];
}

static int proofs_current(const AGServiceChain *c) {
    if (c->retired || *c->proof.local != c->proof.expected[0]) return 0;
    for (unsigned i = 0; i < 3; i++)
        if (c->proof.shared[i] && atomic_load_explicit(c->proof.shared[i],
            memory_order_acquire) != c->proof.expected[i + 1]) return 0;
    for (size_t i = 0; i < c->count; i++) {
        const AGServiceBlock *b = &c->members[i].proof;
        if (*b->serial != b->expected_serial ||
            (b->local_generation && *b->local_generation != b->expected_local_generation) ||
            (b->shared_generation && atomic_load_explicit(b->shared_generation,
                memory_order_acquire) != b->expected_shared_generation)) return 0;
    }
    return 1;
}

static int validate(AGServiceChain *c) {
    if (!proofs_current(c)) return 0;
    if (c->validate_graph) {
        if (!c->validate_graph(c->owner) || c->retired) return 0;
    } else for (size_t i = 0; i < c->count; i++) {
        const AGServiceBlock *b = &c->members[i].proof;
        if (!c->validate(c->owner, b->base, b->count, b->expected_serial) ||
            c->retired) return 0;
    }
    return proofs_current(c);
}

static void reclaim(AGServiceChain *c) {
    for (size_t i = 0; i < c->count; i++) {
        ag_destroy(c->members[i].program);
        ag_destroy(c->members[i].bounded_program);
    }
    free(c);
}

/* Owner-only, inactive, transactional preparation. Generic execution never
 * depends on these allocations. Clone decoded copies without fetching code. */
static int prepare_bounded(AGServiceChain *c) {
    if (c->members[0].bounded_program) return 1;
    AGProgram *copies[AG_SERVICE_MAX_MEMBERS] = {0};
    size_t bytes = c->bytes;
    for (size_t i = 0; i < c->count; i++) {
        size_t size = ag_program_bytes(c->members[i].program);
        if (size > AG_SERVICE_MAX_BYTES - bytes || !(copies[i] = malloc(size))) {
            for (size_t j = 0; j < i; j++) free(copies[j]);
            return 0;
        }
        memcpy(copies[i], c->members[i].program, size);
        copies[i]->targets.entries = copies[i]->operations;
        copies[i]->active_runs = copies[i]->retired = 0;
        bytes += size;
    }
    for (size_t i = 0; i < c->count; i++) {
        AGServiceMember *m = &c->members[i];
        const AGServiceBlock *b = &m->proof;
        m->bounded_program = copies[i];
        c->bounded_targets[i] = (AGTargetRange){b->base, b->count, m->bounded_gates};
        c->bounded_proofs[i] = (AGBoundedProof){b->serial, b->expected_serial,
            b->local_generation, b->expected_local_generation,
            b->shared_generation, b->expected_shared_generation};
        for (size_t j = 0; j < b->count; j++) {
            m->bounded_gates[j] = (AGOperation){.handler = ag_bounded_boundary,
                .next_pc = b->base + j * 4, .immediate = i, .taken = &copies[i]->operations[j]};
            AGOperation *op = &copies[i]->operations[j];
            for (const AGHandler (*map)[2] = ag_bounded_memory_map;
                map != ag_bounded_memory_map_end; map++) {
                if (op->handler == (*map)[0]) { op->handler = (*map)[1]; break; }
            }
            if (op->taken) op->taken = bounded_gate_at(c, op->immediate);
        }
    }
    /* Fallthrough sentinels copy gates, so every gate must be initialized. */
    for (size_t i = 0; i < c->count; i++) {
        AGServiceMember *m = &c->members[i];
        copies[i]->operations[m->proof.count] =
            *bounded_gate_at(c, m->proof.base + m->proof.count * 4);
    }
    c->bytes = bytes;
    return 1;
}

static AGServiceChain *create(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidate validator, AGServiceValidateGraph graph_validator, void *owner) {
    if (!ag_available() || !blocks || !count || count > AG_SERVICE_MAX_MEMBERS ||
        !proof || !proof->local || !proof->shared[0] || !proof->shared[1] ||
        (!validator && !graph_validator))
        return NULL;
    uint64_t end = 0;
    for (size_t i = 0; i < count; i++) {
        const AGServiceBlock *b = &blocks[i];
        if (!b->words || !b->serial || (!b->local_generation && !b->shared_generation) ||
            !b->count || b->count > 16 || (b->base & 3) ||
            b->count > (UINT64_MAX - b->base) / 4 || (i && b->base < end) ||
            (b->base >> 12) != ((b->base + (b->count - 1) * 4) >> 12)) return NULL;
        end = b->base + b->count * 4;
    }
    AGServiceChain *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->proof = *proof; c->memory = memory; c->validate = validator; c->owner = owner;
    c->validate_graph = graph_validator;
    c->count = count; c->bytes = sizeof(*c);
    c->outside.handler = ag_outside;
    for (size_t i = 0; i < count; i++) c->members[i].proof = blocks[i];
    if (!validate(c)) { reclaim(c); return NULL; }
    for (size_t i = 0; i < count; i++) {
        AGServiceMember *m = &c->members[i];
        m->program = ag_create(blocks[i].words, blocks[i].count, blocks[i].base);
        unsigned capability = ag_program_capabilities(m->program);
        if (!capability || (capability == 2 && !memory)) {
            reclaim(c); return NULL;
        }
        c->bytes += ag_program_bytes(m->program);
        if (c->bytes > AG_SERVICE_MAX_BYTES) { reclaim(c); return NULL; }
        c->targets[i] = (AGTargetRange){blocks[i].base, blocks[i].count, m->gates};
        for (size_t j = 0; j < blocks[i].count; j++) {
            m->gates[j] = (AGOperation){.handler = ag_service_boundary,
                .next_pc = blocks[i].base + j * 4, .immediate = i,
                .taken = &m->program->operations[j]};
            AVZNativeInstruction d;
            if (!avz_native_decode_instruction(m->program->operations[j].raw, &d)) {
                reclaim(c); return NULL;
            }
            switch (d.kind) {
            case AVZ_NATIVE_OP_BRANCH: case AVZ_NATIVE_OP_BCOND:
            case AVZ_NATIVE_OP_CBZ: case AVZ_NATIVE_OP_TBZ: case AVZ_NATIVE_OP_REGISTER_BRANCH:
                if (j + 1 != blocks[i].count) { reclaim(c); return NULL; }
                break;
            default: break;
            }
        }
        /* Retain token metadata, not caller-owned instruction storage. */
        m->proof.words = NULL;
    }
    /* Link only these private program copies, including self/suffix targets.
     * Indirect lookup uses the same gates; FIFO-owned programs are untouched. */
    for (size_t i = 0; i < count; i++) {
        AGServiceMember *m = &c->members[i];
        for (size_t j = 0; j < m->proof.count; j++) {
            AGOperation *op = &m->program->operations[j];
            if (op->taken) op->taken = gate_at(c, op->immediate);
        }
        m->program->operations[m->proof.count] =
            *gate_at(c, m->proof.base + m->proof.count * 4);
    }
    if (!validate(c)) { reclaim(c); return NULL; }
    return c;
}

AGServiceChain *ag_service_chain_create(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidate validator, void *owner) {
    return create(blocks, count, proof, memory, validator, NULL, owner);
}
AGServiceChain *ag_service_chain_create_graph(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidateGraph validator, void *owner) {
    return create(blocks, count, proof, memory, NULL, validator, owner);
}

void ag_service_chain_destroy(AGServiceChain *c) {
    if (!c || c->retired) return;
    c->retired = 1;
    if (!c->active) reclaim(c);
}
size_t ag_service_chain_bytes(const AGServiceChain *c) { return c ? c->bytes : 0; }

static uint64_t minimum(uint64_t a, uint64_t b) { return a < b ? a : b; }
static void stop(AGServiceResult *r, uint32_t status, AGServiceStop reason) {
    r->architectural.status = status;
    r->stop = reason;
}

typedef struct {
    AGRun run;
    AGChainControl control;
    AGServiceChain *chain;
    AGServiceLimits limits;
    AGServiceCallback service;
    void *owner;
    AGServiceResult result;
    size_t member;
    unsigned initial, finished;
} AGServiceRun;
_Static_assert(offsetof(AGServiceRun, run) == 0, "resident run prefix");

/* Called initially from C, at ordinary visit boundaries from the resident
 * veneer, and once from C after a terminal assembly exit. No saved target is
 * dereferenced until the callback and whole-graph validation have completed. */
static int service_boundary(AGRun *run) {
    AGServiceRun *s = (AGServiceRun *)run;
    AGServiceChain *c = s->chain;
    AGServiceResult *r = &s->result;
    AGServiceLimits limits = s->limits;
    AVZNativeCPU *cpu = run->cpu;
    for (;;) {
        ag_profile_begin();
        AGServiceBoundary boundary = {.status = AVZ_NATIVE_STATUS_MAX_STEPS,
            .initial = s->initial};
        if (!s->initial) {
            AVZNativeBlockResult part = run->result;
            r->architectural.steps += part.steps;
            r->architectural.generic_dispatches += part.generic_dispatches;
            r->architectural.unsupported_instruction = part.unsupported_instruction;
            /* A rejected assembly entry is not a visit; a first-op fault is. */
            if (part.steps || part.status == AVZ_TP_STATUS_MEMORY_FAULT ||
                part.status == AVZ_NATIVE_STATUS_UNSUPPORTED) {
                const AGServiceBlock *b = &c->members[s->member].proof;
                r->visits++;
                r->has_last_member = 1;
                r->last_member_base = b->base;
                r->last_member_serial = b->expected_serial;
            }
            boundary = (AGServiceBoundary){.retired_delta = part.steps,
                .total_steps = r->architectural.steps, .visits = r->visits,
                .status = part.status};
        }
        s->initial = 0;
        ag_profile_mark(AG_PROFILE_ACCOUNTING);
        AGServiceDecision decision = s->service(s->owner, &boundary, cpu);
        ag_profile_mark(AG_PROFILE_CALLBACK);
        r->timer_accounted_steps += boundary.retired_delta;
        r->service_action = decision.action;
        if (!boundary.initial && boundary.status != AVZ_NATIVE_STATUS_MAX_STEPS &&
            boundary.status != AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
            stop(r, boundary.status, AG_SERVICE_STOP_EXECUTOR); break;
        }
        int valid = validate(c);
        ag_profile_mark(AG_PROFILE_VALIDATION);
        if (!valid) {
            stop(r, AVZ_TP_STATUS_REVALIDATE, AG_SERVICE_STOP_PROOF); break;
        }
        if (decision.action < AG_SERVICE_CONTINUE || decision.action > AG_SERVICE_REVALIDATE) {
            stop(r, AVZ_TP_STATUS_INVALID_ARGUMENT, AG_SERVICE_STOP_INVALID); break;
        }
        if (decision.action != AG_SERVICE_CONTINUE) {
            stop(r, decision.action == AG_SERVICE_REVALIDATE ? AVZ_TP_STATUS_REVALIDATE :
                AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_CALLBACK); break;
        }
        if (limits.events && atomic_load_explicit(limits.events, memory_order_acquire)) {
            stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_EVENT); break;
        }
        if (r->architectural.steps == limits.steps) {
            stop(r, AVZ_NATIVE_STATUS_MAX_STEPS, AG_SERVICE_STOP_STEPS); break;
        }
        if (r->architectural.steps == limits.checkpoint_steps || r->visits == limits.checkpoint_visits) {
            stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_CHECKPOINT); break;
        }
        if (r->visits == limits.visits) {
            stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_VISITS); break;
        }
        if (!decision.next_steps) {
            stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_ALLOWANCE); break;
        }
        const AGOperation *next = run->operation;
        size_t index = next && next->handler == ag_service_boundary && next->next_pc == cpu->pc ?
            next->immediate : member_at(c, cpu->pc);
        if (index == c->count) {
            stop(r, AVZ_NATIVE_STATUS_OUTSIDE_BLOCK, AG_SERVICE_STOP_OUTSIDE); break;
        }
        AGServiceMember *m = &c->members[index];
        uint64_t allowance = minimum(limits.steps - r->architectural.steps,
            limits.checkpoint_steps - r->architectural.steps);
        allowance = minimum(allowance, decision.next_steps);
        allowance = minimum(allowance, m->proof.count - (cpu->pc - m->proof.base) / 4);
        s->member = index;
        run->operation = m->gates[(cpu->pc - m->proof.base) / 4].taken;
        run->budget = allowance;
        run->result = (AVZNativeBlockResult){0};
        ag_profile_mark(AG_PROFILE_SELECTION);
        ag_memory_prepare_inline(&run->memory, c->memory);
        ag_profile_mark(AG_PROFILE_MEMORY);
        ag_profile_end();
        if (!run->memory.shared || run->memory.translation_epoch == run->memory.observed_translation)
            return 1;
        /* Match the old per-entry rejection and its zero-delta final service. */
        run->result.status = AVZ_TP_STATUS_REVALIDATE;
    }
    ag_profile_end();
    s->finished = 1;
    return 0;
}

AGServiceResult ag_service_chain_run(AGServiceChain *c, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner) {
    AGServiceRun s = {.chain = c, .limits = limits, .service = service,
        .owner = owner, .initial = 1, .run.cpu = cpu,
        .control.service = service_boundary};
    if (!ag_available()) {
        stop(&s.result, AVZ_TP_STATUS_DISABLED, AG_SERVICE_STOP_DISABLED); return s.result;
    }
    if (!c || !cpu || !service || !limits.steps || !limits.checkpoint_steps ||
        !limits.visits || !limits.checkpoint_visits || c->active) {
        stop(&s.result, AVZ_TP_STATUS_INVALID_ARGUMENT, AG_SERVICE_STOP_INVALID); return s.result;
    }
    if (cpu->halted) {
        stop(&s.result, AVZ_NATIVE_STATUS_HALTED, AG_SERVICE_STOP_EXECUTOR); return s.result;
    }
    c->active = 1;
    if (!validate(c)) stop(&s.result, AVZ_TP_STATUS_REVALIDATE, AG_SERVICE_STOP_PROOF);
    else {
        s.run.guards = c->proof;
        s.run.targets = c->targets;
        s.run.target_count = c->count;
        s.run.chain = &s.control;
        if (service_boundary(&s.run)) {
            ag_enter(&s.run);
            /* Terminal memory helpers and guard failures never resume. Charge
             * their residual prefix exactly once after leaving assembly. */
            if (!s.finished) service_boundary(&s.run);
        }
    }
    c->active = 0;
    if (c->retired) reclaim(c);
    return s.result;
}

typedef struct {
    AGRun run;
    AGBoundedControl control;
    AGServiceChain *chain;
    AGServiceLimits limits;
    AGServiceCallback service;
    void *owner;
    AGServiceResult result;
} AGBoundedRun;
_Static_assert(offsetof(AGBoundedRun, run) == 0, "bounded resident run prefix");

static void bounded_snapshot(AGBoundedRun *s) {
    AGServiceResult *r = &s->result;
    r->architectural = s->run.result;
    r->visits = s->control.chain.entries;
    uint64_t last = s->control.last_member;
    /* A gate is provisional until an instruction retires or faults. In
     * particular, pre-helper IRQ rejection must not invent a zero-step visit. */
    if (r->visits && s->control.member_start == r->architectural.steps &&
        r->architectural.status != AVZ_TP_STATUS_MEMORY_FAULT &&
        r->architectural.status != AVZ_NATIVE_STATUS_UNSUPPORTED) {
        r->visits--;
        last = s->control.previous_member;
    }
    r->has_last_member = r->visits != 0;
    if (r->has_last_member) {
        const AGServiceBlock *b = &s->chain->members[last].proof;
        r->last_member_base = b->base;
        r->last_member_serial = b->expected_serial;
    } else r->last_member_base = r->last_member_serial = 0;
}

/* Service always sees cumulative CPU state, but charges only the residual.
 * Validation is unconditional even for terminal faults; its result must not
 * mask their architectural precedence. */
static AGServiceDecision bounded_service(AGBoundedRun *s, unsigned initial, int *valid) {
    bounded_snapshot(s);
    AGServiceResult *r = &s->result;
    AGServiceBoundary b = {.retired_delta = r->architectural.steps - r->timer_accounted_steps,
        .total_steps = r->architectural.steps, .visits = r->visits,
        .status = r->architectural.status, .initial = initial};
    AGServiceDecision d = s->service(s->owner, &b, s->run.cpu);
    r->timer_accounted_steps += b.retired_delta;
    r->service_action = d.action;
    *valid = validate(s->chain);
    return d;
}

static int bounded_decision(AGBoundedRun *s, AGServiceDecision d, int valid) {
    AGServiceResult *r = &s->result;
    if (!valid) stop(r, AVZ_TP_STATUS_REVALIDATE, AG_SERVICE_STOP_PROOF);
    else if (d.action < AG_SERVICE_CONTINUE || d.action > AG_SERVICE_REVALIDATE)
        stop(r, AVZ_TP_STATUS_INVALID_ARGUMENT, AG_SERVICE_STOP_INVALID);
    else if (d.action != AG_SERVICE_CONTINUE)
        stop(r, d.action == AG_SERVICE_REVALIDATE ? AVZ_TP_STATUS_REVALIDATE :
            AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_CALLBACK);
    else if (s->limits.events && atomic_load_explicit(s->limits.events, memory_order_acquire))
        stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_EVENT);
    else if (!d.next_steps) stop(r, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_ALLOWANCE);
    else return 1;
    return 0;
}

/* Only the bounded memory variants call this. The instruction has not yet
 * performed any access or writeback, so service may veto it without replay. */
int ag_bounded_before_helper(AGRun *run) {
    AGBoundedRun *s = (AGBoundedRun *)run;
    int valid;
    AGServiceDecision d = bounded_service(s, 0, &valid);
    if (!bounded_decision(s, d, valid)) {
        run->result.status = s->result.architectural.status;
        return 0;
    }
    s->control.terminal = 1;
    return 1;
}

AGServiceResult ag_service_chain_run_bounded(AGServiceChain *c, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner) {
    AGBoundedRun s = {.chain = c, .limits = limits, .service = service, .owner = owner,
        .run = {.cpu = cpu, .result.status = AVZ_NATIVE_STATUS_MAX_STEPS},
        .control = {.last_member = UINT64_MAX, .previous_member = UINT64_MAX}};
    if (!ag_available()) {
        stop(&s.result, AVZ_TP_STATUS_DISABLED, AG_SERVICE_STOP_DISABLED); return s.result;
    }
    if (!c || !cpu || !service || !limits.steps || !limits.checkpoint_steps ||
        !limits.visits || !limits.checkpoint_visits || c->active) {
        stop(&s.result, AVZ_TP_STATUS_INVALID_ARGUMENT, AG_SERVICE_STOP_INVALID); return s.result;
    }
    if (cpu->halted) {
        stop(&s.result, AVZ_NATIVE_STATUS_HALTED, AG_SERVICE_STOP_EXECUTOR); return s.result;
    }
    if (!prepare_bounded(c)) {
        stop(&s.result, AVZ_TP_STATUS_REVALIDATE, AG_SERVICE_STOP_PREPARATION); return s.result;
    }
    c->active = 1;
    if (!validate(c)) stop(&s.result, AVZ_TP_STATUS_REVALIDATE, AG_SERVICE_STOP_PROOF);
    else {
        int valid;
        AGServiceDecision d = bounded_service(&s, 1, &valid);
        if (bounded_decision(&s, d, valid)) {
            const AGOperation *gate = bounded_gate_at(c, cpu->pc);
            if (gate == &c->outside) stop(&s.result, AVZ_NATIVE_STATUS_OUTSIDE_BLOCK, AG_SERVICE_STOP_OUTSIDE);
            else {
                s.run.guards = c->proof;
                s.run.operation = gate;
                s.run.targets = c->bounded_targets;
                s.run.target_count = c->count;
                s.run.chain = &s.control.chain;
                s.run.budget = minimum(d.next_steps, minimum(limits.steps, limits.checkpoint_steps));
                s.control.chain.events = limits.events;
                s.control.chain.remaining = minimum(limits.visits, limits.checkpoint_visits);
                s.control.proofs = c->bounded_proofs;
                s.control.count = c->count;
                ag_memory_prepare_inline(&s.run.memory, c->memory);
                if (s.run.memory.shared &&
                    s.run.memory.translation_epoch != s.run.memory.observed_translation)
                    s.run.result.status = AVZ_TP_STATUS_REVALIDATE;
                else ag_enter(&s.run);

                /* Preserve a pre-helper veto even if final zero-delta service
                 * returns CONTINUE. No terminal helper is ever resumed. */
                AGServiceStop prior_stop = s.result.stop;
                AGServiceAction prior_action = s.result.service_action;
                uint32_t status = s.run.result.status;
                d = bounded_service(&s, 0, &valid);
                if (s.control.terminal || status == AVZ_TP_STATUS_MEMORY_FAULT ||
                    status == AVZ_NATIVE_STATUS_UNSUPPORTED || status == AVZ_NATIVE_STATUS_HALTED)
                    stop(&s.result, status, AG_SERVICE_STOP_EXECUTOR);
                else if (prior_stop != AG_SERVICE_STOP_NONE) {
                    if (!valid || d.action != AG_SERVICE_CONTINUE)
                        bounded_decision(&s, d, valid);
                    else {
                        stop(&s.result, status, prior_stop);
                        s.result.service_action = prior_action;
                    }
                } else if (status == AVZ_TP_STATUS_REVALIDATE)
                    stop(&s.result, status, AG_SERVICE_STOP_PROOF);
                else if (bounded_decision(&s, (AGServiceDecision){UINT64_MAX, d.action}, valid)) {
                    if (s.result.architectural.steps == limits.steps)
                        stop(&s.result, AVZ_NATIVE_STATUS_MAX_STEPS, AG_SERVICE_STOP_STEPS);
                    else if (s.result.architectural.steps == limits.checkpoint_steps ||
                        s.result.visits == limits.checkpoint_visits)
                        stop(&s.result, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_CHECKPOINT);
                    else if (s.result.visits == limits.visits)
                        stop(&s.result, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_VISITS);
                    else if (s.control.stop == AG_BOUNDED_EVENT)
                        stop(&s.result, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_EVENT);
                    else if (status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK)
                        stop(&s.result, status, AG_SERVICE_STOP_OUTSIDE);
                    else stop(&s.result, AVZ_NATIVE_STATUS_YIELDED, AG_SERVICE_STOP_ALLOWANCE);
                }
            }
        }
    }
    c->active = 0;
    if (c->retired) reclaim(c);
    return s.result;
}
#else
/* Assembly may be linked with service veneers enabled while AG_ENABLE is off.
 * Public runners reject entry, but the cold veneer still needs its symbol. */
int ag_bounded_before_helper(AGRun *run) {
    run->result.status = AVZ_TP_STATUS_DISABLED;
    return 0;
}
AGServiceChain *ag_service_chain_create(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidate validator, void *owner) {
    (void)blocks; (void)count; (void)proof; (void)memory; (void)validator; (void)owner;
    return NULL;
}
void ag_service_chain_destroy(AGServiceChain *c) { (void)c; }
AGServiceChain *ag_service_chain_create_graph(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidateGraph validator, void *owner) {
    (void)blocks; (void)count; (void)proof; (void)memory; (void)validator; (void)owner;
    return NULL;
}
size_t ag_service_chain_bytes(const AGServiceChain *c) { (void)c; return 0; }
AGServiceResult ag_service_chain_run(AGServiceChain *c, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner) {
    (void)c; (void)limits; (void)cpu; (void)service; (void)owner;
    return (AGServiceResult){.architectural.status = AVZ_TP_STATUS_DISABLED,
        .stop = AG_SERVICE_STOP_DISABLED};
}
AGServiceResult ag_service_chain_run_bounded(AGServiceChain *c, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner) {
    return ag_service_chain_run(c, limits, cpu, service, owner);
}
#endif
