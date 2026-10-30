/* Test-only access to the same direct-CPU core used by the runtime. This avoids
 * comparing only against the older public API's copy-in/copy-out overhead. */
#include "../../Sources/ARM64VizNative/ARM64VizNative.c"

AVZNativeBlockResult ag_reference_cpu(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu) {
    return avz_native_run_threaded_decoded_block_cpu_impl(
        code, count, base, budget, cpu,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, 0);
}
AVZNativeBlockResult ag_reference_memory(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory) {
    return avz_native_run_threaded_decoded_block_cpu_impl(
        code, count, base, budget, cpu,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, memory, NULL, 0);
}

/* Pair controls use the runtime's paired RAM helper, not two generic callback
 * accesses. Keep historical scalar controls unchanged for comparability. */
AVZNativeBlockResult ag_reference_pair(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory) {
    return avz_native_run_threaded_decoded_block_cpu_impl(
        code, count, base, budget, cpu,
        avz_native_fast_memory_read, avz_native_fast_memory_write,
        avz_native_fast_memory_can_access, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        memory, NULL, 1);
}
