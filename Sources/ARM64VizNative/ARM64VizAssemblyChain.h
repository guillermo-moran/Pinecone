#ifndef ARM64VIZ_ASSEMBLY_CHAIN_H
#define ARM64VIZ_ASSEMBLY_CHAIN_H

#include "Assembly/service_chain.h"

/* Private, owner-thread-only adapter; default off with AG_SERVICE_CHAIN_ENABLE.
 * Synchronize shared translations, then capture selection_proof BEFORE root
 * selection. local is this cache's code epoch; shared[0]/[1] are the bound
 * guest memory's code/translation epochs. Do not refresh these captured values.
 * key is the canonical execution key; the fast path independently supplies
 * the full translation context, including both TTBRs/ASIDs, for capture/checks.
 * Requires a bound fast path, >=2 resident eligible members (or a recorded
 * resident self-edge), <=8 members,
 * <=128 instructions, <=32 KiB including adapter metadata. No target decoding.
 * New members require retained positive single-block programs and previously
 * recorded validated successor edges. An unrelated root never displaces a
 * still-valid graph; auxiliary program eviction does not retire private copies.
 * NULL is ordinary fallback and does not alter single-block eligibility.
 * The returned pointer is borrowed for IMMEDIATE run through the wrapper below:
 * no intervening callback, cache mutation, checkpoint or direct service run.
 */
AGServiceChain *avz_assembly_cache_service_chain(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *root, const AVZNativeBlockKey *key,
    AVZNativeMemoryFastPath *memory, const AGGuards *selection_proof);

/* Read-only membership of the currently published, still-valid graph. The
 * complete original decoded identity must match; a PC/suffix alone is not
 * membership. No building, retirement, mapping callbacks or token refresh. */
int avz_assembly_cache_service_chain_contains(const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, uint64_t serial);

/* Mandatory wrapper: prevents rebuilding/reentry while the service pin is live.
 * Service/helper callbacks may clear/evict/retire, but must not destroy/rebind
 * cache, RAM, fast path or token storage. Destruction/rebinding requires owner
 * quiescence. Retired graph storage is reclaimed by AGServiceChain on return.
 * The caller owns service accounting, architectural status and checkpoint policy.
 */
AGServiceResult avz_assembly_cache_service_chain_run(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner);
/* Same owner pin/lifetime contract. Service is initial, at terminal helpers,
 * and final, not every visit. next_steps must bound all native deadlines. */
AGServiceResult avz_assembly_cache_service_chain_run_bounded(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner);

/* Owner-only explicit retirement; idempotent through the cache, not a stale
 * graph pointer. Does not change decoded entries or single-block retention. */
void avz_assembly_cache_service_chain_retire(AVZNativeBlockCache *cache);

typedef struct {
    size_t members, instructions, bytes;
    unsigned active;
} AVZAssemblyChainInfo;
AVZAssemblyChainInfo avz_assembly_cache_service_chain_info(
    const AVZNativeBlockCache *cache);

/* Lifetime owner counters, unchanged by cache clear. No atomics, clock reads,
 * or work when compile-disabled. bytes includes a retired active graph until
 * the wrapper returns; a valid graph is not displaced on unrelated-root misses. */
typedef struct {
    uint64_t builds, reuses, retirements, failed_builds, retained_graph_misses;
    size_t bytes, peak_bytes;
} AVZAssemblyChainDiagnostics;
AVZAssemblyChainDiagnostics avz_assembly_cache_service_chain_diagnostics(
    const AVZNativeBlockCache *cache);

#endif
