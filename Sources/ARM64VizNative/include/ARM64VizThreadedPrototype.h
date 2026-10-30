#ifndef ARM64VIZ_THREADED_PROTOTYPE_H
#define ARM64VIZ_THREADED_PROTOTYPE_H

#include "ARM64VizNative.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AVZThreadedPrototype AVZThreadedPrototype;

enum {
    AVZ_TP_MAX_INSTRUCTIONS = 4096,
    AVZ_TP_STATUS_DISABLED = 256,
    AVZ_TP_STATUS_INVALID_ARGUMENT = 257,
    AVZ_TP_STATUS_REVALIDATE = 258,
    AVZ_TP_STATUS_MEMORY_FAULT = 259
};

/* Compile this translation unit with
 * AVZ_THREADED_PROTOTYPE_ENABLE=1 to opt in; guaranteed musttail is required.
 * A program is an immutable owned snapshot, NOT a guest code cache. The caller
 * must provide stable code and exclusive CPU ownership for the whole run. No
 * guest fetch, MMU, invalidation, interrupt or checkpoint integration is implied.
 */
int avz_tp_available(void);
int avz_tp_supports_instruction(const AVZNativeInstruction *instruction);
/* Eligibility predicates require decoder-produced operands. The original
 * predicate excludes memory so existing cache adapters remain register-only. */
int avz_tp_supports_instruction_with_memory(const AVZNativeInstruction *instruction);
AVZThreadedPrototype *avz_tp_create(const uint32_t *words, size_t count,
                                  uint64_t base_pc);
/* destroy drops the sole owner and retires the program immediately. Active
 * calls pin its allocation until return; no caller may start a new run after
 * destroy. Ownership, runs and destruction must be serialized on one vCPU,
 * including reentrant callbacks, never concurrently across host threads. */
void avz_tp_destroy(AVZThreadedPrototype *program);
size_t avz_tp_program_bytes(const AVZThreadedPrototype *program);
int avz_tp_program_uses_memory(const AVZThreadedPrototype *program);

/* Returns native MAX_STEPS, OUTSIDE_BLOCK, HALTED, or UNSUPPORTED statuses.
 * UNSUPPORTED means precise subset side exit BEFORE that instruction; it does
 * not mean the reference executor cannot execute it. steps counts only retired
 * instructions. generic_dispatches counts handler executions, not side exits.
 * All CPU fields remain architectural at return. Memory/system operations are
 * never executed here. A zero budget takes precedence over halted/outside state.
 * NULL inputs return INVALID_ARGUMENT without touching CPU state. Disabled
 * builds return DISABLED, create returns NULL, and no execution occurs.
 */
AVZNativeBlockResult avz_tp_run(const AVZThreadedPrototype *program,
                              uint64_t max_steps, AVZNativeCPU *cpu);

/* Optional bounded scalar memory execution, using ONLY existing native helpers.
 * NULL memory preserves avz_tp_run behavior. Caller owns/synchronizes the vCPU,
 * fast-memory translation/architectural context and code validity before entry;
 * max_steps must not exceed its next checkpoint/deadline budget.
 * Proven hot RAM accesses may continue within the original budget. Local/shared
 * code mutations and shared TLBI publication stop dispatch at the next boundary.
 * A miss, callback or observed store uses the complete helper and returns
 * REVALIDATE after success, even if the budget is exhausted. Revalidate
 * code/mappings and process checkpoints before resuming. Callbacks may destroy
 * the program; execution pins its allocation, but never resumes a retired one.
 * On helper failure returns MEMORY_FAULT
 * with no instruction retirement or CPU writeback; caller owns fault delivery
 * and must not retry a potentially side-effecting access as an unsupported op.
 * Helper-owned callback/fault/dirty/observation effects are not rolled back.
 * The fast-memory context, cache, guest RAM and CPU must remain alive throughout
 * the call. They may not be destroyed/replaced by callbacks. Cache clear and
 * entry/program eviction are allowed. Other vCPUs own separate caches/contexts
 * and publish invalidation through shared guest-memory epochs, not this cache.
 */
AVZNativeBlockResult avz_tp_run_with_memory(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory);

/* Runtime adapter supplies epochs captured BEFORE selecting/validating code,
 * closing the validation-to-entry race. Epoch mismatch retires zero instructions
 * and returns REVALIDATE. The unguarded APIs require caller-stable code at entry. */
AVZNativeBlockResult avz_tp_run_guarded(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory,
    AVZNativeBlockCache *cache, uint64_t code_epoch, uint64_t shared_code_epoch);

/* Runtime adapter: returns a cache-owned program only for fully supported
 * validated blocks. Caller must own the cache/vCPU; do not retain across cache
 * mutation. The cache bounds and releases all auxiliary program allocations. */
const AVZThreadedPrototype *avz_native_block_cache_threaded_program(
    AVZNativeBlockCache *cache, const AVZNativeDecodedBlock *block);
const AVZThreadedPrototype *avz_native_block_cache_threaded_program_with_memory(
    AVZNativeBlockCache *cache, const AVZNativeDecodedBlock *block,
    uint8_t allow_memory);

#ifdef __cplusplus
}
#endif
#endif
