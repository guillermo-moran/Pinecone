#ifndef ARM64VIZ_GUEST_MEMORY_INTERNAL_H
#define ARM64VIZ_GUEST_MEMORY_INTERNAL_H

#include "ARM64VizNative.h"

#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>

enum {
    AVZ_FAST_TLB_SET_COUNT = 4096,
    AVZ_FAST_TLB_WAY_COUNT = 4,
    AVZ_FAST_TLB_ENTRY_COUNT =
        AVZ_FAST_TLB_SET_COUNT * AVZ_FAST_TLB_WAY_COUNT,
    AVZ_FAST_INSTRUCTION_TLB_SET_COUNT = 4096,
    AVZ_FAST_INSTRUCTION_TLB_ENTRY_COUNT =
        AVZ_FAST_INSTRUCTION_TLB_SET_COUNT * AVZ_FAST_TLB_WAY_COUNT,
    AVZ_FAST_DATA_HOT_COUNT = 1024,
    AVZ_FAST_INSTRUCTION_HOT_COUNT = 16,
    AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT = 4096,
    AVZ_FAST_DIRTY_HOT_COUNT = 4096,
    AVZ_EXCLUSIVE_GRANULE_SHIFT = 4,
    AVZ_EXCLUSIVE_SLOT_SCALE = 8,
    AVZ_EXCLUSIVE_MINIMUM_SLOT_COUNT = 8192,
    AVZ_FAST_PAGE_SHIFT = 12,
    AVZ_FAST_PAGE_SIZE = 1 << AVZ_FAST_PAGE_SHIFT,
    AVZ_GUEST_PAGE_OBSERVATION_HOST = 1u << 0,
    AVZ_GUEST_PAGE_OBSERVATION_BULK_READER = 1u << 1,
    AVZ_GUEST_PAGE_OBSERVATION_EXCLUSIVE = 1u << 2
};

typedef struct {
    uint64_t virtual_page;
    uint64_t physical_page;
    uint8_t *host_page;
    uint16_t contiguous_span;
    uint64_t context_tag;
    uint64_t generation;
    uint8_t valid;
} AVZNativeFastTLBEntry;

typedef struct {
    uint64_t page;
    uint64_t epoch;
    uint8_t valid;
} AVZNativeDirtyHotEntry;

struct AVZGuestMemory {
    uint8_t *bytes;
    size_t size;
    _Atomic uint64_t *page_epochs;
    _Atomic uint64_t *page_write_generations;
    _Atomic uint64_t *page_exclusive_observation_epochs;
    _Atomic uint8_t *host_page_observations;
    _Atomic uint8_t *bulk_read_page_observations;
    _Atomic uint8_t *page_observation_flags;
    _Atomic uint64_t *exclusive_write_generations;
    _Atomic uint8_t *exclusive_observations;
    size_t exclusive_slot_count;
    size_t exclusive_slot_mask;
    size_t page_count;
    _Atomic uint64_t current_epoch;
    _Atomic uint64_t current_write_generation;
    _Atomic uint64_t code_mutation_epoch;
    _Atomic uint64_t translation_epoch;
    _Atomic uint64_t exclusive_reads;
    _Atomic uint64_t exclusive_nonzero_reads;
    _Atomic uint64_t exclusive_write_successes;
    _Atomic uint64_t exclusive_write_conflicts;
    atomic_flag *page_locks;
    _Atomic uint8_t *code_page_bits;
};

struct AVZNativeMemoryFastPath {
    uint8_t *ram;
    uint64_t ram_base;
    uint64_t ram_size;
    AVZNativeBlockCache *block_cache;
    void *slow_context;
    AVZNativeMemoryTranslateRAMCallback translate_ram;
    AVZNativeMemoryTranslateRAMCallback translate_instruction_ram;
    AVZNativeMemoryTranslationFaultCallback report_translation_fault;
    AVZNativeMemoryReadCallback slow_read;
    AVZNativeMemoryWriteCallback slow_write;
    AVZNativePhysicalMemoryReadCallback read_physical;
    AVZNativePhysicalMemoryWriteCallback write_physical;
    AVZNativeMemoryCanAccessCallback slow_can_access;
    AVZNativeMemoryFillCallback slow_fill;
    AVZNativeSystemRegisterReadCallback slow_read_system_register;
    AVZNativeSystemRegisterWriteCallback slow_write_system_register;
    AVZNativeSystemInstructionCallback slow_execute_system_instruction;
    AVZNativeExceptionReturnCallback slow_exception_return;
    AVZNativeSynchronousExceptionCallback slow_synchronous_exception;
    AVZNativeWaitCallback slow_wait;
    AVZNativeFastTLBEntry read_tlb[AVZ_FAST_TLB_ENTRY_COUNT];
    AVZNativeFastTLBEntry write_tlb[AVZ_FAST_TLB_ENTRY_COUNT];
    AVZNativeFastTLBEntry
        instruction_tlb[AVZ_FAST_INSTRUCTION_TLB_ENTRY_COUNT];
    AVZNativeFastTLBEntry read_hot[AVZ_FAST_DATA_HOT_COUNT];
    AVZNativeFastTLBEntry write_hot[AVZ_FAST_DATA_HOT_COUNT];
    AVZNativeFastTLBEntry instruction_hot[AVZ_FAST_INSTRUCTION_HOT_COUNT];
    AVZNativeDirtyHotEntry dirty_hot[AVZ_FAST_DIRTY_HOT_COUNT];
    uint8_t read_replacement[AVZ_FAST_TLB_SET_COUNT];
    uint8_t write_replacement[AVZ_FAST_TLB_SET_COUNT];
    uint8_t instruction_replacement[AVZ_FAST_INSTRUCTION_TLB_SET_COUNT];
    uint8_t instruction_hot_replacement;
    AVZNativeThreadRegisterState thread_registers;
    AVZNativeArchitecturalState architectural_state;
    AVZNativeStage1TranslationState translation_state;
    uint64_t low_translation_context_tag;
    uint64_t high_translation_context_tag;
    uint64_t low_translation_context_hash;
    uint64_t high_translation_context_hash;
    uint64_t translation_generation;
    uint64_t observed_shared_translation_epoch;
    uint8_t native_translation_enabled;
    uint8_t translation_fault_pending;
    uint8_t detailed_statistics_enabled;
    uint8_t direct_bulk_mapping_enabled;
    uint8_t exclusive_expected_valid;
    uint8_t exclusive_expected_width;
    uint8_t exclusive_expected_count;
    uint64_t exclusive_expected_address;
    uint64_t exclusive_expected_first;
    uint64_t exclusive_expected_second;
    AVZNativeMemoryFastPathStatistics statistics;
    AVZGuestMemory *guest_memory;
};

/*
 * Complete an ordinary RAM load in the CPU translation unit when its direct
 * TLB entry proves that no slow-path behavior is required. Returning zero is
 * not a guest fault: it asks the caller to use avz_native_fast_memory_read(),
 * which handles misses, MMIO, observers, unaligned accesses, and faults.
 */
#if defined(__clang__) || defined(__GNUC__)
__attribute__((always_inline))
#endif
static inline int avz_native_fast_memory_try_read_hot(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value
) {
    if (fast_path == NULL || value == NULL || fast_path->ram == NULL ||
        (width != 1 && width != 2 && width != 4 && width != 8)) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    if (memory != NULL) {
        const uint64_t shared_epoch = atomic_load_explicit(
            &memory->translation_epoch, memory_order_relaxed);
        if (shared_epoch != fast_path->observed_shared_translation_epoch)
            return 0;
    }

    const uint64_t page_offset =
        virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset + width > AVZ_FAST_PAGE_SIZE)
        return 0;

    const uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    const uint64_t context_tag = fast_path->native_translation_enabled
        ? (virtual_address >> 63
            ? fast_path->high_translation_context_tag
            : fast_path->low_translation_context_tag)
        : 0;
    const size_t hot_index = (size_t)(
        (virtual_page ^ (context_tag >> AVZ_FAST_PAGE_SHIFT)) &
        (AVZ_FAST_DATA_HOT_COUNT - 1u));
    const AVZNativeFastTLBEntry *entry = &fast_path->read_hot[hot_index];
    if (!entry->valid ||
        entry->generation != fast_path->translation_generation ||
        entry->contiguous_span < page_offset + width ||
        entry->virtual_page != virtual_page ||
        entry->context_tag != context_tag || entry->host_page == NULL ||
        entry->physical_page < fast_path->ram_base) {
        return 0;
    }

    const uint64_t ram_page_offset =
        entry->physical_page - fast_path->ram_base;
    if (ram_page_offset > fast_path->ram_size ||
        page_offset > fast_path->ram_size - ram_page_offset ||
        width > fast_path->ram_size - ram_page_offset - page_offset) {
        return 0;
    }
    const size_t memory_offset = (size_t)(ram_page_offset + page_offset);
    if (memory != NULL && memory->page_observation_flags != NULL) {
        const size_t page = memory_offset >> AVZ_FAST_PAGE_SHIFT;
        if (page >= memory->page_count ||
            (atomic_load_explicit(
                &memory->page_observation_flags[page],
                memory_order_acquire) &
             AVZ_GUEST_PAGE_OBSERVATION_HOST) != 0) {
            return 0;
        }
    }

    const uint8_t *host_address = entry->host_page + page_offset;
    const uintptr_t host_value = (uintptr_t)host_address;
    switch (width) {
    case 1:
        *value = __atomic_load_n(host_address, __ATOMIC_RELAXED);
        break;
    case 2:
        if ((host_value & 1u) != 0)
            return 0;
        *value = __atomic_load_n(
            (const uint16_t *)host_address, __ATOMIC_RELAXED);
        break;
    case 4:
        if ((host_value & 3u) != 0)
            return 0;
        *value = __atomic_load_n(
            (const uint32_t *)host_address, __ATOMIC_RELAXED);
        break;
    case 8:
        if ((host_value & 7u) != 0)
            return 0;
        *value = __atomic_load_n(
            (const uint64_t *)host_address, __ATOMIC_RELAXED);
        break;
    default:
        return 0;
    }

    if (fast_path->detailed_statistics_enabled) {
        fast_path->statistics.read_tlb_hits++;
        fast_path->statistics.read_hits++;
    }
    return 1;
}

/*
 * A TLB-hit store to ordinary data RAM has already proved that no host,
 * retained DMA reader, or exclusive observer can race the access. Keep its
 * dirty-page bookkeeping in this translation unit as well. Executable pages
 * still use the complete commit path so decoded-code generations and block
 * cache invalidation remain exact.
 */
#if defined(__clang__) || defined(__GNUC__)
__attribute__((always_inline))
#endif
static inline void avz_native_fast_memory_commit_unobserved_write_hot(
    AVZNativeMemoryFastPath *fast_path,
    AVZGuestMemory *memory,
    size_t page,
    uint64_t physical_address,
    size_t byte_count
) {
    if (fast_path == NULL || memory == NULL ||
        memory->page_epochs == NULL || memory->code_page_bits == NULL ||
        page >= memory->page_count) {
        avz_native_fast_memory_commit_write_span(
            fast_path, physical_address, byte_count);
        return;
    }

    const uint8_t code_bits = atomic_load_explicit(
        &memory->code_page_bits[page >> 3], memory_order_relaxed);
    if ((code_bits & (uint8_t)(1u << (page & 7u))) != 0) {
        avz_native_fast_memory_commit_write_span(
            fast_path, physical_address, byte_count);
        return;
    }

    const uint64_t epoch = atomic_load_explicit(
        &memory->current_epoch, memory_order_relaxed);
    const size_t slot = page & (AVZ_FAST_DIRTY_HOT_COUNT - 1u);
    AVZNativeDirtyHotEntry *entry = &fast_path->dirty_hot[slot];
    if (entry->valid && entry->page == page && entry->epoch == epoch)
        return;

    atomic_store_explicit(
        &memory->page_epochs[page], epoch, memory_order_release);
    *entry = (AVZNativeDirtyHotEntry){
        .page = page,
        .epoch = epoch,
        .valid = 1,
    };
}

/* See avz_native_fast_memory_try_read_hot(). The write variant is limited to
 * naturally aligned RAM with no host, DMA, or exclusive observer. Dirty and
 * executable-page accounting still runs through the shared commit routine. */
#if defined(__clang__) || defined(__GNUC__)
__attribute__((always_inline))
#endif
static inline int avz_native_fast_memory_try_write_hot(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value
) {
    if (fast_path == NULL || fast_path->ram == NULL ||
        (width != 1 && width != 2 && width != 4 && width != 8)) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    if (memory != NULL) {
        const uint64_t shared_epoch = atomic_load_explicit(
            &memory->translation_epoch, memory_order_relaxed);
        if (shared_epoch != fast_path->observed_shared_translation_epoch)
            return 0;
    }

    const uint64_t page_offset =
        virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset + width > AVZ_FAST_PAGE_SIZE)
        return 0;

    const uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    const uint64_t context_tag = fast_path->native_translation_enabled
        ? (virtual_address >> 63
            ? fast_path->high_translation_context_tag
            : fast_path->low_translation_context_tag)
        : 0;
    const size_t hot_index = (size_t)(
        (virtual_page ^ (context_tag >> AVZ_FAST_PAGE_SHIFT)) &
        (AVZ_FAST_DATA_HOT_COUNT - 1u));
    const AVZNativeFastTLBEntry *entry = &fast_path->write_hot[hot_index];
    if (!entry->valid ||
        entry->generation != fast_path->translation_generation ||
        entry->contiguous_span < page_offset + width ||
        entry->virtual_page != virtual_page ||
        entry->context_tag != context_tag || entry->host_page == NULL ||
        entry->physical_page < fast_path->ram_base) {
        return 0;
    }

    const uint64_t ram_page_offset =
        entry->physical_page - fast_path->ram_base;
    if (ram_page_offset > fast_path->ram_size ||
        page_offset > fast_path->ram_size - ram_page_offset ||
        width > fast_path->ram_size - ram_page_offset - page_offset) {
        return 0;
    }
    const size_t memory_offset = (size_t)(ram_page_offset + page_offset);
    const size_t page = memory_offset >> AVZ_FAST_PAGE_SHIFT;
    if (memory != NULL) {
        if (page >= memory->page_count ||
            memory->page_observation_flags == NULL ||
            atomic_load_explicit(
                &memory->page_observation_flags[page],
                memory_order_acquire) != 0) {
            return 0;
        }
    }

    uint8_t *host_address = entry->host_page + page_offset;
    const uintptr_t host_value = (uintptr_t)host_address;
    switch (width) {
    case 1:
        __atomic_store_n(host_address, (uint8_t)value, __ATOMIC_RELAXED);
        break;
    case 2:
        if ((host_value & 1u) != 0)
            return 0;
        __atomic_store_n(
            (uint16_t *)host_address, (uint16_t)value, __ATOMIC_RELAXED);
        break;
    case 4:
        if ((host_value & 3u) != 0)
            return 0;
        __atomic_store_n(
            (uint32_t *)host_address, (uint32_t)value, __ATOMIC_RELAXED);
        break;
    case 8:
        if ((host_value & 7u) != 0)
            return 0;
        __atomic_store_n(
            (uint64_t *)host_address, value, __ATOMIC_RELAXED);
        break;
    default:
        return 0;
    }

    avz_native_fast_memory_commit_unobserved_write_hot(
        fast_path,
        memory,
        page,
        entry->physical_page + page_offset,
        width
    );
    if (fast_path->detailed_statistics_enabled) {
        fast_path->statistics.write_tlb_hits++;
        fast_path->statistics.write_hits++;
    }
    return 1;
}

#endif
