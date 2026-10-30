#include "ARM64VizNative.h"
#include "ARM64VizCacheDiagnostics.h"
#include "ARM64VizAssemblyChain.h"
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE && defined(AG_SERVICE_CHAIN_ENABLE) && AG_SERVICE_CHAIN_ENABLE
#include "ARM64VizGuestMemoryInternal.h"
#define AVZ_CACHE_SERVICE_CHAIN 1
#else
#define AVZ_CACHE_SERVICE_CHAIN 0
#endif
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
#include "Assembly/gadget.h"
#endif
#if AVZ_THREADED_PROTOTYPE_ENABLE
#include "ARM64VizThreadedPrototype.h"
#endif

#include <limits.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

/* Payload budget per owner/vCPU, excluding fixed decoded-entry metadata and
 * retired active pins. Overrides are for isolated attribution/testing builds. */
#ifndef AVZ_ASSEMBLY_CACHE_BYTE_BUDGET
#define AVZ_ASSEMBLY_CACHE_BYTE_BUDGET (4u * 1024u * 1024u)
#endif
#define AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET (AVZ_ASSEMBLY_CACHE_BYTE_BUDGET * 3u / 4u)
#define AVZ_ASSEMBLY_CACHE_MAX_RETIREMENTS 64u

#ifndef AVZ_ASSEMBLY_CACHE_DIAGNOSTICS
#define AVZ_ASSEMBLY_CACHE_DIAGNOSTICS 0
#endif
#if AVZ_ASSEMBLY_CACHE_DIAGNOSTICS && AVZ_ASSEMBLY_EXECUTOR_ENABLE
#include <time.h>
#define AVZ_AC_DIAGNOSTICS 1
#define AVZ_AC_COUNT(cache, field) do { \
    if ((cache) && (cache)->assembly_diagnostics.enabled) \
        (cache)->assembly_diagnostics.field++; \
} while (0)
#else
#define AVZ_AC_DIAGNOSTICS 0
#define AVZ_AC_COUNT(cache, field) ((void)0)
#endif

/* Compile-time opt-in: no counters or counter branches in ordinary builds. */
#ifndef AVZ_THREADED_CACHE_DIAGNOSTICS
#define AVZ_THREADED_CACHE_DIAGNOSTICS 0
#endif
#if AVZ_THREADED_CACHE_DIAGNOSTICS && AVZ_THREADED_PROTOTYPE_ENABLE
#define AVZ_TC_COUNT(cache, field) ((cache)->threaded_statistics.field++)
#else
#define AVZ_TC_COUNT(cache, field) ((void)0)
#endif

enum {
    AVZ_BLOCK_CACHE_SET_COUNT = 8192,
    AVZ_BLOCK_CACHE_WAY_COUNT = 4,
    AVZ_BLOCK_CACHE_ENTRY_COUNT =
        AVZ_BLOCK_CACHE_SET_COUNT * AVZ_BLOCK_CACHE_WAY_COUNT,

    AVZ_BLOCK_FRONT_CACHE_ENTRY_COUNT = 8192,
    AVZ_BLOCK_PAGE_BUCKET_COUNT = 16384
};

#define AVZ_BLOCK_TTBR_BASE_MASK UINT64_C(0x0000fffffffff000)

typedef struct {
    int32_t next;
    int32_t previous;
    uint64_t page;
    uint8_t linked;
} AVZBlockPageLink;

typedef struct {
    const AVZNativeDecodedBlock *target;
    const uint64_t *target_serial_token;
    uint64_t target_serial;
    uint64_t last_used;
} AVZBlockSuccessor;

struct AVZNativeDecodedBlock {
    AVZNativeBlockKey key;
    AVZNativeInstruction instructions[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    uint64_t physical_addresses[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    uint8_t semantic_candidates[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    uint8_t trace_semantic_candidates[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    uint8_t instruction_count;
    uint8_t uses_vector_state;
    uint8_t chain_barrier;
    uint8_t requires_host_checkpoint;
    uint8_t code_page_count;
    uint64_t physical_code_pages[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    const uint8_t *host_code_pages[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    const uint64_t
        *code_page_generation_tokens[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    const uint64_t
        *shared_code_page_generation_tokens[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    uint64_t code_page_generations[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    uint64_t shared_code_page_generations[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    AVZBlockSuccessor successors[2];
    uint64_t successor_clock;
};

static int avz_is_coherent_cache_maintenance(uint32_t instruction) {
    unsigned crn = (instruction >> 12u) & 0xfu;
    unsigned crm = (instruction >> 8u) & 0xfu;

    if (crn != 7u) {
        return 0;
    }
    return crm == 5u || crm == 6u ||
        (crm >= 10u && crm <= 14u);
}

static void avz_record_block_exit_metadata(
    AVZNativeDecodedBlock *block,
    const AVZNativeInstruction *instruction
) {
    switch (instruction->kind) {
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ:
    case AVZ_NATIVE_OP_EXCEPTION_RETURN:
        block->chain_barrier = 1;
        break;
    case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
        block->chain_barrier = 1;
        if ((instruction->raw & UINT32_C(0xffe0001f)) !=
            UINT32_C(0xd4000001)) {
            block->requires_host_checkpoint = 1;
        }
        break;
    case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
        if (avz_is_coherent_cache_maintenance(instruction->raw)) {
            break;
        }
        block->chain_barrier = 1;
        block->requires_host_checkpoint = 1;
        break;
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE:
    case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
    case AVZ_NATIVE_OP_WAIT:
    case AVZ_NATIVE_OP_HALT:
        block->chain_barrier = 1;
        block->requires_host_checkpoint = 1;
        break;
    case AVZ_NATIVE_OP_BARRIER:
        if ((instruction->raw & UINT32_C(0xfffff0ff)) ==
            UINT32_C(0xd50330df)) {
            block->chain_barrier = 1;
        }
        break;
    default:
        break;
    }
}

static void avz_classify_block_semantics(AVZNativeDecodedBlock *block) {
    if (block == NULL) {
        return;
    }
    for (size_t index = 0; index < block->instruction_count; index++) {
        block->semantic_candidates[index] =
            avz_native_classify_semantic_candidate(
                block->instructions,
                block->instruction_count,
                index,
                index == 0,
                0
            );
        block->trace_semantic_candidates[index] =
            avz_native_classify_semantic_candidate(
                block->instructions,
                block->instruction_count,
                index,
                index == 0,
                1
            );
    }
}

#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
typedef struct {
    AGProgram *program;
    size_t bytes;
    uint16_t previous, next; /* One-based decoded-entry indices; zero is null. */
    uint8_t queue; /* 0 absent, 1 probation, 2 protected. */
    uint8_t reuse; /* Two cached hits promote; a paired initial lookup does not. */
#if AVZ_AC_DIAGNOSTICS
    uint64_t hits;
#endif
} AVZAssemblyRetention;
_Static_assert(AVZ_BLOCK_CACHE_ENTRY_COUNT <= UINT16_MAX, "assembly queue index width");
_Static_assert(AVZ_ASSEMBLY_CACHE_BYTE_BUDGET > 0, "assembly byte budget must be positive");
#endif

typedef struct {
    AVZNativeDecodedBlock block;
    uint64_t serial;
    uint64_t validated_code_mutation_epoch;
    uint64_t validated_shared_code_mutation_epoch;
    uint64_t validated_translation_epoch;
    uint64_t last_used;
    uint8_t valid;
    uint8_t prefetched;
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
    uint8_t assembly_capability; /* 0 unknown, 1 registers, 2 memory, 3 rejected/OOM */
    AVZAssemblyRetention assembly;
#if AVZ_AC_DIAGNOSTICS
    uint8_t assembly_rejection; /* 1 semantic, 2 unsupported, 3 NULL preparation */
    uint8_t assembly_was_admitted;
#endif
#endif
#if AVZ_THREADED_PROTOTYPE_ENABLE
    /* Decoded-entry lifetime, not auxiliary-slot lifetime. Fits tail padding. */
    uint8_t threaded_eligibility; /* 0 unknown, 1 registers, 2 unsupported, 3 OOM, 4 memory */
    uint16_t threaded_slot; /* One-based; zero means no owned program. */
#endif
} AVZBlockCacheEntry;

#if AVZ_CACHE_SERVICE_CHAIN
typedef struct {
    const AVZBlockCacheEntry *entry;
    uint64_t serial, base, physical_page;
    size_t count;
    const uint64_t *local_generation;
    const _Atomic uint64_t *shared_generation;
    uint64_t expected_local_generation, expected_shared_generation;
} AVZAssemblyChainMember;

typedef struct {
    AGServiceChain *chain;
    AVZNativeMemoryFastPath *memory;
    AVZGuestMemory *guest_memory;
    uint8_t *ram;
    uint64_t ram_base, ram_size, reset_epoch, translation_epoch;
    uint64_t memory_translation_generation, memory_tlbi_epoch;
    AVZNativeBlockKey key, memory_key;
    AGGuards proof;
    size_t count, instructions, bytes;
    unsigned active, native_translation_enabled;
    AVZAssemblyChainMember members[AG_SERVICE_MAX_MEMBERS];
} AVZAssemblyChainOwner;
#endif

typedef struct {
    uint64_t hash;
    int32_t entry_index;
    uint8_t valid;
} AVZBlockFrontCacheEntry;

struct AVZNativeBlockCache {
#if AVZ_CACHE_SERVICE_CHAIN
    AVZAssemblyChainOwner service_chain;
    AVZAssemblyChainDiagnostics service_chain_diagnostics;
#endif
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
    /* Byte-weighted segmented LRU, directly attached to decoded lifetimes.
     * Probation absorbs scans; protected entries have demonstrated reuse. */
    uint16_t assembly_heads[2], assembly_tails[2];
    size_t assembly_bytes[2];
    uint32_t assembly_count;
#if AVZ_AC_DIAGNOSTICS
    AVZAssemblyCacheDiagnostics assembly_diagnostics;
#endif
#endif
#if AVZ_THREADED_PROTOTYPE_ENABLE
    /* Intrusive global FIFO; hits do not reorder the 256-program pool. */
    struct {
        AVZBlockCacheEntry *owner;
        AVZThreadedPrototype *program;
        uint16_t previous, next;
    } threaded_programs[256];
    uint16_t threaded_lru;
#if AVZ_THREADED_CACHE_DIAGNOSTICS
    struct {
        uint64_t hits, negative_hits, collisions, creations, destructions;
        uint64_t eligibility_scans, allocation_failures;
    } threaded_statistics;
#endif
#endif
    AVZBlockCacheEntry *entries;
    AVZBlockPageLink *page_links;
    int32_t *page_bucket_heads;
    uint64_t access_clock;
    AVZBlockFrontCacheEntry front_entries[AVZ_BLOCK_FRONT_CACHE_ENTRY_COUNT];
    AVZNativeBlockKey last_context_key;
    uint64_t last_context_hash;
    uint8_t last_context_valid;
    uint16_t *code_page_refcounts;
    uint64_t *code_page_generations;
    uint8_t *trace_code_page_bits;
    uint8_t *ram;
    uint64_t ram_base;
    uint64_t ram_size;
    AVZNativeBlockKey decode_window_key;
    uint64_t decode_window_virtual_page;
    uint64_t decode_window_physical_page;
    uint8_t decode_window_valid;
    uint8_t batch_prefetch_active;
    uint8_t batch_prefetch_limit;
    uint32_t batch_prefetch_window_hits;
    uint32_t batch_prefetch_window_unused;
    uint64_t tracked_first_page;
    size_t tracked_page_count;
    uint64_t next_serial;
    uint64_t generation;
    uint64_t mutation_epoch;
    uint64_t code_mutation_epoch;
    uint64_t reset_epoch;
    uint64_t translation_epoch;
    AVZNativeInstructionMappingValidateCallback validate_mapping;
    void *mapping_context;
    AVZGuestMemory *guest_memory;
    AVZNativeBlockCacheStatistics statistics;
};

#if AVZ_CACHE_SERVICE_CHAIN
void avz_assembly_cache_service_chain_retire(AVZNativeBlockCache *cache) {
    if (!cache || !cache->service_chain.chain) return;
    AGServiceChain *chain = cache->service_chain.chain;
    /* Lazy preparation may have grown a pinned graph during this invocation. */
    cache->service_chain.bytes = sizeof(cache->service_chain) + ag_service_chain_bytes(chain);
    if (cache->service_chain.bytes > cache->service_chain_diagnostics.peak_bytes)
        cache->service_chain_diagnostics.peak_bytes = cache->service_chain.bytes;
    cache->service_chain.chain = NULL;
    cache->service_chain_diagnostics.retirements++;
    ag_service_chain_destroy(chain);
    /* An active invocation retains this validation context until run returns. */
    if (!cache->service_chain.active)
        memset(&cache->service_chain, 0, sizeof(cache->service_chain));
}

static void avz_assembly_chain_forget_entry(AVZNativeBlockCache *cache,
    const AVZBlockCacheEntry *entry) {
    if (!cache->service_chain.chain) return;
    for (size_t i = 0; i < cache->service_chain.count; i++) {
        if (cache->service_chain.members[i].entry == entry) {
            avz_assembly_cache_service_chain_retire(cache);
            return;
        }
    }
}
#define avz_assembly_chain_retire(cache) avz_assembly_cache_service_chain_retire(cache)
#else
#define avz_assembly_chain_forget_entry(cache, entry) ((void)0)
#define avz_assembly_chain_retire(cache) ((void)0)
#endif

#if AVZ_THREADED_PROTOTYPE_ENABLE
static void avz_threaded_initialize_lru(AVZNativeBlockCache *cache) {
    for (size_t i = 0; i < 256; i++) {
        cache->threaded_programs[i].previous = (uint16_t)((i + 255u) & 255u);
        cache->threaded_programs[i].next = (uint16_t)((i + 1u) & 255u);
    }
    cache->threaded_lru = 0;
}

static void avz_threaded_touch_slot(AVZNativeBlockCache *cache, size_t slot) {
    uint16_t head = cache->threaded_lru;
    if (cache->threaded_programs[slot].next == head) return; /* Already at tail. */
    if (slot == head) {
        cache->threaded_lru = cache->threaded_programs[slot].next;
        return;
    }
    uint16_t previous = cache->threaded_programs[slot].previous;
    uint16_t next = cache->threaded_programs[slot].next;
    cache->threaded_programs[previous].next = next;
    cache->threaded_programs[next].previous = previous;
    uint16_t tail = cache->threaded_programs[head].previous;
    cache->threaded_programs[tail].next = (uint16_t)slot;
    cache->threaded_programs[slot].previous = tail;
    cache->threaded_programs[slot].next = head;
    cache->threaded_programs[head].previous = (uint16_t)slot;
}

static void avz_threaded_release_slot(AVZNativeBlockCache *cache, size_t slot) {
    if (cache->threaded_programs[slot].owner != NULL) {
        cache->threaded_programs[slot].owner->threaded_slot = 0;
    }
    if (cache->threaded_programs[slot].program != NULL) {
        AVZ_TC_COUNT(cache, destructions);
        /* Drop cache ownership now. A reentrant invalidation during execution
         * retires the snapshot; the run's pin delays reclamation until return. */
        avz_tp_destroy(cache->threaded_programs[slot].program);
    }
    cache->threaded_programs[slot].owner = NULL;
    cache->threaded_programs[slot].program = NULL;
    /* Empty slots precede live slots, so misses consume free space first. */
    avz_threaded_touch_slot(cache, slot);
    cache->threaded_lru = (uint16_t)slot;
}

static void avz_threaded_forget_entry(AVZNativeBlockCache *cache,
                                      AVZBlockCacheEntry *entry) {
    if (entry->threaded_slot != 0) {
        avz_threaded_release_slot(cache, entry->threaded_slot - 1u);
    }
    entry->threaded_eligibility = 0;
}

#else
#define avz_threaded_forget_entry(cache, entry) ((void)0)
#endif

#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
static void avz_assembly_unlink(AVZNativeBlockCache *cache, AVZBlockCacheEntry *entry) {
    AVZAssemblyRetention *r = &entry->assembly;
    unsigned queue = r->queue - 1u;
    if (r->previous) cache->entries[r->previous - 1u].assembly.next = r->next;
    else cache->assembly_heads[queue] = r->next;
    if (r->next) cache->entries[r->next - 1u].assembly.previous = r->previous;
    else cache->assembly_tails[queue] = r->previous;
    cache->assembly_bytes[queue] -= r->bytes;
    r->queue = 0;
    r->previous = r->next = 0;
}

static void avz_assembly_append(AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry, unsigned queue) {
    AVZAssemblyRetention *r = &entry->assembly;
    uint16_t index = (uint16_t)(entry - cache->entries + 1u);
    uint16_t tail = cache->assembly_tails[queue];
    r->previous = tail;
    r->next = 0;
    r->queue = (uint8_t)(queue + 1u);
    if (tail) cache->entries[tail - 1u].assembly.next = index;
    else cache->assembly_heads[queue] = index;
    cache->assembly_tails[queue] = index;
    cache->assembly_bytes[queue] += r->bytes;
}

static void avz_assembly_release(AVZNativeBlockCache *cache, AVZBlockCacheEntry *entry) {
    AVZAssemblyRetention *r = &entry->assembly;
    if (!r->program) return;
#if AVZ_AC_DIAGNOSTICS
    if (cache->assembly_diagnostics.enabled) {
        cache->assembly_diagnostics.cache_owned_programs--;
        cache->assembly_diagnostics.cache_owned_program_bytes -= r->bytes;
    }
#endif
    avz_assembly_unlink(cache, entry);
    cache->assembly_count--;
    /* Cache ownership ends now; active execution still pins the snapshot. */
    ag_destroy(r->program);
    memset(r, 0, sizeof(*r));
}
static void avz_assembly_forget_entry(AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry) {
    if (entry->assembly.program) {
        AVZ_AC_COUNT(cache, entry_releases);
        avz_assembly_release(cache, entry);
    }
    entry->assembly_capability = 0;
#if AVZ_AC_DIAGNOSTICS
    entry->assembly_rejection = 0;
    entry->assembly_was_admitted = 0;
#endif
}
static void avz_assembly_clear(AVZNativeBlockCache *cache) {
    for (unsigned queue = 0; queue < 2; queue++) {
        while (cache->assembly_heads[queue]) {
            AVZ_AC_COUNT(cache, clear_releases);
            avz_assembly_release(cache, &cache->entries[cache->assembly_heads[queue] - 1u]);
        }
    }
}

static void avz_assembly_record_reuse(AVZNativeBlockCache *cache, AVZBlockCacheEntry *entry) {
    AVZAssemblyRetention *r = &entry->assembly;
    if (r->queue == 2) {
        if (!r->next) return; /* Consecutive selection/execution pair: no writes. */
        avz_assembly_unlink(cache, entry);
        avz_assembly_append(cache, entry, 1);
        return;
    }
    if (r->reuse < 2) r->reuse++;
    if (r->reuse < 2 || r->bytes > AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET) return;
    /* Demote at most one entry on a lookup. Large promotions that need more
     * room remain in probation and retry on reuse; lookup work stays O(1). */
    if (cache->assembly_bytes[1] > AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET - r->bytes) {
        AVZBlockCacheEntry *old = &cache->entries[cache->assembly_heads[1] - 1u];
        avz_assembly_unlink(cache, old);
        old->assembly.reuse = 0;
        avz_assembly_append(cache, old, 0);
        AVZ_AC_COUNT(cache, protected_demotions);
    }
    if (cache->assembly_bytes[1] > AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET - r->bytes) return;
    avz_assembly_unlink(cache, entry);
    avz_assembly_append(cache, entry, 1);
    AVZ_AC_COUNT(cache, promotions);
}

static int avz_assembly_make_room(AVZNativeBlockCache *cache, size_t bytes) {
    if (bytes > AVZ_ASSEMBLY_CACHE_BYTE_BUDGET) return 0;
    unsigned retired = 0;
    while (cache->assembly_bytes[0] + cache->assembly_bytes[1] >
           AVZ_ASSEMBLY_CACHE_BYTE_BUDGET - bytes &&
           retired < AVZ_ASSEMBLY_CACHE_MAX_RETIREMENTS) {
        /* Prefer probation; a program larger than the unprotected reserve may
         * also require the oldest protected entry. Never scan decoded entries. */
        uint16_t victim = cache->assembly_heads[0] ?
            cache->assembly_heads[0] : cache->assembly_heads[1];
        AVZBlockCacheEntry *entry = &cache->entries[victim - 1u];
        AVZ_AC_COUNT(cache, positive_evictions);
        AVZ_AC_COUNT(cache, budget_evictions);
#if AVZ_AC_DIAGNOSTICS
        if (cache->assembly_diagnostics.enabled) {
            if (entry->assembly.hits) cache->assembly_diagnostics.reused_positive_evictions++;
            cache->assembly_diagnostics.evicted_program_hits += entry->assembly.hits;
        }
#endif
        avz_assembly_release(cache, entry);
        retired++;
    }
#if AVZ_AC_DIAGNOSTICS
    if (cache->assembly_diagnostics.enabled &&
        retired > cache->assembly_diagnostics.peak_admission_retirements)
        cache->assembly_diagnostics.peak_admission_retirements = retired;
#endif
    return cache->assembly_bytes[0] + cache->assembly_bytes[1] <=
        AVZ_ASSEMBLY_CACHE_BYTE_BUDGET - bytes;
}
#else
#define avz_assembly_forget_entry(cache, entry) ((void)0)
#define avz_assembly_clear(cache) ((void)0)
#endif

static void avz_advance_nonzero_counter(uint64_t *counter) {
    (*counter)++;
    if (*counter == 0) {
        *counter = 1;
    }
}

static uint64_t avz_mix_u64(uint64_t value) {
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return value;
}

static AVZNativeBlockKey avz_canonical_block_key(
    const AVZNativeBlockKey *key
) {
    AVZNativeBlockKey canonical = *key;
    if ((canonical.pc >> 63) != 0) {
        canonical.ttbr0_el1 = 0;
        canonical.ttbr1_el1 &= AVZ_BLOCK_TTBR_BASE_MASK;
    } else {
        canonical.ttbr0_el1 &= AVZ_BLOCK_TTBR_BASE_MASK;
        canonical.ttbr1_el1 = 0;
    }
    return canonical;
}

static int avz_block_contexts_equal(
    const AVZNativeBlockKey *left,
    const AVZNativeBlockKey *right
) {
    return left->sctlr_el1 == right->sctlr_el1 &&
        left->tcr_el1 == right->tcr_el1 &&
        left->ttbr0_el1 == right->ttbr0_el1 &&
        left->ttbr1_el1 == right->ttbr1_el1 &&
        left->current_el == right->current_el;
}

static uint64_t avz_block_context_hash(
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key
) {
    if (cache->last_context_valid &&
        avz_block_contexts_equal(&cache->last_context_key, key)) {
        return cache->last_context_hash;
    }

    uint64_t hash = avz_mix_u64(key->sctlr_el1);
    hash ^= avz_mix_u64(key->tcr_el1);
    hash ^= avz_mix_u64(key->ttbr0_el1);
    hash ^= avz_mix_u64(key->ttbr1_el1);
    hash ^= avz_mix_u64(key->current_el);
    cache->last_context_key = *key;
    cache->last_context_hash = avz_mix_u64(hash);
    cache->last_context_valid = 1;
    return cache->last_context_hash;
}

static uint64_t avz_block_key_hash(
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key
) {
    return avz_mix_u64(
        avz_mix_u64(key->pc) ^ avz_block_context_hash(cache, key)
    );
}

static int avz_block_keys_equal(
    const AVZNativeBlockKey *left,
    const AVZNativeBlockKey *right
) {
    return left->pc == right->pc &&
        left->sctlr_el1 == right->sctlr_el1 &&
        left->tcr_el1 == right->tcr_el1 &&
        left->ttbr0_el1 == right->ttbr0_el1 &&
        left->ttbr1_el1 == right->ttbr1_el1 &&
        left->current_el == right->current_el;
}

static const AVZBlockCacheEntry *avz_entry_for_block(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
) {
    if (cache == NULL || cache->entries == NULL || block == NULL) {
        return NULL;
    }
    uintptr_t base = (uintptr_t)cache->entries;
    uintptr_t address = (uintptr_t)block;
    size_t span = AVZ_BLOCK_CACHE_ENTRY_COUNT * sizeof(*cache->entries);
    if (address < base || address >= base + span) {
        return NULL;
    }
    size_t offset = (size_t)(address - base);
    if (offset % sizeof(*cache->entries) != 0) {
        return NULL;
    }
    size_t index = offset / sizeof(*cache->entries);
    const AVZBlockCacheEntry *entry = &cache->entries[index];
    return &entry->block == block ? entry : NULL;
}

static uint64_t avz_allocate_block_serial(AVZNativeBlockCache *cache) {
    cache->next_serial++;
    if (cache->next_serial == 0) {
        cache->next_serial = 1;
    }
    return cache->next_serial;
}

static size_t avz_block_set_index(uint64_t hash) {
    return (size_t)(hash & (AVZ_BLOCK_CACHE_SET_COUNT - 1));
}

static void avz_update_front_cache(
    AVZNativeBlockCache *cache,
    uint64_t hash,
    size_t entry_index
) {
    size_t front_index =
        (size_t)(hash & (AVZ_BLOCK_FRONT_CACHE_ENTRY_COUNT - 1));
    cache->front_entries[front_index] = (AVZBlockFrontCacheEntry){
        .hash = hash,
        .entry_index = (int32_t)entry_index,
        .valid = 1
    };
}

static size_t avz_page_bucket(uint64_t page) {
    return (size_t)(avz_mix_u64(page >> 12) & (AVZ_BLOCK_PAGE_BUCKET_COUNT - 1));
}

static void avz_track_code_page(AVZNativeBlockCache *cache, uint64_t page) {
    avz_guest_memory_mark_code_page(cache->guest_memory, page, cache->ram_base);
    if (cache->code_page_refcounts == NULL || page < cache->tracked_first_page) {
        return;
    }
    uint64_t page_index = (page - cache->tracked_first_page) >> 12;
    if (page_index >= cache->tracked_page_count) {
        return;
    }
    uint16_t *refcount = &cache->code_page_refcounts[page_index];
    if (*refcount < UINT16_MAX) {
        (*refcount)++;
    }
}

static void avz_untrack_code_page(AVZNativeBlockCache *cache, uint64_t page) {
    if (cache->code_page_refcounts == NULL || page < cache->tracked_first_page) {
        return;
    }
    uint64_t page_index = (page - cache->tracked_first_page) >> 12;
    if (page_index >= cache->tracked_page_count) {
        return;
    }
    uint16_t *refcount = &cache->code_page_refcounts[page_index];
    if (*refcount > 0) {
        (*refcount)--;
    }
}

static uint64_t *avz_code_page_generation_token(
    AVZNativeBlockCache *cache,
    uint64_t page
) {
    if (cache->code_page_generations == NULL ||
        page < cache->tracked_first_page) {
        return NULL;
    }
    uint64_t page_index = (page - cache->tracked_first_page) >> 12;
    if (page_index >= cache->tracked_page_count) {
        return NULL;
    }
    return &cache->code_page_generations[page_index];
}

static size_t avz_trace_code_page_byte_count(size_t page_count) {
    return page_count / 8u + (page_count % 8u != 0);
}

static int avz_trace_code_page_is_registered(
    const AVZNativeBlockCache *cache,
    size_t page_index
) {
    return cache->trace_code_page_bits != NULL &&
        page_index < cache->tracked_page_count &&
        (cache->trace_code_page_bits[page_index >> 3] &
         (uint8_t)(1u << (page_index & 7u))) != 0;
}

static const uint8_t *avz_direct_physical_pointer(
    const AVZNativeBlockCache *cache,
    uint64_t physical_address,
    size_t byte_count
) {
    if (cache == NULL || cache->ram == NULL || byte_count == 0 ||
        physical_address < cache->ram_base) {
        return NULL;
    }
    uint64_t offset = physical_address - cache->ram_base;
    if (offset > cache->ram_size || byte_count > cache->ram_size - offset) {
        return NULL;
    }
    return cache->ram + offset;
}

static int avz_block_code_pages_are_current(
    const AVZNativeDecodedBlock *block
) {
    if (block == NULL) {
        return 0;
    }
    for (size_t slot = 0; slot < block->code_page_count; slot++) {
        const uint64_t *token = block->code_page_generation_tokens[slot];
        if (token != NULL && *token != block->code_page_generations[slot]) {
            return 0;
        }
    }
    return 1;
}

static int avz_block_shared_code_pages_are_current(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
) {
    if (cache == NULL || block == NULL || cache->guest_memory == NULL) {
        return 1;
    }
    for (size_t slot = 0; slot < block->code_page_count; slot++) {
        const uint64_t *token =
            block->shared_code_page_generation_tokens[slot];
        if (token != NULL &&
            __atomic_load_n(token, __ATOMIC_ACQUIRE) !=
                block->shared_code_page_generations[slot]) {
            return 0;
        }
    }
    return 1;
}

static int avz_entry_code_is_current(
    AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry
) {
    uint64_t shared_epoch =
        avz_native_block_cache_shared_code_mutation_epoch(cache);
    if (entry->validated_shared_code_mutation_epoch != shared_epoch) {
        if (!avz_block_shared_code_pages_are_current(cache, &entry->block)) {
            return 0;
        }
        entry->validated_shared_code_mutation_epoch = shared_epoch;
    }
    if (entry->validated_code_mutation_epoch == cache->code_mutation_epoch) {
        return 1;
    }
    if (entry->validated_translation_epoch != cache->translation_epoch) {
        if (cache->validate_mapping == NULL) return 0;
        uint64_t epoch = cache->translation_epoch;
        uint64_t previous_page = UINT64_MAX;
        for (size_t index = 0; index < entry->block.instruction_count; index++) {
            uint64_t va = entry->block.key.pc + index * sizeof(uint32_t);
            if ((va >> 12) == previous_page) continue;
            if (!cache->validate_mapping(cache->mapping_context, va,
                    entry->block.physical_addresses[index])) return 0;
            previous_page = va >> 12;
        }
        /* A callback may observe another shared TLBI. Do not acknowledge that
         * newer epoch using a mapping checked before its publication. */
        if (epoch != cache->translation_epoch) return 0;
        entry->validated_translation_epoch = epoch;
    }
    if (!avz_block_code_pages_are_current(&entry->block)) {
        return 0;
    }
    entry->validated_code_mutation_epoch = cache->code_mutation_epoch;
    return 1;
}

static int avz_range_may_contain_code(
    const AVZNativeBlockCache *cache,
    uint64_t physical_address,
    uint64_t last_address
) {
    if (cache->code_page_refcounts == NULL || cache->tracked_page_count == 0) {
        return 1;
    }

    uint64_t first_page = physical_address & ~UINT64_C(0xfff);
    uint64_t last_page = last_address & ~UINT64_C(0xfff);
    uint64_t tracked_last_page = cache->tracked_first_page +
        ((uint64_t)(cache->tracked_page_count - 1) << 12);
    if (first_page < cache->tracked_first_page || last_page > tracked_last_page) {
        return 1;
    }

    size_t first_index = (size_t)(
        (first_page - cache->tracked_first_page) >> 12
    );
    size_t last_index = (size_t)(
        (last_page - cache->tracked_first_page) >> 12
    );
    for (size_t index = first_index; index <= last_index; index++) {
        if (cache->code_page_refcounts[index] != 0 ||
            avz_trace_code_page_is_registered(cache, index)) {
            return 1;
        }
    }
    return 0;
}

static int avz_native_kind_uses_vector_state(uint16_t kind) {
    switch (kind) {
    case AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL:
    case AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE:
    case AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE:
    case AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE:
    case AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP:
    case AVZ_NATIVE_OP_SIMD_INSERT_GENERAL_TO_ELEMENT:
    case AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D:
    case AVZ_NATIVE_OP_SIMD_ADD_VECTOR:
    case AVZ_NATIVE_OP_SIMD_ORR_VECTOR:
    case AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER:
    case AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL:
    case AVZ_NATIVE_OP_SIMD_MOVI_ZERO:
    case AVZ_NATIVE_OP_SIMD_MOVI_BYTE:
    case AVZ_NATIVE_OP_SIMD_MVNI_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_MOVI_D_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_TABLE_LOOKUP:
    case AVZ_NATIVE_OP_SIMD_PERMUTE_TWO_VECTOR:
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR:
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET:
    case AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP:
    case AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC:
    case AVZ_NATIVE_OP_FP_SCALAR_MINMAX:
    case AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX:
    case AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD:
    case AVZ_NATIVE_OP_FP_SCALAR_UNARY:
    case AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE:
    case AVZ_NATIVE_OP_FP_RECIPROCAL_STEP:
    case AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE:
    case AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE:
    case AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY:
    case AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG:
    case AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD:
    case AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE:
    case AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL:
    case AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE:
    case AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG:
    case AVZ_NATIVE_OP_SIMD_NARROW_HIGH:
    case AVZ_NATIVE_OP_SIMD_BITWISE_NOT:
    case AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT:
    case AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT:
    case AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_SELECT:
    case AVZ_NATIVE_OP_FP_SCALAR_COMPARE:
    case AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER:
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER:
    case AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION:
    case AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE:
    case AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE:
    case AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT:
    case AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE:
    case AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR:
    case AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR:
    case AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS:
    case AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS:
    case AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE:
    case AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS:
    case AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR:
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_NARROW_WIDEN:
    case AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR:
        return 1;
    default:
        return 0;
    }
}

static int avz_native_kind_terminates_block(uint16_t kind) {
    switch (kind) {
    case AVZ_NATIVE_OP_CBZ:
    case AVZ_NATIVE_OP_TBZ:
    case AVZ_NATIVE_OP_BCOND:
    case AVZ_NATIVE_OP_BRANCH:
    case AVZ_NATIVE_OP_REGISTER_BRANCH:
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE:
    case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
    case AVZ_NATIVE_OP_EXCEPTION_RETURN:
    case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
    case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
    case AVZ_NATIVE_OP_WAIT:
        return 1;
    default:
        return 0;
    }
}

static int avz_native_kind_has_linear_fallthrough(uint16_t kind) {
    return kind == AVZ_NATIVE_OP_CBZ ||
        kind == AVZ_NATIVE_OP_TBZ ||
        kind == AVZ_NATIVE_OP_BCOND;
}

static int avz_instruction_requires_vm_exit(uint32_t instruction, uint16_t kind) {
    return (instruction & UINT32_C(0xfffff0ff)) == UINT32_C(0xd503305f) ||
        kind == AVZ_NATIVE_OP_HALT;
}

static void avz_unlink_page_link(AVZNativeBlockCache *cache, int32_t link_index) {
    AVZBlockPageLink *link = &cache->page_links[link_index];
    if (!link->linked) {
        return;
    }

    avz_untrack_code_page(cache, link->page);
    size_t bucket = avz_page_bucket(link->page);
    if (link->previous >= 0) {
        cache->page_links[link->previous].next = link->next;
    } else {
        cache->page_bucket_heads[bucket] = link->next;
    }
    if (link->next >= 0) {
        cache->page_links[link->next].previous = link->previous;
    }
    *link = (AVZBlockPageLink){.next = -1, .previous = -1, .page = 0, .linked = 0};
}

static void avz_unindex_entry(AVZNativeBlockCache *cache, size_t entry_index) {
    /* Retire private copies BEFORE dropping enrollment or recycling serials. */
    avz_assembly_chain_forget_entry(cache, &cache->entries[entry_index]);
    size_t first_link = entry_index * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES;
    for (size_t slot = 0; slot < AVZ_NATIVE_BLOCK_MAX_CODE_PAGES; slot++) {
        avz_unlink_page_link(cache, (int32_t)(first_link + slot));
    }
}

static void avz_record_prefetch_outcome(
    AVZNativeBlockCache *cache,
    int useful
) {
    enum { AVZ_BATCH_PREFETCH_ADAPTATION_WINDOW = 4096 };
    if (useful) {
        cache->batch_prefetch_window_hits++;
    } else {
        cache->batch_prefetch_window_unused++;
    }
    uint32_t outcomes = cache->batch_prefetch_window_hits +
        cache->batch_prefetch_window_unused;
    if (outcomes < AVZ_BATCH_PREFETCH_ADAPTATION_WINDOW) {
        return;
    }

    uint8_t next_limit;
    if ((uint64_t)cache->batch_prefetch_window_hits * 100u >=
        (uint64_t)outcomes * 80u) {
        next_limit = 3;
    } else if ((uint64_t)cache->batch_prefetch_window_hits * 100u >=
               (uint64_t)outcomes * 65u) {
        next_limit = 2;
    } else if ((uint64_t)cache->batch_prefetch_window_hits * 100u >=
               (uint64_t)outcomes * 55u) {
        next_limit = 1;
    } else {
        next_limit = 0;
    }
    if (next_limit != cache->batch_prefetch_limit) {
        cache->batch_prefetch_limit = next_limit;
        cache->statistics.batch_prefetch_limit_changes++;
        cache->statistics.batch_prefetch_limit = next_limit;
    }
    cache->batch_prefetch_window_hits = 0;
    cache->batch_prefetch_window_unused = 0;
}

static void avz_retire_unused_prefetch(
    AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry
) {
    if (entry->valid && entry->prefetched) {
        cache->statistics.batch_prefetch_unused++;
        entry->prefetched = 0;
        avz_record_prefetch_outcome(cache, 0);
    }
}

static void avz_record_prefetch_hit(
    AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry
) {
    if (!cache->batch_prefetch_active && entry->prefetched) {
        cache->statistics.batch_prefetch_hits++;
        entry->prefetched = 0;
        avz_record_prefetch_outcome(cache, 1);
    }
}

static void avz_touch_entry(
    AVZNativeBlockCache *cache,
    AVZBlockCacheEntry *entry
) {
    avz_advance_nonzero_counter(&cache->access_clock);
    entry->last_used = cache->access_clock;
}

static void avz_link_entry_page(
    AVZNativeBlockCache *cache,
    size_t entry_index,
    size_t slot,
    uint64_t page
) {
    int32_t link_index = (int32_t)(
        entry_index * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES + slot
    );
    size_t bucket = avz_page_bucket(page);
    int32_t old_head = cache->page_bucket_heads[bucket];
    cache->page_links[link_index] = (AVZBlockPageLink){
        .next = old_head,
        .previous = -1,
        .page = page,
        .linked = 1
    };
    if (old_head >= 0) {
        cache->page_links[old_head].previous = link_index;
    }
    cache->page_bucket_heads[bucket] = link_index;
    avz_track_code_page(cache, page);
}

static void avz_index_entry(AVZNativeBlockCache *cache, size_t entry_index) {
    AVZNativeDecodedBlock *block = &cache->entries[entry_index].block;
    uint64_t pages[AVZ_NATIVE_BLOCK_MAX_CODE_PAGES] = {0};
    size_t page_count = 0;

    for (size_t index = 0; index < block->instruction_count; index++) {
        uint64_t page = block->physical_addresses[index] & ~UINT64_C(0xfff);
        int duplicate = 0;
        for (size_t existing = 0; existing < page_count; existing++) {
            duplicate |= pages[existing] == page;
        }
        if (!duplicate && page_count < AVZ_NATIVE_BLOCK_MAX_CODE_PAGES) {
            pages[page_count++] = page;
        }
    }

    for (size_t slot = 0; slot < page_count; slot++) {
        avz_link_entry_page(cache, entry_index, slot, pages[slot]);
        block->physical_code_pages[slot] = pages[slot];
        block->host_code_pages[slot] =
            avz_direct_physical_pointer(cache, pages[slot], 1);
        block->code_page_generation_tokens[slot] =
            avz_code_page_generation_token(cache, pages[slot]);
        block->code_page_generations[slot] =
            block->code_page_generation_tokens[slot] == NULL
                ? 0
                : *block->code_page_generation_tokens[slot];
        block->shared_code_page_generation_tokens[slot] =
            avz_guest_memory_page_write_generation_token(
                cache->guest_memory,
                pages[slot],
                cache->ram_base
            );
        block->shared_code_page_generations[slot] =
            block->shared_code_page_generation_tokens[slot] == NULL
                ? 0
                : __atomic_load_n(
                    block->shared_code_page_generation_tokens[slot],
                    __ATOMIC_ACQUIRE
                );
    }
    block->code_page_count = (uint8_t)page_count;
}

static void avz_discard_stale_entry(
    AVZNativeBlockCache *cache,
    size_t entry_index
) {
    AVZBlockCacheEntry *entry = &cache->entries[entry_index];
    if (!entry->valid) {
        return;
    }
    avz_retire_unused_prefetch(cache, entry);
    avz_unindex_entry(cache, entry_index);
    avz_threaded_forget_entry(cache, entry);
    avz_assembly_forget_entry(cache, entry);
    entry->valid = 0;
    entry->serial = 0;
    entry->validated_code_mutation_epoch = 0;
    avz_advance_nonzero_counter(&cache->mutation_epoch);
    cache->statistics.invalidations++;
    cache->statistics.stale_block_discards++;
}

static void avz_invalidate_entry(AVZNativeBlockCache *cache, size_t entry_index) {
    AVZBlockCacheEntry *entry = &cache->entries[entry_index];
    if (!entry->valid) {
        return;
    }
    avz_retire_unused_prefetch(cache, entry);
    avz_unindex_entry(cache, entry_index);
    avz_threaded_forget_entry(cache, entry);
    avz_assembly_forget_entry(cache, entry);
    entry->valid = 0;
    entry->serial = 0;
    avz_advance_nonzero_counter(&cache->generation);
    avz_advance_nonzero_counter(&cache->mutation_epoch);
    cache->statistics.invalidations++;
}

AVZNativeBlockCache *avz_native_block_cache_create(void) {
    AVZNativeBlockCache *cache = calloc(1, sizeof(*cache));
    if (cache == NULL) {
        return NULL;
    }
#if AVZ_THREADED_PROTOTYPE_ENABLE
    avz_threaded_initialize_lru(cache);
#endif
    cache->generation = 1;
    cache->mutation_epoch = 1;
    cache->code_mutation_epoch = 1;
    cache->reset_epoch = 1;
    cache->batch_prefetch_limit = 3;
    cache->statistics.batch_prefetch_limit = 3;
    cache->entries = calloc(AVZ_BLOCK_CACHE_ENTRY_COUNT, sizeof(*cache->entries));
    cache->page_links = calloc(
        AVZ_BLOCK_CACHE_ENTRY_COUNT * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES,
        sizeof(*cache->page_links)
    );
    cache->page_bucket_heads = malloc(
        AVZ_BLOCK_PAGE_BUCKET_COUNT * sizeof(*cache->page_bucket_heads)
    );
    if (cache->entries == NULL || cache->page_links == NULL ||
        cache->page_bucket_heads == NULL) {
        avz_native_block_cache_destroy(cache);
        return NULL;
    }

    for (size_t index = 0; index < AVZ_BLOCK_PAGE_BUCKET_COUNT; index++) {
        cache->page_bucket_heads[index] = -1;
    }
    for (size_t index = 0;
         index < AVZ_BLOCK_CACHE_ENTRY_COUNT * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES;
         index++) {
        cache->page_links[index].next = -1;
        cache->page_links[index].previous = -1;
    }
    return cache;
}

void avz_native_block_cache_destroy(AVZNativeBlockCache *cache) {
    if (cache == NULL) {
        return;
    }
    avz_assembly_chain_retire(cache);
    avz_assembly_clear(cache);
#if AVZ_THREADED_PROTOTYPE_ENABLE
    for (size_t i = 0; i < 256; i++) {
        avz_threaded_release_slot(cache, i);
    }
#endif
    free(cache->entries);
    free(cache->page_links);
    free(cache->page_bucket_heads);
    free(cache->code_page_refcounts);
    free(cache->code_page_generations);
    free(cache->trace_code_page_bits);
    free(cache);
}

void avz_native_block_cache_clear(AVZNativeBlockCache *cache) {
    if (cache == NULL) {
        return;
    }
    avz_assembly_chain_retire(cache);
    avz_assembly_clear(cache);
#if AVZ_THREADED_PROTOTYPE_ENABLE
    for (size_t i = 0; i < 256; i++) {
        avz_threaded_release_slot(cache, i);
    }
    avz_threaded_initialize_lru(cache);
#endif
    avz_advance_nonzero_counter(&cache->generation);
    avz_advance_nonzero_counter(&cache->mutation_epoch);
    avz_advance_nonzero_counter(&cache->code_mutation_epoch);
    avz_advance_nonzero_counter(&cache->reset_epoch);
    memset(cache->entries, 0, AVZ_BLOCK_CACHE_ENTRY_COUNT * sizeof(*cache->entries));
    cache->access_clock = 0;
    memset(cache->front_entries, 0, sizeof(cache->front_entries));
    cache->last_context_valid = 0;
    cache->decode_window_valid = 0;
    cache->batch_prefetch_active = 0;
    if (cache->code_page_refcounts != NULL) {
        memset(
            cache->code_page_refcounts,
            0,
            cache->tracked_page_count * sizeof(*cache->code_page_refcounts)
        );
    }
    if (cache->trace_code_page_bits != NULL) {
        memset(
            cache->trace_code_page_bits,
            0,
            avz_trace_code_page_byte_count(cache->tracked_page_count)
        );
    }
    for (size_t index = 0; index < AVZ_BLOCK_PAGE_BUCKET_COUNT; index++) {
        cache->page_bucket_heads[index] = -1;
    }
    for (size_t index = 0;
         index < AVZ_BLOCK_CACHE_ENTRY_COUNT * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES;
         index++) {
        cache->page_links[index] = (AVZBlockPageLink){.next = -1, .previous = -1};
    }
}

int avz_native_block_cache_configure_physical_range(
    AVZNativeBlockCache *cache,
    uint64_t physical_address,
    uint64_t byte_count
) {
    if (cache == NULL || byte_count == 0) {
        return 0;
    }

    uint64_t last_address = physical_address + (byte_count - 1);
    if (last_address < physical_address) {
        return 0;
    }
    uint64_t first_page = physical_address & ~UINT64_C(0xfff);
    uint64_t last_page = last_address & ~UINT64_C(0xfff);
    uint64_t page_count_u64 = ((last_page - first_page) >> 12) + 1;
    if (page_count_u64 > SIZE_MAX ||
        (size_t)page_count_u64 > SIZE_MAX / sizeof(uint16_t) ||
        (size_t)page_count_u64 > SIZE_MAX / sizeof(uint64_t)) {
        return 0;
    }
    size_t page_count = (size_t)page_count_u64;
    if (cache->code_page_refcounts != NULL &&
        cache->tracked_first_page == first_page &&
        cache->tracked_page_count == page_count) {
        return 1;
    }

    uint16_t *refcounts = calloc(page_count, sizeof(*refcounts));
    uint64_t *generations = malloc(page_count * sizeof(*generations));
    uint8_t *trace_bits = calloc(
        avz_trace_code_page_byte_count(page_count),
        sizeof(*trace_bits)
    );
    if (refcounts == NULL || generations == NULL || trace_bits == NULL) {
        free(refcounts);
        free(generations);
        free(trace_bits);
        return 0;
    }
    for (size_t index = 0; index < page_count; index++) {
        generations[index] = 1;
    }
    avz_native_block_cache_clear(cache);
    free(cache->code_page_refcounts);
    free(cache->code_page_generations);
    free(cache->trace_code_page_bits);
    cache->code_page_refcounts = refcounts;
    cache->code_page_generations = generations;
    cache->trace_code_page_bits = trace_bits;
    cache->tracked_first_page = first_page;
    cache->tracked_page_count = page_count;
    cache->ram = NULL;
    cache->ram_base = 0;
    cache->ram_size = 0;

    return 1;
}

int avz_native_block_cache_bind_physical_memory(
    AVZNativeBlockCache *cache,
    uint8_t *ram,
    uint64_t physical_address,
    uint64_t byte_count
) {
    if (cache == NULL || ram == NULL || byte_count == 0 ||
        physical_address > UINT64_MAX - (byte_count - 1)) {
        return 0;
    }
    uint64_t first_page = physical_address & ~UINT64_C(0xfff);
    uint64_t last_page = (physical_address + byte_count - 1) &
        ~UINT64_C(0xfff);
    size_t page_count = (size_t)(((last_page - first_page) >> 12) + 1);
    int range_matches = cache->code_page_refcounts != NULL &&
        cache->tracked_first_page == first_page &&
        cache->tracked_page_count == page_count;
    if (cache->ram == ram && cache->ram_base == physical_address &&
        cache->ram_size == byte_count && range_matches) {
        return 1;
    }

    if (range_matches) {
        avz_native_block_cache_clear(cache);
    } else if (!avz_native_block_cache_configure_physical_range(
        cache,
        physical_address,
        byte_count
    )) {
        return 0;
    }
    cache->ram = ram;
    cache->ram_base = physical_address;
    cache->ram_size = byte_count;
    return 1;
}

void avz_native_block_cache_set_guest_memory(
    AVZNativeBlockCache *cache,
    AVZGuestMemory *memory
) {
    if (cache == NULL || cache->guest_memory == memory) {
        return;
    }
    cache->guest_memory = memory;
    avz_native_block_cache_clear(cache);
}

void avz_native_block_cache_invalidate_decode_window(
    AVZNativeBlockCache *cache
) {
    if (cache != NULL) {
        cache->decode_window_valid = 0;
    }
}

void avz_native_block_cache_invalidate_translation_mappings(AVZNativeBlockCache *cache) {
    if (cache == NULL) return;
    avz_assembly_chain_retire(cache);
    cache->decode_window_valid = 0;
    avz_advance_nonzero_counter(&cache->translation_epoch);
    /* Existing chain/link guards already observe this token. Physical code
     * generations and decoded contents remain untouched. */
    avz_advance_nonzero_counter(&cache->code_mutation_epoch);
}

void avz_native_block_cache_set_mapping_validator(
    AVZNativeBlockCache *cache,
    AVZNativeInstructionMappingValidateCallback validate,
    void *context
) {
    if (cache == NULL) return;
    if (cache->validate_mapping == validate && cache->mapping_context == context) return;
    cache->validate_mapping = validate;
    cache->mapping_context = context;
    avz_native_block_cache_invalidate_translation_mappings(cache);
}

static int avz_decode_block(
    AVZNativeBlockCache *cache,
    AVZNativeDecodedBlock *block,
    const AVZNativeBlockKey *key,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    uint32_t *unsupported_instruction
) {
    memset(block, 0, sizeof(*block));
    block->key = *key;

    uint64_t pc = key->pc;
    uint64_t direct_virtual_page = 0;
    uint64_t direct_physical_address = 0;
    int direct_fetch_valid = 0;
    uint64_t key_virtual_page = pc >> 12;
    if (cache->decode_window_valid &&
        cache->decode_window_virtual_page == key_virtual_page &&
        avz_block_contexts_equal(&cache->decode_window_key, key)) {
        uint64_t page_offset = pc & UINT64_C(0xfff);
        if (cache->decode_window_physical_page <=
            UINT64_MAX - page_offset) {
            direct_virtual_page = key_virtual_page;
            direct_physical_address =
                cache->decode_window_physical_page + page_offset;
            direct_fetch_valid = avz_direct_physical_pointer(
                cache,
                direct_physical_address,
                sizeof(uint32_t)
            ) != NULL;
        }
        if (direct_fetch_valid) {
            cache->statistics.decode_window_hits++;
        } else {
            cache->decode_window_valid = 0;
            cache->statistics.decode_window_misses++;
        }
    } else {
        cache->statistics.decode_window_misses++;
    }
    for (size_t index = 0; index < AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS; index++) {
        uint64_t physical_address = 0;
        uint32_t raw = 0;
        const uint8_t *direct = NULL;
        if (direct_fetch_valid && (pc >> 12) == direct_virtual_page) {
            direct = avz_direct_physical_pointer(
                cache,
                direct_physical_address,
                sizeof(raw)
            );
        }
        if (direct != NULL) {
            physical_address = direct_physical_address;
            memcpy(&raw, direct, sizeof(raw));
            cache->statistics.direct_code_fetches++;
        } else if (!fetch_instruction(
            fetch_context,
            pc,
            &physical_address,
            &raw
        )) {
            if (block->instruction_count == 0) {
                return AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT;
            }
            avz_classify_block_semantics(block);
            return AVZ_NATIVE_BLOCK_DECODE_OK;
        }

        direct_virtual_page = pc >> 12;
        direct_physical_address = physical_address + sizeof(raw);
        direct_fetch_valid = physical_address <= UINT64_MAX - sizeof(raw) &&
            (physical_address & UINT64_C(0xfff)) ==
                (pc & UINT64_C(0xfff)) &&
            avz_direct_physical_pointer(
                cache,
                physical_address,
                sizeof(raw)
            ) != NULL;
        if (direct_fetch_valid) {
            uint64_t page_offset = pc & UINT64_C(0xfff);
            cache->decode_window_key = *key;
            cache->decode_window_virtual_page = pc >> 12;
            cache->decode_window_physical_page = physical_address - page_offset;
            cache->decode_window_valid = 1;
        }

        AVZNativeInstruction decoded;
        if (!avz_native_decode_instruction(raw, &decoded) ||
            avz_instruction_requires_vm_exit(raw, decoded.kind)) {
            if (block->instruction_count == 0) {
                if (unsupported_instruction != NULL) {
                    *unsupported_instruction = raw;
                }
                return AVZ_NATIVE_BLOCK_DECODE_UNSUPPORTED;
            }
            break;
        }

        block->instructions[index] = decoded;
        block->physical_addresses[index] = physical_address;
        block->instruction_count++;
        block->uses_vector_state |= (uint8_t)avz_native_kind_uses_vector_state(decoded.kind);
        avz_record_block_exit_metadata(block, &decoded);
        if (avz_native_kind_terminates_block(decoded.kind) ||
            (decoded.kind == AVZ_NATIVE_OP_BARRIER &&
             (raw & UINT32_C(0xfffff0ff)) == UINT32_C(0xd50330df))) {
            break;
        }
        pc += 4;
    }
    avz_classify_block_semantics(block);
    return AVZ_NATIVE_BLOCK_DECODE_OK;
}

const AVZNativeDecodedBlock *avz_native_block_cache_get_or_decode(
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    uint32_t *decode_status,
    uint32_t *unsupported_instruction
) {
    if (decode_status != NULL) {
        *decode_status = AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT;
    }
    if (unsupported_instruction != NULL) {
        *unsupported_instruction = 0;
    }
    if (cache == NULL || key == NULL || fetch_instruction == NULL) {
        return NULL;
    }

    AVZNativeBlockKey canonical_key = avz_canonical_block_key(key);
    key = &canonical_key;

    uint64_t hash = avz_block_key_hash(cache, key);
    size_t front_index =
        (size_t)(hash & (AVZ_BLOCK_FRONT_CACHE_ENTRY_COUNT - 1));
    AVZBlockFrontCacheEntry *front = &cache->front_entries[front_index];
    if (front->valid && front->hash == hash && front->entry_index >= 0 &&
        front->entry_index < AVZ_BLOCK_CACHE_ENTRY_COUNT) {
        size_t entry_index = (size_t)front->entry_index;
        AVZBlockCacheEntry *entry = &cache->entries[entry_index];
        if (entry->valid && avz_block_keys_equal(&entry->block.key, key) &&
            !avz_entry_code_is_current(cache, entry)) {
            avz_discard_stale_entry(cache, entry_index);
        } else if (entry->valid && avz_block_keys_equal(&entry->block.key, key)) {
            cache->statistics.hits++;
            cache->statistics.front_hits++;
            avz_record_prefetch_hit(cache, entry);
            avz_touch_entry(cache, entry);
            if (decode_status != NULL) {
                *decode_status = AVZ_NATIVE_BLOCK_DECODE_OK;
            }
            return &entry->block;
        }
    }

    size_t set = avz_block_set_index(hash);
    size_t base = set * AVZ_BLOCK_CACHE_WAY_COUNT;
    size_t first_invalid = SIZE_MAX;
    for (size_t way = 0; way < AVZ_BLOCK_CACHE_WAY_COUNT; way++) {
        size_t entry_index = base + way;
        AVZBlockCacheEntry *entry = &cache->entries[entry_index];
        if (entry->valid && avz_block_keys_equal(&entry->block.key, key) &&
            !avz_entry_code_is_current(cache, entry)) {
            avz_discard_stale_entry(cache, entry_index);
        } else if (entry->valid && avz_block_keys_equal(&entry->block.key, key)) {
            cache->statistics.hits++;
            avz_record_prefetch_hit(cache, entry);
            avz_touch_entry(cache, entry);
            if (decode_status != NULL) {
                *decode_status = AVZ_NATIVE_BLOCK_DECODE_OK;
            }
            avz_update_front_cache(cache, hash, entry_index);
            return &entry->block;
        }
        if (!entry->valid && first_invalid == SIZE_MAX) {
            first_invalid = entry_index;
        }
    }

    cache->statistics.misses++;
    AVZNativeDecodedBlock decoded;
    int status = avz_decode_block(
        cache,
        &decoded,
        key,
        fetch_instruction,
        fetch_context,
        unsupported_instruction
    );
    if (decode_status != NULL) {
        *decode_status = (uint32_t)status;
    }
    if (status != AVZ_NATIVE_BLOCK_DECODE_OK || decoded.instruction_count == 0) {
        return NULL;
    }

    size_t entry_index = first_invalid;
    if (entry_index == SIZE_MAX) {
        entry_index = base;
        for (size_t way = 1; way < AVZ_BLOCK_CACHE_WAY_COUNT; way++) {
            size_t candidate_index = base + way;
            AVZBlockCacheEntry *candidate = &cache->entries[candidate_index];
            AVZBlockCacheEntry *victim = &cache->entries[entry_index];
            if ((candidate->prefetched && !victim->prefetched) ||
                (candidate->prefetched == victim->prefetched &&
                 candidate->last_used < victim->last_used)) {
                entry_index = candidate_index;
            }
        }
        avz_retire_unused_prefetch(cache, &cache->entries[entry_index]);
        avz_unindex_entry(cache, entry_index);
        avz_threaded_forget_entry(cache, &cache->entries[entry_index]);
        avz_assembly_forget_entry(cache, &cache->entries[entry_index]);
        cache->entries[entry_index].serial = 0;
        avz_advance_nonzero_counter(&cache->mutation_epoch);
        cache->statistics.evictions++;
    }

    cache->entries[entry_index].block = decoded;
    cache->entries[entry_index].serial = avz_allocate_block_serial(cache);
    cache->entries[entry_index].validated_code_mutation_epoch =
        cache->code_mutation_epoch;
    cache->entries[entry_index].validated_shared_code_mutation_epoch =
        avz_native_block_cache_shared_code_mutation_epoch(cache);
    cache->entries[entry_index].validated_translation_epoch = cache->translation_epoch;
    cache->entries[entry_index].valid = 1;
    cache->entries[entry_index].prefetched = cache->batch_prefetch_active;
    avz_touch_entry(cache, &cache->entries[entry_index]);
    avz_index_entry(cache, entry_index);
    avz_update_front_cache(cache, hash, entry_index);
    cache->statistics.decodes++;
    const AVZNativeDecodedBlock *result =
        &cache->entries[entry_index].block;

    if (!cache->batch_prefetch_active && cache->ram != NULL &&
        cache->batch_prefetch_limit != 0) {
        cache->batch_prefetch_active = 1;
        const AVZNativeDecodedBlock *current = result;
        size_t protected_set = set;
        for (size_t batch_index = 0;
             batch_index < cache->batch_prefetch_limit;
             batch_index++) {
            size_t count = current->instruction_count;
            if (count == 0 ||
                !avz_native_kind_has_linear_fallthrough(
                    current->instructions[count - 1].kind
                ) ||
                current->key.pc > UINT64_MAX - count * 4u) {
                break;
            }
            AVZNativeBlockKey next_key = current->key;
            next_key.pc += count * 4u;
            if ((next_key.pc >> 12) != (key->pc >> 12)) {
                break;
            }
            uint64_t next_hash = avz_block_key_hash(cache, &next_key);
            if (avz_block_set_index(next_hash) == protected_set) {
                break;
            }

            uint64_t decodes_before = cache->statistics.decodes;
            uint32_t next_status = AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT;
            uint32_t next_unsupported = 0;
            const AVZNativeDecodedBlock *next =
                avz_native_block_cache_get_or_decode(
                    cache,
                    &next_key,
                    fetch_instruction,
                    fetch_context,
                    &next_status,
                    &next_unsupported
                );
            if (next == NULL || next_status != AVZ_NATIVE_BLOCK_DECODE_OK) {
                break;
            }
            if (cache->statistics.decodes != decodes_before) {
                cache->statistics.batch_prefetched_blocks++;
            }
            current = next;
        }
        cache->batch_prefetch_active = 0;
    }
    return result;
}

void avz_native_block_cache_invalidate_physical_range(
    AVZNativeBlockCache *cache,
    uint64_t physical_address,
    uint64_t byte_count
) {
    if (cache == NULL || byte_count == 0) {
        return;
    }
    uint64_t last_address = physical_address + (byte_count - 1);
    if (last_address < physical_address) {
        last_address = UINT64_MAX;
    }
    uint64_t first_page = physical_address & ~UINT64_C(0xfff);
    uint64_t last_page = last_address & ~UINT64_C(0xfff);
    cache->statistics.invalidation_checks++;
    if (!avz_range_may_contain_code(cache, physical_address, last_address)) {
        cache->statistics.invalidation_skips++;
        return;
    }

    avz_assembly_chain_retire(cache);

    uint64_t tracked_last_page = cache->tracked_page_count == 0
        ? 0
        : cache->tracked_first_page +
            ((uint64_t)(cache->tracked_page_count - 1) << 12);
    if (cache->code_page_generations != NULL &&
        first_page >= cache->tracked_first_page &&
        last_page <= tracked_last_page) {
        int bumped = 0;
        for (uint64_t page = first_page;; page += UINT64_C(0x1000)) {
            size_t page_index = (size_t)(
                (page - cache->tracked_first_page) >> 12
            );
            if (cache->code_page_refcounts[page_index] != 0 ||
                avz_trace_code_page_is_registered(cache, page_index)) {
                avz_advance_nonzero_counter(
                    &cache->code_page_generations[page_index]
                );
                cache->statistics.code_page_generation_bumps++;
                bumped = 1;
            }
            if (page == last_page) {
                break;
            }
        }
        if (bumped) {
            avz_advance_nonzero_counter(&cache->code_mutation_epoch);
        } else {
            cache->statistics.invalidation_skips++;
        }
        return;
    }

    for (uint64_t page = first_page;; page += UINT64_C(0x1000)) {
        size_t bucket = avz_page_bucket(page);
        int32_t link_index = cache->page_bucket_heads[bucket];
        while (link_index >= 0) {
            AVZBlockPageLink *link = &cache->page_links[link_index];
            int32_t next = link->next;
            if (link->linked && link->page == page) {
                size_t entry_index =
                    (size_t)link_index / AVZ_NATIVE_BLOCK_MAX_CODE_PAGES;
                AVZBlockCacheEntry *entry = &cache->entries[entry_index];
                int overlaps = 0;
                for (size_t index = 0; index < entry->block.instruction_count; index++) {
                    uint64_t instruction_address = entry->block.physical_addresses[index];
                    uint64_t instruction_last = instruction_address > UINT64_MAX - 3
                        ? UINT64_MAX
                        : instruction_address + 3;
                    overlaps |= instruction_address <= last_address &&
                        instruction_last >= physical_address;
                }
                if (overlaps) {
                    avz_invalidate_entry(cache, entry_index);
                }
            }
            link_index = next;
        }
        if (page == last_page || page > UINT64_MAX - UINT64_C(0x1000)) {
            break;
        }
    }
}

AVZNativeBlockCacheStatistics avz_native_block_cache_statistics(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? (AVZNativeBlockCacheStatistics){0} : cache->statistics;
}

const AVZNativeInstruction *avz_native_decoded_block_instructions(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL ? NULL : block->instructions;
}

AVZAssemblyCacheDiagnostics avz_native_block_cache_diagnostics_snapshot(
    const AVZNativeBlockCache *cache
) {
    AVZAssemblyCacheDiagnostics result = {0};
#if AVZ_AC_DIAGNOSTICS
    if (cache) result = cache->assembly_diagnostics;
    result.compiled = 1;
#endif
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
    result.program_capacity = AVZ_BLOCK_CACHE_ENTRY_COUNT;
    result.program_byte_budget = AVZ_ASSEMBLY_CACHE_BYTE_BUDGET;
    result.protected_byte_budget = AVZ_ASSEMBLY_CACHE_PROTECTED_BUDGET;
    result.max_retirements_per_admission = AVZ_ASSEMBLY_CACHE_MAX_RETIREMENTS;
    result.assembly_slot_storage_bytes = AVZ_BLOCK_CACHE_ENTRY_COUNT *
        sizeof(AVZAssemblyRetention) + sizeof(cache->assembly_heads) +
        sizeof(cache->assembly_tails) + sizeof(cache->assembly_bytes) +
        sizeof(cache->assembly_count);
#endif
    if (!cache) return result;
    result.cache_storage_bytes = sizeof(*cache);
    if (cache->entries) result.cache_storage_bytes +=
        AVZ_BLOCK_CACHE_ENTRY_COUNT * sizeof(*cache->entries);
    if (cache->page_links) result.cache_storage_bytes +=
        AVZ_BLOCK_CACHE_ENTRY_COUNT * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES *
        sizeof(*cache->page_links);
    if (cache->page_bucket_heads) result.cache_storage_bytes +=
        AVZ_BLOCK_PAGE_BUCKET_COUNT * sizeof(*cache->page_bucket_heads);
    if (cache->code_page_refcounts) result.cache_storage_bytes +=
        cache->tracked_page_count * sizeof(*cache->code_page_refcounts);
    if (cache->code_page_generations) result.cache_storage_bytes +=
        cache->tracked_page_count * sizeof(*cache->code_page_generations);
    if (cache->trace_code_page_bits) result.cache_storage_bytes +=
        avz_trace_code_page_byte_count(cache->tracked_page_count);
    result.cache_owned_programs = 0;
    result.cache_owned_program_bytes = 0;
#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
    result.cache_owned_programs = cache->assembly_count;
    result.cache_owned_program_bytes = cache->assembly_bytes[0] + cache->assembly_bytes[1];
    result.protected_program_bytes = cache->assembly_bytes[1];
#endif
    return result;
}

int avz_native_block_cache_diagnostics_begin(AVZNativeBlockCache *cache,
    uint32_t flags
) {
#if AVZ_AC_DIAGNOSTICS
    if (!cache || (flags & ~(AVZ_CACHE_DIAGNOSTICS_COUNTS |
                            AVZ_CACHE_DIAGNOSTICS_PREPARATION_TIME))) return 0;
    memset(&cache->assembly_diagnostics, 0, sizeof(cache->assembly_diagnostics));
    for (size_t i = 0; i < AVZ_BLOCK_CACHE_ENTRY_COUNT; i++)
        cache->entries[i].assembly.hits = 0;
    cache->assembly_diagnostics = avz_native_block_cache_diagnostics_snapshot(cache);
    AVZAssemblyCacheDiagnostics *d = &cache->assembly_diagnostics;
    d->enabled = flags != 0;
    d->timing_enabled = (flags & AVZ_CACHE_DIAGNOSTICS_PREPARATION_TIME) != 0;
    d->peak_cache_owned_programs = d->cache_owned_programs;
    d->peak_cache_owned_program_bytes = d->cache_owned_program_bytes;
    d->peak_preparation_live_bytes = d->cache_owned_program_bytes;
    return 1;
#else
    (void)cache;
    (void)flags;
    return 0;
#endif
}

#if AVZ_AC_DIAGNOSTICS
static int avz_assembly_diagnostic_clock(uint64_t *ns) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    *ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    return 1;
}
#endif

#if AVZ_ASSEMBLY_EXECUTOR_ENABLE
const AGProgram *avz_assembly_cache_program(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, int allow_memory) {
    AVZBlockCacheEntry *entry = (AVZBlockCacheEntry *)avz_entry_for_block(cache, block);
    AVZ_AC_COUNT(cache, requests);
    if (!entry || !entry->valid || !entry->serial || !block->instruction_count) {
        AVZ_AC_COUNT(cache, invalid_requests);
        return NULL;
    }
    if (!avz_entry_code_is_current(cache, entry)) {
        AVZ_AC_COUNT(cache, stale_requests);
        avz_assembly_forget_entry(cache, entry);
        return NULL;
    }
    if (entry->assembly_capability == 3 ||
        (entry->assembly_capability == 2 && !allow_memory)) {
        AVZ_AC_COUNT(cache, negative_hits);
#if AVZ_AC_DIAGNOSTICS
        if (entry->assembly_capability == 2) AVZ_AC_COUNT(cache, negative_memory_hits);
        else if (entry->assembly_rejection == 1) AVZ_AC_COUNT(cache, negative_semantic_hits);
        else if (entry->assembly_rejection == 2) AVZ_AC_COUNT(cache, negative_unsupported_hits);
        else if (entry->assembly_rejection == 3) AVZ_AC_COUNT(cache, negative_null_hits);
#endif
        return NULL;
    }
    if (!entry->assembly_capability) {
        AVZ_AC_COUNT(cache, eligibility_scans);
        /* Preserve existing bulk/string/PLT accelerators and opportunities to
         * compose their mapped traces. Subset coverage is not a speed proof. */
        for (size_t i = 0; i < block->instruction_count; i++) {
            if (block->semantic_candidates[i] || block->trace_semantic_candidates[i]) {
                entry->assembly_capability = 3;
                AVZ_AC_COUNT(cache, semantic_rejections);
#if AVZ_AC_DIAGNOSTICS
                entry->assembly_rejection = 1;
#endif
                return NULL;
            }
        }
    }
    if (entry->assembly.program) {
        AVZ_AC_COUNT(cache, program_hits);
#if AVZ_AC_DIAGNOSTICS
        if (cache->assembly_diagnostics.enabled)
            entry->assembly.hits++;
#endif
        avz_assembly_record_reuse(cache, entry);
        return entry->assembly.program;
    }
    AVZ_AC_COUNT(cache, program_misses);
#if AVZ_AC_DIAGNOSTICS
    if (entry->assembly_was_admitted) AVZ_AC_COUNT(cache, positive_repreparations);
#endif
    uint32_t words[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    for (size_t i = 0; i < block->instruction_count; i++) words[i] = block->instructions[i].raw;
    AVZ_AC_COUNT(cache, preparation_attempts);
#if AVZ_AC_DIAGNOSTICS
    AVZAssemblyCacheDiagnostics *d = &cache->assembly_diagnostics;
    uint64_t started = 0, finished = 0;
    int timed = d->timing_enabled;
    int clock_started = timed && avz_assembly_diagnostic_clock(&started);
#endif
    AGProgram *program = ag_create(words, block->instruction_count, block->key.pc);
    unsigned capability = ag_program_capabilities(program);
#if AVZ_AC_DIAGNOSTICS
    if (timed) {
        int clock_finished = avz_assembly_diagnostic_clock(&finished);
        if (clock_started && clock_finished && finished >= started) {
            uint64_t elapsed = finished - started;
            d->preparation_timed_samples++;
            d->preparation_ns += elapsed;
            if (elapsed > d->preparation_max_ns) d->preparation_max_ns = elapsed;
        } else d->preparation_clock_failures++;
    }
    if (d->enabled) {
        if (program) {
            d->program_allocations++;
            uint64_t bytes = ag_program_bytes(program);
            d->allocated_program_bytes += bytes;
            if (d->cache_owned_program_bytes + bytes > d->peak_preparation_live_bytes)
                d->peak_preparation_live_bytes = d->cache_owned_program_bytes + bytes;
        } else d->preparation_null_results++;
    }
    if (!capability) entry->assembly_rejection = program ? 2 : 3;
#endif
    entry->assembly_capability = capability ? capability : 3;
    if (!capability || (capability == 2 && !allow_memory)) {
        if (program && !capability) AVZ_AC_COUNT(cache, unsupported_preparations);
        if (capability == 2) AVZ_AC_COUNT(cache, memory_denied_preparations);
        if (program) AVZ_AC_COUNT(cache, transient_releases);
        ag_destroy(program);
        return NULL;
    }
    size_t bytes = ag_program_bytes(program);
    if (!avz_assembly_make_room(cache, bytes)) {
        AVZ_AC_COUNT(cache, budget_rejections);
        AVZ_AC_COUNT(cache, transient_releases);
        ag_destroy(program);
        return NULL;
    }
    entry->assembly.program = program;
    entry->assembly.bytes = bytes;
    avz_assembly_append(cache, entry, 0);
    cache->assembly_count++;
    AVZ_AC_COUNT(cache, admissions);
#if AVZ_AC_DIAGNOSTICS
    entry->assembly_was_admitted = 1;
    if (d->enabled) {
        d->cache_owned_programs++;
        d->cache_owned_program_bytes += ag_program_bytes(program);
        if (d->cache_owned_programs > d->peak_cache_owned_programs)
            d->peak_cache_owned_programs = d->cache_owned_programs;
        if (d->cache_owned_program_bytes > d->peak_cache_owned_program_bytes)
            d->peak_cache_owned_program_bytes = d->cache_owned_program_bytes;
    }
#endif
    return program;
}
#endif

#if AVZ_THREADED_PROTOTYPE_ENABLE
const AVZThreadedPrototype *avz_native_block_cache_threaded_program(
    AVZNativeBlockCache *cache, const AVZNativeDecodedBlock *block
) {
    return avz_native_block_cache_threaded_program_with_memory(cache, block, 0);
}

const AVZThreadedPrototype *avz_native_block_cache_threaded_program_with_memory(
    AVZNativeBlockCache *cache, const AVZNativeDecodedBlock *block, uint8_t allow_memory
) {
    AVZBlockCacheEntry *entry = (AVZBlockCacheEntry *)avz_entry_for_block(cache, block);
    if (entry == NULL || !entry->valid || entry->serial == 0 ||
        block->instruction_count < 2) {
        return NULL;
    }
    if (!avz_entry_code_is_current(cache, entry)) {
        avz_threaded_forget_entry(cache, entry);
        return NULL;
    }
    if (entry->threaded_eligibility == 2 || entry->threaded_eligibility == 3 ||
        (entry->threaded_eligibility == 4 && !allow_memory)) {
        AVZ_TC_COUNT(cache, negative_hits);
        return NULL;
    }
    if (entry->threaded_slot != 0) {
        size_t slot = entry->threaded_slot - 1u;
        AVZ_TC_COUNT(cache, hits);
        return cache->threaded_programs[slot].program;
    }
    if (entry->threaded_eligibility == 0) {
        AVZ_TC_COUNT(cache, eligibility_scans);
        int needs_memory = 0;
        for (size_t i = 0; i < block->instruction_count; i++) {
            if (!avz_tp_supports_instruction(&block->instructions[i])) {
                if (!avz_tp_supports_instruction_with_memory(&block->instructions[i])) {
                    entry->threaded_eligibility = 2;
                    return NULL;
                }
                needs_memory = 1;
            }
        }
        entry->threaded_eligibility = needs_memory ? 4 : 1;
        if (needs_memory && !allow_memory) return NULL;
    }
    size_t slot = cache->threaded_lru;
    if (cache->threaded_programs[slot].program != NULL) {
        AVZ_TC_COUNT(cache, collisions);
        avz_threaded_release_slot(cache, slot);
    }
    uint32_t words[AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS];
    for (size_t i = 0; i < block->instruction_count; i++) {
        words[i] = block->instructions[i].raw;
    }
    /* At most 256 cache-owned programs. Retired running snapshots live only
     * until their active calls return and cannot be selected again. */
    cache->threaded_programs[slot].program = avz_tp_create(
        words, block->instruction_count, block->key.pc);
    if (cache->threaded_programs[slot].program == NULL) {
        entry->threaded_eligibility = 3;
        AVZ_TC_COUNT(cache, allocation_failures);
        return NULL;
    }
    AVZ_TC_COUNT(cache, creations);
    cache->threaded_programs[slot].owner = entry;
    avz_threaded_touch_slot(cache, slot);
    entry->threaded_slot = (uint16_t)(slot + 1u);
    return cache->threaded_programs[slot].program;
}
#endif

const uint8_t *avz_native_decoded_block_semantic_candidates(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL ? NULL : block->semantic_candidates;
}

const uint8_t *avz_native_decoded_block_trace_semantic_candidates(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL ? NULL : block->trace_semantic_candidates;
}

size_t avz_native_decoded_block_instruction_count(const AVZNativeDecodedBlock *block) {
    return block == NULL ? 0 : block->instruction_count;
}

uint64_t avz_native_decoded_block_pc(const AVZNativeDecodedBlock *block) {
    return block == NULL ? 0 : block->key.pc;
}

int avz_native_decoded_block_uses_vector_state(const AVZNativeDecodedBlock *block) {
    return block != NULL && block->uses_vector_state;
}

int avz_native_decoded_block_is_chain_barrier(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL || block->chain_barrier;
}

int avz_native_decoded_block_requires_host_checkpoint(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL || block->requires_host_checkpoint;
}

size_t avz_native_decoded_block_code_page_count(
    const AVZNativeDecodedBlock *block
) {
    return block == NULL ? 0 : block->code_page_count;
}

uint64_t avz_native_decoded_block_physical_code_page(
    const AVZNativeDecodedBlock *block,
    size_t index
) {
    return block == NULL || index >= block->code_page_count
        ? 0
        : block->physical_code_pages[index];
}

const uint8_t *avz_native_decoded_block_host_code_page(
    const AVZNativeDecodedBlock *block,
    size_t index
) {
    return block == NULL || index >= block->code_page_count
        ? NULL
        : block->host_code_pages[index];
}

int avz_native_block_cache_register_trace_code_page(
    AVZNativeBlockCache *cache,
    uint64_t physical_code_page,
    const uint64_t **generation_token,
    uint64_t *generation
) {
    if (generation_token != NULL) {
        *generation_token = NULL;
    }
    if (generation != NULL) {
        *generation = 0;
    }
    if (cache == NULL || cache->trace_code_page_bits == NULL ||
        (physical_code_page & UINT64_C(0xfff)) != 0 ||
        physical_code_page < cache->tracked_first_page) {
        return 0;
    }
    uint64_t page_index_u64 =
        (physical_code_page - cache->tracked_first_page) >> 12;
    if (page_index_u64 >= cache->tracked_page_count) {
        return 0;
    }
    size_t page_index = (size_t)page_index_u64;
    const uint64_t *token = &cache->code_page_generations[page_index];
    cache->trace_code_page_bits[page_index >> 3] |=
        (uint8_t)(1u << (page_index & 7u));
    avz_guest_memory_mark_code_page(
        cache->guest_memory,
        physical_code_page,
        cache->ram_base
    );
    if (generation_token != NULL) {
        *generation_token = token;
    }
    if (generation != NULL) {
        *generation = *token;
    }
    return 1;
}

uint64_t avz_native_decoded_block_serial(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
) {
    const AVZBlockCacheEntry *entry = avz_entry_for_block(cache, block);
    return entry != NULL && entry->valid ? entry->serial : 0;
}

const uint64_t *avz_native_decoded_block_serial_token(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
) {
    const AVZBlockCacheEntry *entry = avz_entry_for_block(cache, block);
    return entry != NULL ? &entry->serial : NULL;
}

static int avz_successor_is_current(
    AVZNativeBlockCache *cache,
    const AVZBlockSuccessor *successor
) {
    return successor->target != NULL &&
        successor->target_serial != 0 &&
        successor->target_serial_token != NULL &&
        *successor->target_serial_token == successor->target_serial &&
        avz_native_decoded_block_code_is_current(cache, successor->target);
}

static const AVZNativeDecodedBlock *avz_find_successor(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *target_key,
    int match_pc,
    uint64_t *target_serial
) {
    if (target_serial != NULL) {
        *target_serial = 0;
    }
    AVZBlockCacheEntry *source_entry = (AVZBlockCacheEntry *)
        avz_entry_for_block(cache, source);
    if (source_entry == NULL || !source_entry->valid || source_serial == 0 ||
        source_entry->serial != source_serial || target_key == NULL ||
        !avz_entry_code_is_current(cache, source_entry)) {
        return NULL;
    }

    AVZNativeDecodedBlock *mutable_source = &source_entry->block;
    AVZBlockSuccessor *best = NULL;
    for (size_t index = 0; index < 2; index++) {
        AVZBlockSuccessor *candidate = &mutable_source->successors[index];
        if (!avz_successor_is_current(cache, candidate)) {
            continue;
        }
        int matches = match_pc
            ? avz_block_keys_equal(&candidate->target->key, target_key)
            : avz_block_contexts_equal(&candidate->target->key, target_key);
        if (matches && (best == NULL || candidate->last_used > best->last_used)) {
            best = candidate;
        }
    }
    if (best == NULL) {
        return NULL;
    }
    mutable_source->successor_clock++;
    if (mutable_source->successor_clock == 0) {
        mutable_source->successor_clock = 1;
    }
    best->last_used = mutable_source->successor_clock;
    if (target_serial != NULL) {
        *target_serial = best->target_serial;
    }
    return best->target;
}

const AVZNativeDecodedBlock *avz_native_decoded_block_find_successor(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *target_key,
    uint64_t *target_serial
) {
    return avz_find_successor(
        cache, source, source_serial, target_key, 1, target_serial
    );
}

const AVZNativeDecodedBlock *avz_native_decoded_block_find_recent_successor(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *target_context,
    uint64_t *target_serial
) {
    return avz_find_successor(
        cache, source, source_serial, target_context, 0, target_serial
    );
}

void avz_native_decoded_block_record_successor(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeDecodedBlock *target,
    uint64_t target_serial
) {
    AVZBlockCacheEntry *source_entry = (AVZBlockCacheEntry *)
        avz_entry_for_block(cache, source);
    const AVZBlockCacheEntry *target_entry = avz_entry_for_block(cache, target);
    if (source_entry == NULL || target_entry == NULL ||
        !source_entry->valid || !target_entry->valid ||
        source_serial == 0 || target_serial == 0 ||
        source_entry->serial != source_serial ||
        target_entry->serial != target_serial ||
        !avz_entry_code_is_current(cache, source_entry) ||
        !avz_entry_code_is_current(cache, (AVZBlockCacheEntry *)target_entry)) {
        return;
    }

    AVZNativeDecodedBlock *mutable_source = &source_entry->block;
    AVZBlockSuccessor *slot = NULL;
    AVZBlockSuccessor *oldest = &mutable_source->successors[0];
    for (size_t index = 0; index < 2; index++) {
        AVZBlockSuccessor *candidate = &mutable_source->successors[index];
        if (candidate->target == target &&
            candidate->target_serial == target_serial) {
            slot = candidate;
            break;
        }
        if (!avz_successor_is_current(cache, candidate)) {
            slot = candidate;
            break;
        }
        if (candidate->last_used < oldest->last_used) {
            oldest = candidate;
        }
    }
    if (slot == NULL) {
        slot = oldest;
    }
    mutable_source->successor_clock++;
    if (mutable_source->successor_clock == 0) {
        mutable_source->successor_clock = 1;
    }
    *slot = (AVZBlockSuccessor){
        .target = target,
        .target_serial_token = &target_entry->serial,
        .target_serial = target_serial,
        .last_used = mutable_source->successor_clock
    };
}

int avz_native_decoded_block_code_is_current(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
) {
    AVZBlockCacheEntry *entry = (AVZBlockCacheEntry *)avz_entry_for_block(
        cache,
        block
    );
    return entry != NULL && entry->valid &&
        avz_entry_code_is_current(cache, entry);
}

int avz_native_block_cache_validate_block(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block,
    uint64_t serial,
    const AVZNativeBlockKey *key
) {
    const AVZBlockCacheEntry *entry = avz_entry_for_block(cache, block);
    return entry != NULL && entry->valid && serial != 0 &&
        entry->serial == serial &&
        avz_block_code_pages_are_current(&entry->block) &&
        avz_block_shared_code_pages_are_current(cache, &entry->block) &&
        (key == NULL || avz_block_keys_equal(&entry->block.key, key));
}

uint64_t avz_native_block_cache_generation(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? 0 : cache->generation;
}

uint64_t avz_native_block_cache_mutation_epoch(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? 0 : cache->mutation_epoch;
}

uint64_t avz_native_block_cache_code_mutation_epoch(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? 0 : cache->code_mutation_epoch;
}

uint64_t avz_native_block_cache_shared_code_mutation_epoch(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL
        ? 0
        : avz_guest_memory_code_mutation_epoch(cache->guest_memory);
}

const uint64_t *avz_native_block_cache_shared_code_mutation_epoch_token(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL
        ? NULL
        : avz_guest_memory_code_mutation_epoch_token(cache->guest_memory);
}

const uint64_t *avz_native_block_cache_code_mutation_epoch_token(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? NULL : &cache->code_mutation_epoch;
}

uint64_t avz_native_block_cache_reset_epoch(
    const AVZNativeBlockCache *cache
) {
    return cache == NULL ? 0 : cache->reset_epoch;
}

#if AVZ_CACHE_SERVICE_CHAIN
static AVZNativeBlockKey avz_assembly_chain_memory_key(
    const AVZNativeMemoryFastPath *memory, uint64_t pc) {
    const AVZNativeStage1TranslationState *s = &memory->translation_state;
    return (AVZNativeBlockKey){.pc = pc, .sctlr_el1 = s->sctlr_el1,
        .tcr_el1 = s->tcr_el1, .ttbr0_el1 = s->ttbr0_el1,
        .ttbr1_el1 = s->ttbr1_el1, .current_el = s->current_el};
}

static int avz_assembly_chain_proof_current(const AGGuards *p) {
    if (!p->local || *p->local != p->expected[0]) return 0;
    for (size_t i = 0; i < 3; i++)
        if (p->shared[i] && atomic_load_explicit(p->shared[i],
                memory_order_acquire) != p->expected[i + 1]) return 0;
    return 1;
}

static int avz_assembly_chain_binding_matches(const AVZNativeBlockCache *cache) {
    const AVZAssemblyChainOwner *o = &cache->service_chain;
    const AVZNativeMemoryFastPath *m = o->memory;
    if (!m || cache->reset_epoch != o->reset_epoch ||
        cache->translation_epoch != o->translation_epoch ||
        cache->guest_memory != o->guest_memory || cache->ram != o->ram ||
        cache->ram_base != o->ram_base || cache->ram_size != o->ram_size ||
        m->block_cache != cache || m->guest_memory != o->guest_memory ||
        m->ram != o->ram || m->ram_base != o->ram_base || m->ram_size != o->ram_size ||
        m->native_translation_enabled != o->native_translation_enabled ||
        m->translation_generation != o->memory_translation_generation ||
        m->tlbi_epoch != o->memory_tlbi_epoch ||
        m->observed_shared_translation_epoch != o->proof.expected[2]) return 0;
    AVZNativeBlockKey current = avz_assembly_chain_memory_key(m, o->key.pc);
    return avz_block_keys_equal(&current, &o->memory_key);
}

static int avz_assembly_chain_binding_current(const AVZNativeBlockCache *cache) {
    return avz_assembly_chain_binding_matches(cache) &&
        avz_assembly_chain_proof_current(&cache->service_chain.proof);
}

/* Deliberately does not call avz_entry_code_is_current: mapping validation can
 * call into the owner, and active validation must neither mutate nor retire. */
static int avz_assembly_chain_entry_eligible(const AVZNativeBlockCache *cache,
    const AVZBlockCacheEntry *e, const AVZNativeBlockKey *context) {
    if (!e || !e->valid || !e->serial) return 0;
    const AVZNativeDecodedBlock *b = &e->block;
    if (!b->instruction_count || b->instruction_count > 16 || b->code_page_count != 1 ||
        b->chain_barrier || b->requires_host_checkpoint || (b->key.pc & 3) ||
        b->instruction_count > (UINT64_MAX - b->key.pc) / 4 ||
        (b->key.pc >> 12) != ((b->key.pc + (b->instruction_count - 1u) * 4) >> 12) ||
        e->validated_translation_epoch != cache->translation_epoch) return 0;
    AVZNativeBlockKey canonical = *context;
    canonical.pc = b->key.pc;
    canonical = avz_canonical_block_key(&canonical);
    if (!avz_block_keys_equal(&b->key, &canonical)) return 0;
    uint64_t page = b->physical_code_pages[0];
    if (page < cache->tracked_first_page || !cache->code_page_refcounts ||
        !cache->code_page_generations || !cache->guest_memory) return 0;
    uint64_t index = (page - cache->tracked_first_page) >> 12;
    if (index >= cache->tracked_page_count || !cache->code_page_refcounts[index] ||
        b->code_page_generation_tokens[0] != &cache->code_page_generations[index] ||
        !avz_block_code_pages_are_current(b) ||
        !avz_block_shared_code_pages_are_current(cache, b)) return 0;
    size_t entry_index = (size_t)(e - cache->entries);
    const AVZBlockPageLink *link = &cache->page_links[
        entry_index * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    const uint64_t *shared = avz_guest_memory_page_write_generation_token(
        cache->guest_memory, page, cache->ram_base);
    const uint8_t *host = avz_direct_physical_pointer(cache, page, 4096);
    if (!link->linked || link->page != page || !shared || !host ||
        b->shared_code_page_generation_tokens[0] != shared ||
        b->host_code_pages[0] != host) return 0;
    for (size_t i = 0; i < b->instruction_count; i++) {
        if (b->semantic_candidates[i] || b->trace_semantic_candidates[i] ||
            (b->physical_addresses[i] & ~UINT64_C(0xfff)) != page) return 0;
        switch (b->instructions[i].kind) {
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ:
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE:
        case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
        case AVZ_NATIVE_OP_EXCEPTION_RETURN:
        case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
        case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
        case AVZ_NATIVE_OP_WAIT:
        case AVZ_NATIVE_OP_HALT:
        case AVZ_NATIVE_OP_BARRIER:
            return 0;
        default: break;
        }
    }
    return 1;
}

static int avz_assembly_chain_member_current(const AVZNativeBlockCache *cache,
    const AVZAssemblyChainMember *m, int check_generations) {
    const AVZAssemblyChainOwner *o = &cache->service_chain;
    const AVZNativeDecodedBlock *b = &m->entry->block;
    size_t index = (size_t)(m->entry - cache->entries);
    const AVZBlockPageLink *link = &cache->page_links[index * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES];
    /* Opcodes, semantic arrays and physical mappings are immutable for this
     * resident serial. Hooks retire before any entry/enrollment recycling;
     * only live identity, enrollment and captured proofs need per-visit work. */
    return m->entry->valid && m->entry->serial == m->serial && b->key.pc == m->base &&
        m->entry->validated_translation_epoch == o->translation_epoch &&
        link->linked && link->page == m->physical_page && b->code_page_count == 1 &&
        b->instruction_count == m->count && b->physical_code_pages[0] == m->physical_page &&
        b->code_page_generation_tokens[0] == m->local_generation &&
        b->code_page_generations[0] == m->expected_local_generation &&
        (const void *)b->shared_code_page_generation_tokens[0] == m->shared_generation &&
        b->shared_code_page_generations[0] == m->expected_shared_generation &&
        (!check_generations || (*m->local_generation == m->expected_local_generation &&
        atomic_load_explicit(m->shared_generation, memory_order_acquire) ==
            m->expected_shared_generation));
}

static int avz_assembly_chain_all_current(const AVZNativeBlockCache *cache, int admission) {
    const AVZAssemblyChainOwner *o = &cache->service_chain;
    if (!avz_assembly_chain_binding_current(cache)) return 0;
    for (size_t i = 0; i < o->count; i++) {
        const AVZAssemblyChainMember *m = &o->members[i];
        if (!avz_assembly_chain_member_current(cache, m, 1))
            return 0;
        if (admission && !avz_assembly_chain_entry_eligible(cache, m->entry, &o->key)) return 0;
    }
    return avz_assembly_chain_proof_current(&o->proof);
}

static int avz_assembly_chain_validate_graph(void *owner) {
    const AVZNativeBlockCache *cache = owner;
    const AVZAssemblyChainOwner *o = &cache->service_chain;
    /* The service runtime checks every captured serial/page generation and
     * global guard before AND after this callback. Avoid a third value load,
     * but keep all binding, identity and enrollment metadata checks live. */
    if (!avz_assembly_chain_binding_matches(cache)) return 0;
    for (size_t i = 0; i < o->count; i++)
        if (!avz_assembly_chain_member_current(cache, &o->members[i], 0)) return 0;
    return 1;
}

AGServiceChain *avz_assembly_cache_service_chain(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *root, const AVZNativeBlockKey *key,
    AVZNativeMemoryFastPath *memory, const AGGuards *proof) {
    if (!cache || !root || !key || !memory || !proof ||
        cache->service_chain.active) return NULL;
    if (!cache->guest_memory || !cache->ram || memory->block_cache != cache ||
        memory->guest_memory != cache->guest_memory || memory->ram != cache->ram ||
        memory->ram_base != cache->ram_base || memory->ram_size != cache->ram_size ||
        proof->local != &cache->code_mutation_epoch ||
        proof->shared[0] != &cache->guest_memory->code_mutation_epoch ||
        proof->shared[1] != &cache->guest_memory->translation_epoch ||
        memory->observed_shared_translation_epoch != proof->expected[2] ||
        !avz_assembly_chain_proof_current(proof)) {
        avz_assembly_chain_retire(cache);
        return NULL;
    }
    AVZNativeBlockKey canonical = avz_canonical_block_key(key);
    AVZNativeBlockKey memory_key = avz_assembly_chain_memory_key(memory, key->pc);
    AVZNativeBlockKey canonical_memory = avz_canonical_block_key(&memory_key);
    if (memory->native_translation_enabled &&
        !avz_block_contexts_equal(&canonical, &canonical_memory)) return NULL;
    const AVZBlockCacheEntry *first = avz_entry_for_block(cache, root);
    if (!avz_assembly_chain_entry_eligible(cache, first, &canonical) ||
        key->pc < root->key.pc || (key->pc & 3) ||
        key->pc - root->key.pc >= root->instruction_count * 4u) return NULL;

    AVZAssemblyChainOwner *o = &cache->service_chain;
    if (o->chain) {
        int same = o->memory == memory && avz_block_contexts_equal(&o->key, &canonical) &&
            o->proof.local == proof->local && o->proof.expected[0] == proof->expected[0];
        for (size_t i = 0; i < 3; i++)
            same &= o->proof.shared[i] == proof->shared[i] &&
                o->proof.expected[i + 1] == proof->expected[i + 1];
        if (avz_assembly_chain_all_current(cache, 1)) {
            if (same) {
                for (size_t i = 0; i < o->count; i++) {
                    if (o->members[i].entry == first && o->members[i].serial == first->serial) {
                        cache->service_chain_diagnostics.reuses++;
                        return o->chain;
                    }
                }
            }
            cache->service_chain_diagnostics.retained_graph_misses++;
            return NULL;
        }
        avz_assembly_chain_retire(cache);
    }
    /* Only assembly-selected roots with retained positive programs earn a graph.
     * Successor metadata demonstrates actual prior execution, not prediction. */
    if (!first->assembly.program || !first->assembly_capability ||
        first->assembly_capability == 3) return NULL;
    const AVZBlockCacheEntry *entries[AG_SERVICE_MAX_MEMBERS] = {first};
    size_t count = 1;
    int self_edge = 0;
    for (size_t i = 0; i < count && count < AG_SERVICE_MAX_MEMBERS; i++) {
        for (size_t j = 0; j < 2 && count < AG_SERVICE_MAX_MEMBERS; j++) {
            const AVZBlockSuccessor *s = &entries[i]->block.successors[j];
            const AVZBlockCacheEntry *e = avz_entry_for_block(cache, s->target);
            if (!e || !s->target_serial || s->target_serial_token != &e->serial ||
                s->target_serial != e->serial ||
                !e->assembly.program || !e->assembly_capability || e->assembly_capability == 3 ||
                !avz_assembly_chain_entry_eligible(cache, e, &canonical)) continue;
            if (e == first && entries[i] == first) self_edge = 1;
            uint64_t start = e->block.key.pc;
            uint64_t end = start + e->block.instruction_count * 4u;
            int overlaps = 0;
            for (size_t k = 0; k < count; k++) {
                const AVZNativeDecodedBlock *b = &entries[k]->block;
                overlaps |= start < b->key.pc + b->instruction_count * 4u && b->key.pc < end;
            }
            if (!overlaps) entries[count++] = e;
        }
    }
    if (count < 2 && !self_edge) return NULL;
    for (size_t i = 1; i < count; i++) {
        const AVZBlockCacheEntry *e = entries[i];
        size_t j = i;
        while (j && entries[j - 1]->block.key.pc > e->block.key.pc) {
            entries[j] = entries[j - 1]; j--;
        }
        entries[j] = e;
    }
    *o = (AVZAssemblyChainOwner){.memory = memory, .guest_memory = cache->guest_memory,
        .ram = cache->ram, .ram_base = cache->ram_base, .ram_size = cache->ram_size,
        .reset_epoch = cache->reset_epoch, .translation_epoch = cache->translation_epoch,
        .memory_translation_generation = memory->translation_generation,
        .memory_tlbi_epoch = memory->tlbi_epoch, .key = canonical, .memory_key = memory_key,
        .proof = *proof, .count = count,
        .native_translation_enabled = memory->native_translation_enabled};
    uint32_t words[AG_SERVICE_MAX_MEMBERS][16];
    AGServiceBlock blocks[AG_SERVICE_MAX_MEMBERS];
    for (size_t i = 0; i < count; i++) {
        const AVZBlockCacheEntry *e = entries[i];
        const AVZNativeDecodedBlock *b = &e->block;
        /* Shared tokens originate in atomic guest-memory storage; local tokens
         * remain ordinary uint64_t and are never cast to atomic storage. */
        const _Atomic uint64_t *shared = (const _Atomic uint64_t *)
            b->shared_code_page_generation_tokens[0];
        o->members[i] = (AVZAssemblyChainMember){.entry = e, .serial = e->serial,
            .base = b->key.pc, .count = b->instruction_count,
            .physical_page = b->physical_code_pages[0],
            .local_generation = b->code_page_generation_tokens[0],
            .shared_generation = shared,
            .expected_local_generation = b->code_page_generations[0],
            .expected_shared_generation = b->shared_code_page_generations[0]};
        for (size_t j = 0; j < b->instruction_count; j++) words[i][j] = b->instructions[j].raw;
        blocks[i] = (AGServiceBlock){.words = words[i], .count = b->instruction_count,
            .base = b->key.pc, .serial = &e->serial, .expected_serial = e->serial,
            .local_generation = b->code_page_generation_tokens[0],
            .expected_local_generation = b->code_page_generations[0],
            .shared_generation = shared,
            .expected_shared_generation = b->shared_code_page_generations[0]};
        o->instructions += b->instruction_count;
    }
    o->chain = ag_service_chain_create_graph(blocks, count, proof, memory,
        avz_assembly_chain_validate_graph, cache);
    if (!o->chain) {
        cache->service_chain_diagnostics.failed_builds++;
        memset(o, 0, sizeof(*o)); return NULL;
    }
    o->bytes = sizeof(*o) + ag_service_chain_bytes(o->chain);
    if (o->instructions > 128 || o->bytes > 32768 || !avz_assembly_chain_all_current(cache, 1)) {
        cache->service_chain_diagnostics.failed_builds++;
        avz_assembly_chain_retire(cache);
        return NULL;
    }
    cache->service_chain_diagnostics.builds++;
    if (o->bytes > cache->service_chain_diagnostics.peak_bytes)
        cache->service_chain_diagnostics.peak_bytes = o->bytes;
    return o->chain;
}

static AGServiceResult avz_assembly_cache_service_chain_run_impl(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner, int bounded) {
    if (!cache || !chain || cache->service_chain.chain != chain || cache->service_chain.active)
        return (AGServiceResult){.architectural.status = AVZ_TP_STATUS_INVALID_ARGUMENT,
            .stop = AG_SERVICE_STOP_INVALID};
    cache->service_chain.active = 1;
    AGServiceResult result = bounded
        ? ag_service_chain_run_bounded(chain, limits, cpu, service, owner)
        : ag_service_chain_run(chain, limits, cpu, service, owner);
    cache->service_chain.active = 0;
    if (!cache->service_chain.chain) memset(&cache->service_chain, 0, sizeof(cache->service_chain));
    else if (!avz_assembly_chain_all_current(cache, 0)) avz_assembly_chain_retire(cache);
    else {
        cache->service_chain.bytes = sizeof(cache->service_chain) +
            ag_service_chain_bytes(cache->service_chain.chain);
        if (cache->service_chain.bytes > cache->service_chain_diagnostics.peak_bytes)
            cache->service_chain_diagnostics.peak_bytes = cache->service_chain.bytes;
    }
    return result;
}

AGServiceResult avz_assembly_cache_service_chain_run(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner) {
    return avz_assembly_cache_service_chain_run_impl(cache, chain, limits, cpu, service, owner, 0);
}
AGServiceResult avz_assembly_cache_service_chain_run_bounded(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner) {
    return avz_assembly_cache_service_chain_run_impl(cache, chain, limits, cpu, service, owner, 1);
}

int avz_assembly_cache_service_chain_contains(const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, uint64_t serial) {
    if (!cache || !cache->service_chain.chain || !serial ||
        !avz_assembly_chain_all_current(cache, 0)) return 0;
    for (size_t i = 0; i < cache->service_chain.count; i++) {
        const AVZAssemblyChainMember *m = &cache->service_chain.members[i];
        if (&m->entry->block == block && m->serial == serial) return 1;
    }
    return 0;
}

AVZAssemblyChainInfo avz_assembly_cache_service_chain_info(const AVZNativeBlockCache *cache) {
    if (!cache || (!cache->service_chain.chain && !cache->service_chain.active))
        return (AVZAssemblyChainInfo){0};
    const AVZAssemblyChainOwner *o = &cache->service_chain;
    return (AVZAssemblyChainInfo){o->count, o->instructions, o->bytes, o->active};
}
AVZAssemblyChainDiagnostics avz_assembly_cache_service_chain_diagnostics(
    const AVZNativeBlockCache *cache) {
    if (!cache) return (AVZAssemblyChainDiagnostics){0};
    AVZAssemblyChainDiagnostics result = cache->service_chain_diagnostics;
    result.bytes = avz_assembly_cache_service_chain_info(cache).bytes;
    return result;
}
#else
int avz_assembly_cache_service_chain_contains(const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block, uint64_t serial) {
    (void)cache; (void)block; (void)serial; return 0;
}
AGServiceChain *avz_assembly_cache_service_chain(AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *root, const AVZNativeBlockKey *key,
    AVZNativeMemoryFastPath *memory, const AGGuards *proof) {
    (void)cache; (void)root; (void)key; (void)memory; (void)proof;
    return NULL;
}
AGServiceResult avz_assembly_cache_service_chain_run(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner) {
    (void)cache; (void)chain; (void)limits; (void)cpu; (void)service; (void)owner;
    return (AGServiceResult){.architectural.status = AVZ_TP_STATUS_DISABLED,
        .stop = AG_SERVICE_STOP_DISABLED};
}
void avz_assembly_cache_service_chain_retire(AVZNativeBlockCache *cache) { (void)cache; }
AGServiceResult avz_assembly_cache_service_chain_run_bounded(AVZNativeBlockCache *cache,
    AGServiceChain *chain, AGServiceLimits limits, AVZNativeCPU *cpu,
    AGServiceCallback service, void *owner) {
    return avz_assembly_cache_service_chain_run(cache, chain, limits, cpu, service, owner);
}
AVZAssemblyChainInfo avz_assembly_cache_service_chain_info(const AVZNativeBlockCache *cache) {
    (void)cache; return (AVZAssemblyChainInfo){0};
}
AVZAssemblyChainDiagnostics avz_assembly_cache_service_chain_diagnostics(
    const AVZNativeBlockCache *cache) {
    (void)cache; return (AVZAssemblyChainDiagnostics){0};
}
#endif
