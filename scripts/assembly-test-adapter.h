/* Run the same adversarial fixtures through the production assembly adapter.
 * Included after Native.c so aliases affect tests, never implementation code. */
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

static AVZNativeThreadedPrototypeStatistics assembly_test_statistics(
    const AVZNativeExecutionContext *c) {
    AVZNativeAssemblyStatistics s = avz_native_execution_context_assembly_statistics(c);
    return (AVZNativeThreadedPrototypeStatistics){.enabled = s.enabled,
        .blocks = s.blocks, .steps = s.steps, .memory_enabled = s.enabled,
        .memory_boundaries = s.boundaries, .memory_faults = s.faults};
}
static AVZNativeBlockResult assembly_test_memory(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory) {
    return ag_run_memory(p, budget, cpu, NULL, memory);
}
static AVZNativeBlockResult assembly_test_run(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu) {
    return ag_run(p, budget, cpu, NULL);
}
static AVZNativeBlockResult assembly_test_guarded(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory, AVZNativeBlockCache *cache,
    uint64_t local, uint64_t shared) {
    AGGuards proof = {.local = avz_native_block_cache_code_mutation_epoch_token(cache),
        .shared = {(const _Atomic uint64_t *)avz_native_block_cache_shared_code_mutation_epoch_token(cache)},
        .expected = {local, shared}};
    return ag_run_memory(p, budget, cpu, &proof, memory);
}
#define AVZThreadedPrototype AGProgram
#define avz_tp_create ag_create
#define avz_tp_destroy ag_destroy
#define avz_tp_run_with_memory assembly_test_memory
#define avz_tp_run assembly_test_run
#define avz_tp_run_guarded assembly_test_guarded
#define avz_native_block_cache_threaded_program_with_memory avz_assembly_cache_program
#define avz_native_execution_context_set_threaded_prototype avz_native_execution_context_set_assembly_executor
#define avz_native_execution_context_set_threaded_memory(context, enabled) ((void)0)
#define avz_native_execution_context_threaded_statistics assembly_test_statistics
