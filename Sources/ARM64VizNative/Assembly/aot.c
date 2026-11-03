#include "aot_runtime.h"
#include "ARM64VizAOT.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

/* Replace this include through the offline generator; signed into the app. */
#ifndef AG_AOT_GENERATED_INCLUDE
#define AG_AOT_GENERATED_INCLUDE "aot_generated.inc"
#endif
#include AG_AOT_GENERATED_INCLUDE
static _Atomic uint64_t bindings;
/* Programs are owner-confined, just like the assembly cache. Publish counters
 * to a process-lifetime shard so readers never follow cache allocations or
 * race their reclamation. Normal runs need no TLS lookup; the origin shard is
 * bound once during preparation. Separate cache lines
 * prevent vCPUs from bouncing a shared statistics line on every tiny block.
 * The last shard is shared after unusually many origin threads. All updates
 * remain atomic so migration or programs sharing an origin remain safe. */
enum { AG_AOT_OWNER_SHARDS = 128 };
static struct AGAOTCounters counter_shards[AG_AOT_OWNER_SHARDS + 1];
static _Atomic unsigned next_counter_shard;
static _Thread_local struct AGAOTCounters *owner_counters;
struct AGAOTCounters *ag_aot_owner_counters(void) {
    if (!owner_counters) {
        unsigned index = atomic_load_explicit(&next_counter_shard, memory_order_relaxed);
        while (index < AG_AOT_OWNER_SHARDS &&
            !atomic_compare_exchange_weak_explicit(&next_counter_shard, &index, index + 1,
                memory_order_relaxed, memory_order_relaxed)) {}
        owner_counters = &counter_shards[index];
    }
    return owner_counters;
}
const AGAOTBlock *ag_aot_find(const uint32_t *words, size_t count) {
    const char *enabled = getenv("PINECONE_AOT");
    if (!enabled || strcmp(enabled, "1")) return NULL;
    if (!words || !count) return NULL;
    size_t available = count < AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS ? count : AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS;
    uint64_t hashes[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < available; i++) {
        hash = (hash ^ words[i]) * UINT64_C(1099511628211);
        hashes[i] = hash;
    }
    /* Longest exact instruction prefix wins. The original assembly program
     * retains the full block and its proofs, so native code can safely return
     * to the interpreter for a memory/unsupported translation tail. */
    for (size_t length = available; length > 0; length--) {
        hash = hashes[length - 1];
        size_t low = 0, high = AG_AOT_BLOCK_COUNT;
        while (low < high) {
            size_t mid = low + (high - low) / 2;
            if (ag_aot_blocks[mid].fingerprint < hash) low = mid + 1;
            else high = mid;
        }
        for (size_t i = low; i < AG_AOT_BLOCK_COUNT && ag_aot_blocks[i].fingerprint == hash; i++) {
            const AGAOTBlock *b = &ag_aot_blocks[i];
            if (length == b->count && !memcmp(words, b->words, length * sizeof(*words))) {
                atomic_fetch_add_explicit(&bindings, 1, memory_order_relaxed);
                return b;
            }
        }
    }
    return NULL;
}
AVZNativeAOTStatistics avz_native_aot_statistics(void) {
    AVZNativeAOTStatistics result = {
        .compiled_blocks = AG_AOT_BLOCK_COUNT,
        .bindings = atomic_load_explicit(&bindings, memory_order_relaxed)
    };
    for (size_t i = 0; i <= AG_AOT_OWNER_SHARDS; i++) {
        uint64_t span_runs = atomic_load_explicit(&counter_shards[i].published_span_runs, memory_order_relaxed);
        uint64_t span_steps = atomic_load_explicit(&counter_shards[i].published_span_steps, memory_order_relaxed);
        result.runs += atomic_load_explicit(&counter_shards[i].published_runs, memory_order_relaxed) + span_runs;
        result.steps += atomic_load_explicit(&counter_shards[i].published_steps, memory_order_relaxed) + span_steps;
        result.span_runs += span_runs;
        result.span_steps += span_steps;
    }
    return result;
}
void ag_aot_capture(const uint32_t *words, size_t count, uint64_t base) {
    const char *path = getenv("PINECONE_AOT_CAPTURE");
    if (!path || !*path || !count || count > AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS) return;
    /* Discovery trace, NOT an execution-frequency profile. One append per
     * preparation, outside dispatch; duplicate blocks are deduplicated offline.
     * Each vCPU writes one complete short JSONL record through O_APPEND. */
    char line[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS * 13 + 128];
    int used = snprintf(line, sizeof(line), "{\"pc\":\"0x%llx\",\"words\":[", (unsigned long long)base);
    for (size_t i = 0; i < count; i++)
        used += snprintf(line + used, sizeof(line) - (size_t)used, "%s\"%08x\"", i ? "," : "", words[i]);
    used += snprintf(line + used, sizeof(line) - (size_t)used, "]}\n");
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) {
        /* A partial record is discarded by the offline reader. Never block
         * guest execution retrying a failed diagnostic write. */
        (void)write(fd, line, (size_t)used);
        close(fd);
    }
}
