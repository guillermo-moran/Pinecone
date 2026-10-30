#include "gadget_internal.h"
#include <stdlib.h>

extern void ag_boundary(void);
extern void ag_outside(void);
extern void ag_indirect(void);
extern void ag_indirect_link(void);

typedef struct {
    AGProgram *program;
    AGOperation *gates;
    const _Atomic uint64_t *generation;
    uint64_t expected;
} AGChainBlock;
struct AGChain {
    AGGuards proof;
    AGChainStats *stats;
    size_t count, bytes;
    unsigned active, retired, proof_valid;
    AGOperation outside;
    AGTargetRange *targets;
    AGChainBlock blocks[];
};
#define COUNT(c, field, amount) do { if ((c)->stats) (c)->stats->field += (amount); } while (0)

static AGOperation *entry(AGChain *c, uint64_t pc) {
    size_t low = 0, high = c->count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        AGChainBlock *b = &c->blocks[mid];
        AGProgram *p = b->program;
        if (pc < p->targets.base) high = mid;
        else if (pc - p->targets.base >= p->targets.count * 4) low = mid + 1;
        else return (pc & 3) ? NULL : &b->gates[(pc - p->targets.base) / 4];
    }
    return NULL;
}
static void reclaim(AGChain *c) {
    for (size_t i = 0; i < c->count; i++) {
        ag_destroy(c->blocks[i].program);
        free(c->blocks[i].gates);
    }
    COUNT(c, reclamations, 1);
    free(c->targets); free(c);
}
AGChain *ag_chain_create(const AGBlock *blocks, size_t count,
    const AGGuards *proof, AGChainStats *stats) {
    if (!ag_available() || !blocks || !count || count > 256 || !proof ||
        !proof->shared[0] || !proof->shared[1]) return NULL;
    uint64_t end = 0;
    for (size_t i = 0; i < count; i++) {
        const AGBlock *b = &blocks[i];
        if (!b->words || !b->code_generation || !b->count || b->count > 16 ||
            (b->base & 3) || b->count > (UINT64_MAX - b->base) / 4 ||
            (i && b->base < end) ||
            (b->base >> 12) != ((b->base + (b->count - 1) * 4) >> 12)) return NULL;
        end = b->base + b->count * 4;
    }
    AGChain *c = calloc(1, sizeof(*c) + count * sizeof(AGChainBlock));
    if (!c) return NULL;
    c->proof = *proof; c->count = count;
    c->targets = calloc(count, sizeof(*c->targets));
    if (!c->targets) { reclaim(c); return NULL; }
    c->outside.handler = ag_outside;
    c->bytes = sizeof(*c) + count * (sizeof(AGChainBlock) + sizeof(AGTargetRange));
    for (size_t i = 0; i < count; i++) {
        AGChainBlock *b = &c->blocks[i];
        b->program = ag_create(blocks[i].words, blocks[i].count, blocks[i].base);
        b->gates = calloc(blocks[i].count, sizeof(*b->gates));
        b->generation = blocks[i].code_generation;
        b->expected = blocks[i].expected_generation;
        if (!b->program || !b->gates) { reclaim(c); return NULL; }
        c->targets[i] = (AGTargetRange){blocks[i].base, blocks[i].count, b->gates};
        c->bytes += ag_program_bytes(b->program) + blocks[i].count * sizeof(*b->gates);
        for (size_t j = 0; j < blocks[i].count; j++) {
            AGOperation *op = &b->program->operations[j];
            if ((op->taken || op->handler == ag_indirect || op->handler == ag_indirect_link) &&
                j + 1 != blocks[i].count) {
                reclaim(c); return NULL;
            }
            b->gates[j].handler = ag_boundary;
            b->gates[j].taken = &b->program->operations[j];
        }
    }
    for (size_t i = 0; i < count; i++) {
        AGProgram *p = c->blocks[i].program;
        for (size_t j = 0; j < p->targets.count; j++) {
            AGOperation *op = &p->operations[j];
            if (op->taken) {
                AGOperation *target = entry(c, op->immediate);
                // Unlinked branches must exit, not fall through to an adjacent block.
                op->taken = target ? target : &c->outside;
            }
        }
        AGOperation *next = entry(c, p->targets.base + p->targets.count * 4);
        if (next) p->operations[p->targets.count] = *next;
    }
    c->stats = stats;
    return c;
}
void ag_chain_destroy(AGChain *c) {
    if (!c || c->retired) return;
    c->retired = 1; COUNT(c, retirements, 1);
    if (!c->active) reclaim(c);
}
size_t ag_chain_bytes(const AGChain *c) { return c ? c->bytes : 0; }
static int context_current(const AGGuards *p) {
    if (p->local && *p->local != p->expected[0]) return 0;
    for (unsigned i = 1; i < 3; i++)
        if (p->shared[i] && atomic_load_explicit(p->shared[i], memory_order_acquire) != p->expected[i + 1]) return 0;
    return 1;
}
static int validate(AGChain *c) {
    if (!context_current(&c->proof)) return 0;
    uint64_t code = atomic_load_explicit(c->proof.shared[0], memory_order_acquire);
    if (c->proof_valid && code == c->proof.expected[1]) COUNT(c, proof_hits, 1);
    else {
        COUNT(c, proof_scans, 1);
        for (size_t i = 0; i < c->count; i++) {
            COUNT(c, page_checks, 1);
            if (atomic_load_explicit(c->blocks[i].generation, memory_order_acquire) != c->blocks[i].expected) return 0;
        }
    }
    if (!context_current(&c->proof) ||
        atomic_load_explicit(c->proof.shared[0], memory_order_acquire) != code) return 0;
    c->proof.expected[1] = code;
    c->proof_valid = 1;
    return 1;
}
AVZNativeBlockResult ag_chain_run(AGChain *c, AGLimits limits,
    AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory) {
    AVZNativeBlockResult r = {0};
    if (!ag_available()) r.status = AVZ_TP_STATUS_DISABLED;
    else if (!c || !cpu || !limits.steps || !limits.service_steps || !limits.blocks || c->active)
        r.status = AVZ_TP_STATUS_INVALID_ARGUMENT;
    else if (cpu->halted) r.status = AVZ_NATIVE_STATUS_HALTED;
    else if (c->retired) r.status = AVZ_TP_STATUS_REVALIDATE;
    else {
        c->active = 1;
        COUNT(c, entries, 1);
        if (!validate(c)) r.status = AVZ_TP_STATUS_REVALIDATE;
        else {
            AGOperation *start = entry(c, cpu->pc);
            if (!start) r.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            else {
                AGChainControl control = {.events = limits.events, .remaining = limits.blocks};
                uint64_t allowance = limits.steps < limits.service_steps ? limits.steps : limits.service_steps;
                AGRun run = {.cpu = cpu, .operation = start, .budget = allowance,
                    .guards = c->proof, .chain = &control,
                    .targets = c->targets, .target_count = c->count};
                ag_memory_prepare(&run.memory, memory);
                if (run.memory.shared && run.memory.translation_epoch != run.memory.observed_translation)
                    run.result.status = AVZ_TP_STATUS_REVALIDATE;
                else {
                    // The RAM view already checks these tokens every instruction.
                    // Reuse that proof only when both identity AND captured value
                    // match; a newer memory snapshot cannot bless older code.
                    if (run.memory.shared) {
                        if (run.guards.shared[0] == &run.memory.shared->code_mutation_epoch &&
                            run.guards.expected[1] == run.memory.code_epoch) run.guards.shared[0] = NULL;
                        if (run.guards.shared[1] == &run.memory.shared->translation_epoch &&
                            run.guards.expected[2] == run.memory.translation_epoch) run.guards.shared[1] = NULL;
                    }
                    ag_enter(&run);
                }
                r = run.result;
                if (r.status == AVZ_NATIVE_STATUS_MAX_STEPS && limits.service_steps <= limits.steps)
                    r.status = AVZ_NATIVE_STATUS_YIELDED;
                COUNT(c, block_entries, control.entries);
                COUNT(c, polls, control.polls);
            }
        }
        if (r.status == AVZ_TP_STATUS_REVALIDATE) COUNT(c, revalidations, 1);
        if (r.status == AVZ_NATIVE_STATUS_YIELDED) COUNT(c, yields, 1);
        c->active = 0;
        if (c->retired) reclaim(c);
    }
    return r;
}
