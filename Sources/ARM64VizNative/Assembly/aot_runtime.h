#ifndef PINECONE_AOT_RUNTIME_H
#define PINECONE_AOT_RUNTIME_H
#include "gadget_internal.h"

/* Generated functions have an ordinary C ABI and no runtime code allocation.
 * A descriptor is bound only after exact instruction-word comparison. Its
 * count may be a prefix of the full assembly program; never a suffix/gap. */
typedef struct AGAOTBlock {
    const uint32_t *words;
    size_t count;
    void (*run)(AGRun *, uint64_t base);
    uint64_t fingerprint;
    /* Pure-register <=member-prefix only. Entry/all-exit coherence guards,
     * per-instruction budgets; matching the mapped C member validity window.
     * Memory/helper/system translations must leave this NULL unless separately
     * proven. Readable AGRun fields are limited to cpu, budget, result.steps,
     * result.generic_dispatches, result.status, guards, and memory.shared /
     * translation_epoch / code_epoch. Other fields may be uninitialized by
     * minimal pure-span setup. Ordinary assembly entry always uses strict run. */
    void (*run_span)(AGRun *, uint64_t base);
} AGAOTBlock;
struct AGAOTCounters {
    _Alignas(128) _Atomic uint64_t published_runs;
    _Atomic uint64_t published_steps;
    _Atomic uint64_t published_span_runs;
    _Atomic uint64_t published_span_steps;
};
/* Atomic even on an origin-thread shard: an owner-confined program may migrate
 * between host threads over its lifetime, and different programs may share the
 * origin shard. Normal per-vCPU preparation avoids globally contended updates.
 * Inlining removes the old out-of-line statistics call on each tiny block. */
static inline void ag_aot_note_run(struct AGAOTCounters *c, uint64_t retired) {
    if (!c) return;
    atomic_fetch_add_explicit(&c->published_runs, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->published_steps, retired, memory_order_relaxed);
}
/* The mapped C executor aggregates native visits locally and publishes once
 * when its span exits, keeping accounting out of its member-dispatch loop. */
static inline void ag_aot_note_span(struct AGAOTCounters *c, uint64_t runs, uint64_t steps) {
    if (!c || !runs) return;
    atomic_fetch_add_explicit(&c->published_span_runs, runs, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->published_span_steps, steps, memory_order_relaxed);
}
const AGAOTBlock *ag_aot_find(const uint32_t *words, size_t count);
/* Pure C-span translations never use RAM/TLB accessors, targets, operations,
 * chains or assembly entry state. Initialize only their documented readable
 * subset rather than clearing AGRun and preparing a full memory-access view
 * for each tiny ALU prefix. No uninitialized field may escape to strict run,
 * ag_enter, memory helpers, or any future non-pure translation. The selected
 * code epochs remain exact; only independent memory epochs are captured here. */
static inline int ag_aot_prepare_pure_span(AGRun *r, AVZNativeCPU *cpu,
    uint64_t budget, const uint64_t *local, uint64_t local_epoch,
    const _Atomic uint64_t *shared, uint64_t shared_epoch,
    AVZNativeMemoryFastPath *path) {
    r->cpu = cpu;
    r->budget = budget;
    r->result.steps = 0;
    r->result.generic_dispatches = 0;
    r->result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
    r->guards = (AGGuards){.local = local, .shared = {shared},
        .expected = {local_epoch, shared_epoch}};
    r->memory.shared = path ? path->guest_memory : NULL;
    r->memory.observed_translation = path ? path->observed_shared_translation_epoch : 0;
    r->memory.translation_epoch = r->memory.code_epoch = 0;
    if (!r->memory.shared) return 1;
    r->memory.translation_epoch = atomic_load_explicit(
        &r->memory.shared->translation_epoch, memory_order_acquire);
    r->memory.code_epoch = atomic_load_explicit(
        &r->memory.shared->code_mutation_epoch, memory_order_acquire);
    return r->memory.translation_epoch == r->memory.observed_translation;
}
struct AGAOTCounters *ag_aot_owner_counters(void);
void ag_aot_capture(const uint32_t *words, size_t count, uint64_t base);

/* Match the assembly executor's before-entry and after-retirement checks,
 * including the independently observed memory/code epochs. No helper calls,
 * memory operations or chains are supported by the first AOT subset. */
static inline int ag_aot_boundary_budget(AGRun *r, uint64_t remaining) {
    const AGGuards *g = &r->guards;
    int valid = !g->local || *g->local == g->expected[0];
    for (unsigned i = 0; i < 3; i++)
        if (g->shared[i] && atomic_load_explicit(g->shared[i], memory_order_acquire) != g->expected[i + 1])
            valid = 0;
    if (r->memory.shared &&
        (atomic_load_explicit(&r->memory.shared->translation_epoch, memory_order_acquire) != r->memory.translation_epoch ||
         atomic_load_explicit(&r->memory.shared->code_mutation_epoch, memory_order_acquire) != r->memory.code_epoch))
        valid = 0;
    if (!valid) {
        r->result.status = AVZ_TP_STATUS_REVALIDATE;
        return 0;
    }
    if (!remaining) {
        r->result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
        return 0;
    }
    return 1;
}
/* Compatibility entry for callers that keep the live budget in AGRun.
 * Generated native functions can keep it in a host local, checking identical
 * guards on every retirement without publishing the budget on every step. */
static inline int ag_aot_boundary(AGRun *r) {
    return ag_aot_boundary_budget(r, r->budget);
}
static inline int ag_aot_retire(AGRun *r) {
    r->result.steps++;
    r->result.generic_dispatches++;
    r->budget--;
    return ag_aot_boundary(r);
}
#endif
