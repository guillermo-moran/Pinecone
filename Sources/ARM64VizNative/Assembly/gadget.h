#ifndef PINECONE_PHASE3_GADGET_H
#define PINECONE_PHASE3_GADGET_H
#include "ARM64VizThreadedPrototype.h"
#include <stdatomic.h>

typedef struct AGProgram AGProgram;
typedef struct {
    const uint64_t *local;
    const _Atomic uint64_t *shared[3];
    uint64_t expected[4];
} AGGuards;

/* Single-owner immutable execution snapshot. The VM adapter must provide
 * cache enrollment, lifetime, context proofs and scheduling boundaries.
 * CPU/program/guard storage must remain alive and owner-confined throughout
 * run; only shared atomic generations may be published by another thread.
 * Memory runs may invoke the authoritative C access callbacks. Such callbacks
 * may destroy (retire) the program, but not the CPU, fast path or guest RAM.
 * Destruction during execution is deferred until the owner returns from run.
 * This API does not enroll code pages: callers must enroll/guard mutable code.
 * The caller supplies a stable snapshot and a bounded service allowance.
 * NULL guards means caller-guaranteed immutable code/context, not a VM mode. */
int ag_available(void);
AGProgram *ag_create(const uint32_t *words, size_t count, uint64_t base);
void ag_destroy(AGProgram *program);
size_t ag_program_bytes(const AGProgram *program);
/* 0 unsupported, 1 register-only, 2 requires authoritative memory helpers. */
unsigned ag_program_capabilities(const AGProgram *program);
const AGProgram *avz_assembly_cache_program(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, int allow_memory);
AVZNativeBlockResult ag_run(const AGProgram *program, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards);
AVZNativeBlockResult ag_run_memory(const AGProgram *program, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory);

typedef struct AGChain AGChain;
typedef struct {
    const uint32_t *words;
    size_t count;
    uint64_t base;
    const _Atomic uint64_t *code_generation;
    uint64_t expected_generation;
} AGBlock;
typedef struct {
    uint64_t steps, service_steps, blocks;
    const _Atomic uint64_t *events;
} AGLimits;
typedef struct {
    uint64_t entries, proof_scans, proof_hits, page_checks;
    uint64_t revalidations, block_entries, polls, yields;
    uint64_t retirements, reclamations;
} AGChainStats;

/* Offline owner-confined chain. Basic blocks are sorted, disjoint, at most 16
 * instructions and contained within one code page; branches must be last.
 * The caller validates the
 * snapshot before creation and retains all proof storage until destruction.
 * shared[0] publishes ALL writes to enrolled code pages, shared[1] mapping/
 * context changes. Both are required; local/shared[2] are optional context
 * guards. Code-page tokens must change before release-publishing shared[0].
 * Tokens never wrap/reuse identities while a chain exists. Page proof reuse
 * is permitted only while the aggregate code epoch is unchanged. An unrelated
 * code write can refresh that proof after every page is checked again.
 * Each branch/entry/fallthrough polls events (nonzero means return, not ack).
 * service_steps is the caller's next event/deadline allowance, not a wall clock.
 * Helpers always terminate. Destroy from an owner callback retires the entire
 * chain; actual reclamation waits for the run pin. Peers may publish tokens or
 * events, never destroy/mutate the chain. Statistics storage is optional and
 * must outlive the chain, including its final deferred reclamation. */
AGChain *ag_chain_create(const AGBlock *blocks, size_t count,
    const AGGuards *proof, AGChainStats *stats);
void ag_chain_destroy(AGChain *chain);
size_t ag_chain_bytes(const AGChain *chain);
AVZNativeBlockResult ag_chain_run(AGChain *chain, AGLimits limits,
    AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory);

#endif
