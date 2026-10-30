#ifndef ARM64VIZ_CACHE_DIAGNOSTICS_H
#define ARM64VIZ_CACHE_DIAGNOSTICS_H

#include "ARM64VizNative.h"

/* Owner-confined attribution API. Build the
 * cache with AVZ_ASSEMBLY_CACHE_DIAGNOSTICS=1; default builds have no diagnostic
 * hot-path branches, increments or clocks. Even instrumented builds start off.
 * Call only on the cache's owning vCPU, or while it is stopped. No atomics or
 * concurrent snapshot guarantees. Do not reset a window from an execution
 * callback. Snapshot each vCPU separately at matched workload boundaries.
 * Keep diagnostic runs separate from clean timing cohorts; no speedup follows
 * from hit rates, preparation time or these synthetic retention tests. */
enum {
    AVZ_CACHE_DIAGNOSTICS_COUNTS = 1u,
    AVZ_CACHE_DIAGNOSTICS_PREPARATION_TIME = 2u
};

typedef struct {
    /* program_capacity is the decoded-entry ceiling, not a fixed slot pool.
     * Actual retention is limited by program_byte_budget below. */
    uint32_t compiled, enabled, timing_enabled, program_capacity;
    /* Lookups, not executed blocks/steps. For a non-NULL cache, requests are
     * partitioned into invalid + stale + hits + misses + negative_hits +
     * semantic_rejections. Misses reach preparation; first semantic rejects
     * do not. Negative hits reuse entry-lifetime eligibility, not a program. */
    uint64_t requests, invalid_requests, stale_requests;
    uint64_t program_hits, program_misses, negative_hits;
    uint64_t negative_semantic_hits, negative_unsupported_hits;
    uint64_t negative_null_hits, negative_memory_hits;
    uint64_t eligibility_scans, semantic_rejections;
    uint64_t preparation_attempts, program_allocations, preparation_null_results;
    uint64_t unsupported_preparations, memory_denied_preparations, admissions;
    /* Same decoded-entry lifetime, previously admitted but now without a program.
     * Does not count reuse after decoded eviction/invalidation/reset. */
    uint64_t positive_repreparations;
    /* Existing positive ownership at budget replacement, without extra code
     * validation of the victim. entry_releases groups decoded replacement and
     * invalidation; clear_releases covers cache clear/destroy. */
    uint64_t positive_evictions, evictions_with_free_slots;
    /* evictions_with_free_slots is a legacy FIFO metric, always zero under
     * decoded-entry retention: there is no independent slot pool. */
    /* Hits since this diagnostic window began (or the victim was admitted).
     * Reuse is evidence for a retention experiment, not a counterfactual win. */
    uint64_t reused_positive_evictions, evicted_program_hits;
    uint64_t entry_releases, clear_releases, transient_releases;
    uint64_t preparation_timed_samples, preparation_ns, preparation_max_ns;
    uint64_t preparation_clock_failures;
    /* ag_create plus capability query only; excludes word copying, cache
     * lookup/validation, semantic scans, eviction/free and execution. NULL
     * means OOM OR invalid input/unavailable implementation, not proven OOM.
     * Current ag_create makes one allocation per non-NULL program. */
    uint64_t allocated_program_bytes;
    uint64_t cache_owned_programs, cache_owned_program_bytes;
    uint64_t peak_cache_owned_programs, peak_cache_owned_program_bytes;
    uint64_t peak_preparation_live_bytes;
    /* Requested payload sizes, not allocator/RSS measurements. Includes the
     * cache object, decoded entries, page links/buckets and tracking arrays.
     * Excludes guest RAM, guest-memory object, threaded programs and programs
     * retired but still pinned by execution (no reclamation hook here).
     * Snapshot gauges remain available with collection disabled. */
    uint64_t cache_storage_bytes, assembly_slot_storage_bytes;
    /* Appended retention-policy fields. Defaults: 4 MiB payload/vCPU, at most
     * 3 MiB protected. Compile-time AVZ_ASSEMBLY_CACHE_BYTE_BUDGET overrides are
     * reported here. assembly_slot_storage_bytes now describes fixed per-entry
     * retention metadata and queue heads/byte gauges, not a 256-slot array.
     * Payload excludes allocator overhead and retired active pins; preparation
     * may transiently add one bounded decoded-block program above the budget.
     * Hot hits do ordinary owner-confined queue updates, never diagnostic
     * clocks/atomics when collection is disabled. Third lookup promotes;
     * an initial selection/execution pair alone remains in probation. */
    uint64_t program_byte_budget, protected_byte_budget, protected_program_bytes;
    uint64_t promotions, protected_demotions, budget_evictions, budget_rejections;
    uint64_t max_retirements_per_admission, peak_admission_retirements;
} AVZAssemblyCacheDiagnostics;

#ifdef __cplusplus
extern "C" {
#endif
/* Starts a new counter window WITHOUT clearing/rewarming the cache. Timing
 * implies counts; flags=0 resets and disables collection. Returns 0 if the
 * instrumentation is not compiled, cache is NULL, or flags are unknown.
 * Cache clear/invalidation does not reset counters. Peaks start at residency
 * on begin; release counts denote loss of ownership, not physical frees. */
int avz_native_block_cache_diagnostics_begin(AVZNativeBlockCache *cache,
    uint32_t flags);
AVZAssemblyCacheDiagnostics avz_native_block_cache_diagnostics_snapshot(
    const AVZNativeBlockCache *cache);
#ifdef __cplusplus
}
#endif

#endif
