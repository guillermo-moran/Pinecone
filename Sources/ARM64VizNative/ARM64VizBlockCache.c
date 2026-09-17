#include "ARM64VizNative.h"

#include <limits.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

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

typedef struct {
    AVZNativeDecodedBlock block;
    uint64_t serial;
    uint64_t validated_code_mutation_epoch;
    uint64_t validated_shared_code_mutation_epoch;
    uint64_t validated_translation_epoch;
    uint64_t last_used;
    uint8_t valid;
    uint8_t prefetched;
} AVZBlockCacheEntry;

typedef struct {
    uint64_t hash;
    int32_t entry_index;
    uint8_t valid;
} AVZBlockFrontCacheEntry;

struct AVZNativeBlockCache {
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
