#include "ARM64VizNative.h"

#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>

enum {
    AVZ_FAST_TLB_SET_COUNT = 1024,
    AVZ_FAST_TLB_WAY_COUNT = 4,
    AVZ_FAST_TLB_ENTRY_COUNT =
        AVZ_FAST_TLB_SET_COUNT * AVZ_FAST_TLB_WAY_COUNT,
    AVZ_FAST_PAGE_SHIFT = 12,
    AVZ_FAST_PAGE_SIZE = 1 << AVZ_FAST_PAGE_SHIFT
};

enum {
    AVZ_FAST_TRANSLATION_FAILED = 0,
    AVZ_FAST_TRANSLATION_RAM = 1,
    AVZ_FAST_TRANSLATION_PHYSICAL = 2
};

#define AVZ_STAGE1_OUTPUT_ADDRESS_MASK 0x0000fffffffff000ULL
#define AVZ_STAGE1_ACCESS_FLAG_BIT (1ULL << 10)
#define AVZ_STAGE1_READ_ONLY_AP_BIT (1ULL << 7)
#define AVZ_STAGE1_PRIVILEGED_EXECUTE_NEVER_BIT (1ULL << 53)
#define AVZ_STAGE1_UNPRIVILEGED_EXECUTE_NEVER_BIT (1ULL << 54)

enum {
    AVZ_FAULT_ADDRESS_SIZE_LEVEL_0 = 0x00,
    AVZ_FAULT_TRANSLATION_LEVEL_0 = 0x04,
    AVZ_FAULT_ACCESS_FLAG_LEVEL_0 = 0x08,
    AVZ_FAULT_PERMISSION_LEVEL_0 = 0x0c
};

typedef struct {
    uint64_t virtual_page;
    uint64_t physical_page;
    uint8_t *host_page;
    uint64_t context_tag;
    uint64_t generation;
    uint8_t valid;
} AVZNativeFastTLBEntry;

struct AVZGuestMemory {
    uint8_t *bytes;
    size_t size;
    _Atomic uint64_t *page_epochs;
    _Atomic uint64_t *page_write_generations;
    size_t page_count;
    _Atomic uint64_t current_epoch;
    _Atomic uint64_t current_write_generation;
    _Atomic uint64_t translation_epoch;
    atomic_flag write_lock;
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
    AVZNativeFastTLBEntry instruction_tlb[AVZ_FAST_TLB_ENTRY_COUNT];
    AVZNativeFastTLBEntry read_hot;
    AVZNativeFastTLBEntry write_hot;
    AVZNativeFastTLBEntry instruction_hot;
    uint8_t read_replacement[AVZ_FAST_TLB_SET_COUNT];
    uint8_t write_replacement[AVZ_FAST_TLB_SET_COUNT];
    uint8_t instruction_replacement[AVZ_FAST_TLB_SET_COUNT];
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
    AVZNativeMemoryFastPathStatistics statistics;
    AVZGuestMemory *guest_memory;
};

static uint16_t avz_system_register_key(uint32_t instruction) {
    uint16_t op0 = (uint16_t)((instruction >> 19) & 0x3u);
    uint16_t op1 = (uint16_t)((instruction >> 16) & 0x7u);
    uint16_t crn = (uint16_t)((instruction >> 12) & 0xfu);
    uint16_t crm = (uint16_t)((instruction >> 8) & 0xfu);
    uint16_t op2 = (uint16_t)((instruction >> 5) & 0x7u);
    return (uint16_t)(
        (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2
    );
}

#define AVZ_SYSTEM_REGISTER_KEY(op0, op1, crn, crm, op2) \
    ((uint16_t)( \
        ((uint16_t)(op0) << 14) | ((uint16_t)(op1) << 11) | \
        ((uint16_t)(crn) << 7) | ((uint16_t)(crm) << 3) | (uint16_t)(op2) \
    ))

enum {
    AVZ_SYSREG_SPSR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 0, 0),
    AVZ_SYSREG_ELR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 0, 1),
    AVZ_SYSREG_SP_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 1, 0),
    AVZ_SYSREG_ESR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 5, 2, 0),
    AVZ_SYSREG_FAR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 6, 0, 0),
    AVZ_SYSREG_VBAR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 12, 0, 0),
    AVZ_SYSREG_CONTEXTIDR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 13, 0, 1),
    AVZ_SYSREG_TPIDR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 13, 0, 4),
    AVZ_SYSREG_TPIDR_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 13, 0, 2),
    AVZ_SYSREG_TPIDRRO_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 13, 0, 3),
    AVZ_SYSREG_CNTPCT_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 0, 1),
    AVZ_SYSREG_CNTVCT_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 0, 2),
    AVZ_SYSREG_CNTP_TVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 0),
    AVZ_SYSREG_CNTP_CTL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 1),
    AVZ_SYSREG_CNTP_CVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 2),
    AVZ_SYSREG_CNTV_TVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 0),
    AVZ_SYSREG_CNTV_CTL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 1),
    AVZ_SYSREG_CNTV_CVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 2)
};

AVZGuestMemory *avz_guest_memory_create(size_t size) {
    if (size == 0 || size > SIZE_MAX - (AVZ_FAST_PAGE_SIZE - 1u)) {
        return 0;
    }
    AVZGuestMemory *memory = calloc(1, sizeof(*memory));
    if (memory == 0) {
        return 0;
    }
    void *mapping = mmap(
        0,
        size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (mapping == MAP_FAILED) {
        free(memory);
        return 0;
    }
    memory->bytes = mapping;
    memory->size = size;
    memory->page_count = (size + AVZ_FAST_PAGE_SIZE - 1u) >>
        AVZ_FAST_PAGE_SHIFT;
    memory->page_epochs = calloc(
        memory->page_count,
        sizeof(*memory->page_epochs)
    );
    if (memory->page_epochs == NULL) {
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->page_write_generations = calloc(
        memory->page_count,
        sizeof(*memory->page_write_generations)
    );
    if (memory->page_write_generations == NULL) {
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    atomic_init(&memory->current_epoch, 1);
    atomic_init(&memory->current_write_generation, 1);
    atomic_init(&memory->translation_epoch, 1);
    atomic_flag_clear(&memory->write_lock);
    return memory;
}

void avz_guest_memory_destroy(AVZGuestMemory *memory) {
    if (memory == 0) {
        return;
    }
    if (memory->bytes != 0 && memory->size > 0) {
        munmap(memory->bytes, memory->size);
    }
    free(memory->page_epochs);
    free(memory->page_write_generations);
    free(memory);
}

void avz_guest_memory_note_write(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    avz_guest_memory_mark_dirty(memory, offset, byte_count);
    uint64_t generation = atomic_fetch_add_explicit(
        &memory->current_write_generation,
        1,
        memory_order_acq_rel
    ) + 1;
    if (generation == 0) {
        generation = 1;
        atomic_store_explicit(
            &memory->current_write_generation,
            generation,
            memory_order_release
        );
    }
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->page_write_generations[page],
            generation,
            memory_order_release
        );
    }
}

void avz_guest_memory_invalidate_translations(AVZGuestMemory *memory) {
    if (memory == NULL) {
        return;
    }
    uint64_t epoch = atomic_fetch_add_explicit(
        &memory->translation_epoch,
        1,
        memory_order_acq_rel
    ) + 1;
    if (epoch == 0) {
        atomic_store_explicit(
            &memory->translation_epoch,
            1,
            memory_order_release
        );
    }
}

uint64_t avz_guest_memory_translation_epoch(const AVZGuestMemory *memory) {
    return memory == NULL ? 0 : atomic_load_explicit(
        &memory->translation_epoch,
        memory_order_acquire
    );
}

uint8_t *avz_guest_memory_bytes(AVZGuestMemory *memory) {
    return memory == 0 ? 0 : memory->bytes;
}

size_t avz_guest_memory_size(const AVZGuestMemory *memory) {
    return memory == 0 ? 0 : memory->size;
}

void avz_guest_memory_mark_dirty(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    const uint64_t current_epoch = atomic_load_explicit(
        &memory->current_epoch,
        memory_order_relaxed
    );
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->page_epochs[page],
            current_epoch,
            memory_order_release
        );
    }
}

uint64_t avz_guest_memory_advance_dirty_epoch(AVZGuestMemory *memory) {
    if (memory == NULL) {
        return 0;
    }
    uint64_t completed_epoch = atomic_load_explicit(
        &memory->current_epoch,
        memory_order_acquire
    );
    while (completed_epoch != UINT64_MAX &&
           !atomic_compare_exchange_weak_explicit(
               &memory->current_epoch,
               &completed_epoch,
               completed_epoch + 1,
               memory_order_acq_rel,
               memory_order_acquire
           )) {
    }
    return completed_epoch;
}

size_t avz_guest_memory_dirty_ranges(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint64_t after_epoch,
    uint64_t through_epoch,
    AVZGuestDirtyRange *ranges,
    size_t range_capacity
) {
    if (memory == NULL || ranges == NULL || range_capacity == 0 ||
        byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset || through_epoch < after_epoch) {
        return 0;
    }

    const size_t requested_end = offset + byte_count;
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (requested_end - 1u) >> AVZ_FAST_PAGE_SHIFT;
    size_t range_count = 0;
    size_t page = first_page;
    while (page <= last_page) {
        const uint64_t epoch = atomic_load_explicit(
            &memory->page_epochs[page],
            memory_order_acquire
        );
        if (epoch <= after_epoch || epoch > through_epoch) {
            page++;
            continue;
        }

        const size_t run_start_page = page;
        do {
            page++;
            if (page > last_page) {
                break;
            }
            const uint64_t next_epoch = atomic_load_explicit(
                &memory->page_epochs[page],
                memory_order_acquire
            );
            if (next_epoch <= after_epoch || next_epoch > through_epoch) {
                break;
            }
        } while (1);

        if (range_count == range_capacity) {
            ranges[0] = (AVZGuestDirtyRange){
                .offset = offset,
                .length = byte_count
            };
            return 1;
        }
        const size_t run_start = run_start_page << AVZ_FAST_PAGE_SHIFT;
        const size_t run_end = page << AVZ_FAST_PAGE_SHIFT;
        const size_t clipped_start = run_start > offset ? run_start : offset;
        const size_t clipped_end = run_end < requested_end
            ? run_end
            : requested_end;
        ranges[range_count++] = (AVZGuestDirtyRange){
            .offset = clipped_start,
            .length = clipped_end - clipped_start
        };
    }
    return range_count;
}

static void avz_fast_mark_dirty(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t physical_address,
    size_t byte_count
) {
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        physical_address < fast_path->ram_base) {
        return;
    }
    const uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > SIZE_MAX) {
        return;
    }
    avz_guest_memory_note_write(
        fast_path->guest_memory,
        (size_t)offset,
        byte_count
    );
}

static int avz_fast_width_supported(uint8_t width) {
    return width == 1 || width == 2 || width == 4 || width == 8;
}

enum {
    AVZ_NATIVE_TRANSLATION_FAULT = 0,
    AVZ_NATIVE_TRANSLATION_SUCCESS = 1,
    AVZ_NATIVE_TRANSLATION_UNAVAILABLE = 2
};

static void avz_fast_clear_tlbs(AVZNativeMemoryFastPath *fast_path) {
    fast_path->translation_generation++;
    if (fast_path->translation_generation == 0) {
        memset(fast_path->read_tlb, 0, sizeof(fast_path->read_tlb));
        memset(fast_path->write_tlb, 0, sizeof(fast_path->write_tlb));
        memset(
            fast_path->instruction_tlb,
            0,
            sizeof(fast_path->instruction_tlb)
        );
        fast_path->translation_generation = 1;
    }
    fast_path->read_hot.valid = 0;
    fast_path->write_hot.valid = 0;
    fast_path->instruction_hot.valid = 0;
}

static void avz_fast_synchronize_shared_translation_epoch(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path == NULL || fast_path->guest_memory == NULL) {
        return;
    }
    const uint64_t epoch = atomic_load_explicit(
        &fast_path->guest_memory->translation_epoch,
        memory_order_acquire
    );
    if (epoch == fast_path->observed_shared_translation_epoch) {
        return;
    }
    avz_fast_clear_tlbs(fast_path);
    fast_path->observed_shared_translation_epoch = epoch;
}

static int avz_stage1_translation_state_equal(
    const AVZNativeStage1TranslationState *lhs,
    const AVZNativeStage1TranslationState *rhs
) {
    return lhs->sctlr_el1 == rhs->sctlr_el1 &&
        lhs->tcr_el1 == rhs->tcr_el1 &&
        lhs->ttbr0_el1 == rhs->ttbr0_el1 &&
        lhs->ttbr1_el1 == rhs->ttbr1_el1 &&
        lhs->current_el == rhs->current_el;
}

static int avz_stage1_translation_geometry_equal(
    const AVZNativeStage1TranslationState *lhs,
    const AVZNativeStage1TranslationState *rhs
) {
    return lhs->sctlr_el1 == rhs->sctlr_el1 &&
        lhs->tcr_el1 == rhs->tcr_el1;
}

static uint64_t avz_fast_mix_u64(uint64_t value) {
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return value;
}

static uint64_t avz_fast_translation_context_tag_for_ttbr(
    const AVZNativeStage1TranslationState *state,
    uint64_t ttbr
) {
    uint64_t hash = avz_fast_mix_u64(state->sctlr_el1);
    hash ^= avz_fast_mix_u64(state->tcr_el1);
    hash ^= avz_fast_mix_u64(ttbr & AVZ_STAGE1_OUTPUT_ADDRESS_MASK);
    hash ^= avz_fast_mix_u64(state->current_el);
    return avz_fast_mix_u64(hash);
}

static void avz_fast_refresh_translation_context_tags(
    AVZNativeMemoryFastPath *fast_path
) {
    const AVZNativeStage1TranslationState *state =
        &fast_path->translation_state;
    fast_path->low_translation_context_tag =
        avz_fast_translation_context_tag_for_ttbr(state, state->ttbr0_el1);
    fast_path->high_translation_context_tag =
        avz_fast_translation_context_tag_for_ttbr(state, state->ttbr1_el1);
    fast_path->low_translation_context_hash =
        avz_fast_mix_u64(fast_path->low_translation_context_tag);
    fast_path->high_translation_context_hash =
        avz_fast_mix_u64(fast_path->high_translation_context_tag);
}

static uint64_t avz_fast_translation_context_tag(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address
) {
    if (!fast_path->native_translation_enabled) {
        return 0;
    }
    return virtual_address >> 63
        ? fast_path->high_translation_context_tag
        : fast_path->low_translation_context_tag;
}

static uint64_t avz_fast_translation_context_hash(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address
) {
    if (!fast_path->native_translation_enabled) {
        return 0;
    }
    return virtual_address >> 63
        ? fast_path->high_translation_context_hash
        : fast_path->low_translation_context_hash;
}

static int avz_stage1_fault(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t access,
    uint8_t level,
    uint8_t status_code
) {
    fast_path->translation_fault_pending = 1;
    fast_path->statistics.native_page_table_faults++;
    if (fast_path->report_translation_fault != NULL) {
        fast_path->report_translation_fault(
            fast_path->slow_context,
            virtual_address,
            access,
            level,
            status_code
        );
    }
    return AVZ_NATIVE_TRANSLATION_FAULT;
}

static int avz_stage1_read_descriptor(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t physical_address,
    uint64_t *descriptor
) {
    if (physical_address < fast_path->ram_base) {
        return 0;
    }
    uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > fast_path->ram_size ||
        sizeof(*descriptor) > fast_path->ram_size - offset) {
        return 0;
    }
    const uint8_t *host_address = fast_path->ram + offset;
    if (((uintptr_t)host_address & (sizeof(*descriptor) - 1u)) == 0) {
        *descriptor = __atomic_load_n(
            (const uint64_t *)host_address,
            __ATOMIC_ACQUIRE
        );
    } else {
        memcpy(descriptor, host_address, sizeof(*descriptor));
    }
    return 1;
}

static int avz_stage1_validate_leaf(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t descriptor,
    uint64_t virtual_address,
    uint8_t access,
    uint8_t level
) {
    if ((descriptor & AVZ_STAGE1_ACCESS_FLAG_BIT) == 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            level,
            (uint8_t)(AVZ_FAULT_ACCESS_FLAG_LEVEL_0 + level)
        );
    }
    if (access == AVZ_NATIVE_MEMORY_ACCESS_WRITE &&
        (descriptor & AVZ_STAGE1_READ_ONLY_AP_BIT) != 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            level,
            (uint8_t)(AVZ_FAULT_PERMISSION_LEVEL_0 + level)
        );
    }
    if (access == AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION) {
        uint64_t execute_never_bit = fast_path->translation_state.current_el == 0
            ? AVZ_STAGE1_UNPRIVILEGED_EXECUTE_NEVER_BIT
            : AVZ_STAGE1_PRIVILEGED_EXECUTE_NEVER_BIT;
        if ((descriptor & execute_never_bit) != 0) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_PERMISSION_LEVEL_0 + level)
            );
        }
    }
    return AVZ_NATIVE_TRANSLATION_SUCCESS;
}

static int avz_stage1_translate(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t access,
    uint64_t *physical_address
) {
    if (!fast_path->native_translation_enabled) {
        return AVZ_NATIVE_TRANSLATION_UNAVAILABLE;
    }
    if ((fast_path->translation_state.sctlr_el1 & 1u) == 0) {
        *physical_address = virtual_address;
        return AVZ_NATIVE_TRANSLATION_SUCCESS;
    }

    fast_path->statistics.native_page_table_walks++;
    uint8_t uses_ttbr1 = (uint8_t)(virtual_address >> 63);
    unsigned size_offset = uses_ttbr1 ? 16u : 0u;
    unsigned tsz = (unsigned)(
        (fast_path->translation_state.tcr_el1 >> size_offset) & 0x3fu
    );
    unsigned input_address_size = 64u - tsz;
    if (input_address_size == 0 || input_address_size > 48u) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            0,
            AVZ_FAULT_ADDRESS_SIZE_LEVEL_0
        );
    }

    uint64_t ttbr = uses_ttbr1
        ? fast_path->translation_state.ttbr1_el1
        : fast_path->translation_state.ttbr0_el1;
    uint64_t current_table = ttbr & AVZ_STAGE1_OUTPUT_ADDRESS_MASK;
    if (current_table == 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            0,
            AVZ_FAULT_TRANSLATION_LEVEL_0
        );
    }

    uint64_t effective_address = virtual_address &
        ((1ULL << input_address_size) - 1u);
    for (uint8_t level = 0; level <= 3; level++) {
        unsigned shift = 39u - ((unsigned)level * 9u);
        uint64_t index = (effective_address >> shift) & 0x1ffu;
        if (current_table > UINT64_MAX - index * sizeof(uint64_t)) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }
        uint64_t descriptor_address =
            current_table + index * sizeof(uint64_t);
        uint64_t descriptor = 0;
        if (!avz_stage1_read_descriptor(
                fast_path,
                descriptor_address,
                &descriptor
            ) || (descriptor & 1u) == 0) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }

        uint64_t descriptor_type = descriptor & 3u;
        if (level == 3) {
            if (descriptor_type != 3u) {
                return avz_stage1_fault(
                    fast_path,
                    virtual_address,
                    access,
                    level,
                    (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
                );
            }
            if (avz_stage1_validate_leaf(
                    fast_path,
                    descriptor,
                    virtual_address,
                    access,
                    level
                ) != AVZ_NATIVE_TRANSLATION_SUCCESS) {
                return AVZ_NATIVE_TRANSLATION_FAULT;
            }
            *physical_address =
                (descriptor & AVZ_STAGE1_OUTPUT_ADDRESS_MASK) |
                (effective_address & (AVZ_FAST_PAGE_SIZE - 1u));
            return AVZ_NATIVE_TRANSLATION_SUCCESS;
        }

        if (descriptor_type == 1u) {
            unsigned offset_bits = 39u - ((unsigned)level * 9u);
            uint64_t offset_mask = (1ULL << offset_bits) - 1u;
            if (avz_stage1_validate_leaf(
                    fast_path,
                    descriptor,
                    virtual_address,
                    access,
                    level
                ) != AVZ_NATIVE_TRANSLATION_SUCCESS) {
                return AVZ_NATIVE_TRANSLATION_FAULT;
            }
            uint64_t output_base = descriptor &
                AVZ_STAGE1_OUTPUT_ADDRESS_MASK & ~offset_mask;
            *physical_address = output_base |
                (effective_address & offset_mask);
            return AVZ_NATIVE_TRANSLATION_SUCCESS;
        }

        if (descriptor_type != 3u) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }
        current_table = descriptor & AVZ_STAGE1_OUTPUT_ADDRESS_MASK;
    }

    return avz_stage1_fault(
        fast_path,
        virtual_address,
        access,
        3,
        (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + 3u)
    );
}

static int avz_resolve_translation(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t access,
    AVZNativeMemoryTranslateRAMCallback fallback,
    uint64_t *physical_address
) {
    int result = avz_stage1_translate(
        fast_path,
        virtual_address,
        access,
        physical_address
    );
    if (result != AVZ_NATIVE_TRANSLATION_UNAVAILABLE) {
        return result == AVZ_NATIVE_TRANSLATION_SUCCESS;
    }
    fast_path->statistics.translation_callback_walks++;
    return fallback != NULL && fallback(
        fast_path->slow_context,
        virtual_address,
        width,
        access == AVZ_NATIVE_MEMORY_ACCESS_WRITE,
        physical_address
    );
}

static int avz_fast_translate(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *physical_address,
    uint8_t **host_address
) {
    if (fast_path == 0 || fast_path->ram == 0 || physical_address == 0 ||
        !avz_fast_width_supported(width)) {
        return 0;
    }
    avz_fast_synchronize_shared_translation_epoch(fast_path);
    uint64_t page_offset = virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset + width > AVZ_FAST_PAGE_SIZE) {
        return 0;
    }

    uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    uint64_t context_tag = avz_fast_translation_context_tag(
        fast_path,
        virtual_address
    );
    AVZNativeFastTLBEntry *hot =
        is_write ? &fast_path->write_hot : &fast_path->read_hot;
    uint64_t physical_page;
    uint8_t *host_page;
    if (hot->valid && hot->generation == fast_path->translation_generation &&
        hot->virtual_page == virtual_page &&
        hot->context_tag == context_tag) {
        physical_page = hot->physical_page;
        host_page = hot->host_page;
        if (is_write) {
            fast_path->statistics.write_tlb_hits++;
        } else {
            fast_path->statistics.read_tlb_hits++;
        }
        goto translated;
    }

    uint64_t page_hash = virtual_page ^ (virtual_page >> 11) ^
        (virtual_page >> 23) ^
        avz_fast_translation_context_hash(fast_path, virtual_address);
    size_t set = (size_t)(page_hash & (AVZ_FAST_TLB_SET_COUNT - 1u));
    size_t base = set * AVZ_FAST_TLB_WAY_COUNT;
    AVZNativeFastTLBEntry *entries =
        is_write ? fast_path->write_tlb : fast_path->read_tlb;
    AVZNativeFastTLBEntry *entry = NULL;
    AVZNativeFastTLBEntry *first_invalid = NULL;
    for (size_t way = 0; way < AVZ_FAST_TLB_WAY_COUNT; way++) {
        AVZNativeFastTLBEntry *candidate = &entries[base + way];
        if (candidate->valid &&
            candidate->generation == fast_path->translation_generation &&
            candidate->virtual_page == virtual_page &&
            candidate->context_tag == context_tag) {
            entry = candidate;
            break;
        }
        if (!candidate->valid && first_invalid == NULL) {
            first_invalid = candidate;
        }
    }
    if (entry != NULL) {
        physical_page = entry->physical_page;
        host_page = entry->host_page;
        if (is_write) {
            fast_path->statistics.write_tlb_hits++;
        } else {
            fast_path->statistics.read_tlb_hits++;
        }
    } else {
        if (is_write) {
            fast_path->statistics.write_tlb_misses++;
        } else {
            fast_path->statistics.read_tlb_misses++;
        }
        uint64_t translated = 0;
        if (!avz_resolve_translation(
                fast_path,
                virtual_address,
                width,
                is_write
                    ? AVZ_NATIVE_MEMORY_ACCESS_WRITE
                    : AVZ_NATIVE_MEMORY_ACCESS_READ,
                fast_path->translate_ram,
                &translated
            )) {
            return 0;
        }
        if (translated < page_offset) {
            return 0;
        }
        physical_page = translated - page_offset;
        if (physical_page >= fast_path->ram_base &&
            physical_page - fast_path->ram_base < fast_path->ram_size) {
            host_page =
                fast_path->ram + (physical_page - fast_path->ram_base);
        } else {
            host_page = NULL;
        }
        if (first_invalid != NULL) {
            entry = first_invalid;
        } else {
            uint8_t *replacement = is_write
                ? &fast_path->write_replacement[set]
                : &fast_path->read_replacement[set];
            size_t way = *replacement & (AVZ_FAST_TLB_WAY_COUNT - 1u);
            *replacement =
                (uint8_t)((way + 1u) & (AVZ_FAST_TLB_WAY_COUNT - 1u));
            entry = &entries[base + way];
        }
        entry->virtual_page = virtual_page;
        entry->physical_page = physical_page;
        entry->host_page = host_page;
        entry->context_tag = context_tag;
        entry->generation = fast_path->translation_generation;
        entry->valid = 1;
    }
    *hot = *entry;

translated:
    if (physical_page > UINT64_MAX - page_offset) {
        return AVZ_FAST_TRANSLATION_FAILED;
    }
    *physical_address = physical_page + page_offset;
    if (host_page == NULL || physical_page < fast_path->ram_base) {
        if (host_address != NULL) {
            *host_address = NULL;
        }
        return AVZ_FAST_TRANSLATION_PHYSICAL;
    }
    uint64_t offset = physical_page - fast_path->ram_base + page_offset;
    if (offset > fast_path->ram_size || width > fast_path->ram_size - offset) {
        if (host_address != NULL) {
            *host_address = NULL;
        }
        return AVZ_FAST_TRANSLATION_PHYSICAL;
    }
    if (host_address != NULL) {
        *host_address = host_page + page_offset;
    }
    return AVZ_FAST_TRANSLATION_RAM;
}

static uint64_t avz_fast_load(
    const uint8_t *host_address,
    uint8_t width
) {
    const uintptr_t address = (uintptr_t)host_address;
    switch (width) {
    case 1:
        return __atomic_load_n(host_address, __ATOMIC_ACQUIRE);
    case 2:
        if ((address & 1u) == 0) {
            return __atomic_load_n(
                (const uint16_t *)host_address,
                __ATOMIC_ACQUIRE
            );
        }
        break;
    case 4:
        if ((address & 3u) == 0) {
            return __atomic_load_n(
                (const uint32_t *)host_address,
                __ATOMIC_ACQUIRE
            );
        }
        break;
    case 8:
        if ((address & 7u) == 0) {
            return __atomic_load_n(
                (const uint64_t *)host_address,
                __ATOMIC_ACQUIRE
            );
        }
        break;
    default:
        break;
    }
    uint64_t value = 0;
    memcpy(&value, host_address, width);
    return value;
}

static int avz_fast_translate_instruction(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint8_t **host_address
) {
    if (fast_path == NULL || fast_path->ram == NULL ||
        (!fast_path->native_translation_enabled &&
         fast_path->translate_instruction_ram == NULL) ||
        physical_address == NULL || host_address == NULL ||
        (virtual_address & 3u) != 0) {
        return 0;
    }
    avz_fast_synchronize_shared_translation_epoch(fast_path);

    uint64_t page_offset = virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset > AVZ_FAST_PAGE_SIZE - sizeof(uint32_t)) {
        return 0;
    }
    uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    uint64_t context_tag = avz_fast_translation_context_tag(
        fast_path,
        virtual_address
    );
    uint64_t physical_page = 0;
    uint8_t *host_page = NULL;
    AVZNativeFastTLBEntry *entry = NULL;

    if (fast_path->instruction_hot.valid &&
        fast_path->instruction_hot.generation ==
            fast_path->translation_generation &&
        fast_path->instruction_hot.virtual_page == virtual_page &&
        fast_path->instruction_hot.context_tag == context_tag) {
        entry = &fast_path->instruction_hot;
        fast_path->statistics.instruction_tlb_hits++;
    } else {
        uint64_t page_hash = virtual_page ^ (virtual_page >> 11) ^
            (virtual_page >> 23) ^
            avz_fast_translation_context_hash(fast_path, virtual_address);
        size_t set = (size_t)(page_hash & (AVZ_FAST_TLB_SET_COUNT - 1u));
        size_t base = set * AVZ_FAST_TLB_WAY_COUNT;
        AVZNativeFastTLBEntry *first_invalid = NULL;
        for (size_t way = 0; way < AVZ_FAST_TLB_WAY_COUNT; way++) {
            AVZNativeFastTLBEntry *candidate =
                &fast_path->instruction_tlb[base + way];
            if (candidate->valid &&
                candidate->generation == fast_path->translation_generation &&
                candidate->virtual_page == virtual_page &&
                candidate->context_tag == context_tag) {
                entry = candidate;
                break;
            }
            if (!candidate->valid && first_invalid == NULL) {
                first_invalid = candidate;
            }
        }

        if (entry != NULL) {
            fast_path->statistics.instruction_tlb_hits++;
        } else {
            fast_path->statistics.instruction_tlb_misses++;
            uint64_t translated = 0;
            if (!avz_resolve_translation(
                    fast_path,
                    virtual_address,
                    sizeof(uint32_t),
                    AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION,
                    fast_path->translate_instruction_ram,
                    &translated
                ) || translated < page_offset) {
                return 0;
            }
            physical_page = translated - page_offset;
            if (physical_page < fast_path->ram_base ||
                physical_page - fast_path->ram_base >= fast_path->ram_size) {
                return 0;
            }
            host_page = fast_path->ram +
                (physical_page - fast_path->ram_base);
            if (first_invalid != NULL) {
                entry = first_invalid;
            } else {
                size_t way = fast_path->instruction_replacement[set] &
                    (AVZ_FAST_TLB_WAY_COUNT - 1u);
                fast_path->instruction_replacement[set] =
                    (uint8_t)((way + 1u) & (AVZ_FAST_TLB_WAY_COUNT - 1u));
                entry = &fast_path->instruction_tlb[base + way];
            }
            *entry = (AVZNativeFastTLBEntry){
                .virtual_page = virtual_page,
                .physical_page = physical_page,
                .host_page = host_page,
                .context_tag = context_tag,
                .generation = fast_path->translation_generation,
                .valid = 1
            };
        }
        fast_path->instruction_hot = *entry;
    }

    physical_page = entry->physical_page;
    host_page = entry->host_page;
    if (physical_page < fast_path->ram_base) {
        return 0;
    }
    uint64_t offset = physical_page - fast_path->ram_base + page_offset;
    if (offset > fast_path->ram_size ||
        sizeof(uint32_t) > fast_path->ram_size - offset) {
        return 0;
    }
    *physical_address = fast_path->ram_base + offset;
    *host_address = host_page + page_offset;
    return 1;
}

int avz_native_fast_fetch_instruction(
    void *context,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint32_t *instruction
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint8_t *host_address = NULL;
    if (instruction == NULL ||
        !avz_fast_translate_instruction(
            fast_path,
            virtual_address,
            physical_address,
            &host_address
        )) {
        return 0;
    }
    memcpy(instruction, host_address, sizeof(*instruction));
    fast_path->statistics.instruction_fetch_hits++;
    return 1;
}

static void avz_fast_store(
    AVZNativeMemoryFastPath *fast_path,
    uint8_t *host_address,
    uint64_t physical_address,
    uint8_t width,
    uint64_t value
) {
    AVZGuestMemory *memory = fast_path->guest_memory;
    if (memory != NULL) {
        while (atomic_flag_test_and_set_explicit(
            &memory->write_lock,
            memory_order_acquire
        )) {
        }
    }
    const uintptr_t address = (uintptr_t)host_address;
    if (width == 1) {
        __atomic_store_n(host_address, (uint8_t)value, __ATOMIC_RELEASE);
    } else if (width == 2 && (address & 1u) == 0) {
        __atomic_store_n((uint16_t *)host_address, (uint16_t)value, __ATOMIC_RELEASE);
    } else if (width == 4 && (address & 3u) == 0) {
        __atomic_store_n((uint32_t *)host_address, (uint32_t)value, __ATOMIC_RELEASE);
    } else if (width == 8 && (address & 7u) == 0) {
        __atomic_store_n((uint64_t *)host_address, value, __ATOMIC_RELEASE);
    } else {
        memcpy(host_address, &value, width);
    }
    avz_fast_mark_dirty(fast_path, physical_address, width);
    if (fast_path->block_cache != 0) {
        avz_native_block_cache_invalidate_physical_range(
            fast_path->block_cache,
            physical_address,
            width
        );
    }
    if (memory != NULL) {
        atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
    }
}

static uint64_t avz_guest_memory_write_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_address,
    uint64_t ram_base,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || physical_address < ram_base) {
        return 0;
    }
    const uint64_t raw_offset = physical_address - ram_base;
    if (raw_offset > SIZE_MAX || (size_t)raw_offset >= memory->size ||
        byte_count > memory->size - (size_t)raw_offset) {
        return 0;
    }
    const size_t offset = (size_t)raw_offset;
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    uint64_t generation = 0;
    for (size_t page = first_page; page <= last_page; page++) {
        const uint64_t candidate = atomic_load_explicit(
            &memory->page_write_generations[page],
            memory_order_acquire
        );
        if (candidate > generation) {
            generation = candidate;
        }
    }
    return generation;
}

uint64_t avz_guest_memory_page_write_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_page,
    uint64_t ram_base
) {
    return avz_guest_memory_write_generation(
        memory,
        physical_page,
        ram_base,
        AVZ_FAST_PAGE_SIZE
    );
}

int avz_native_fast_memory_reservation_generation(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (generation == NULL || fast_path == NULL ||
        fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }
    *generation = avz_guest_memory_write_generation(
        fast_path->guest_memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    return 1;
}

int avz_native_fast_memory_exclusive_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        value == NULL || generation == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    while (atomic_flag_test_and_set_explicit(
        &memory->write_lock,
        memory_order_acquire
    )) {
    }
    *value = avz_fast_load(host_address, width);
    *generation = avz_guest_memory_write_generation(
        memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
    return 1;
}

int avz_native_fast_memory_exclusive_read_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *first_value,
    uint64_t *second_value,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        first_value == NULL || second_value == NULL || generation == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &first_physical,
            &first_host
        ) != AVZ_FAST_TRANSLATION_RAM ||
        avz_fast_translate(
            fast_path,
            virtual_address + width,
            width,
            0,
            &second_physical,
            &second_host
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    while (atomic_flag_test_and_set_explicit(
        &memory->write_lock,
        memory_order_acquire
    )) {
    }
    *first_value = avz_fast_load(first_host, width);
    *second_value = avz_fast_load(second_host, width);
    const uint64_t first_generation = avz_guest_memory_write_generation(
        memory,
        first_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t second_generation = avz_guest_memory_write_generation(
        memory,
        second_physical,
        fast_path->ram_base,
        width
    );
    *generation = first_generation > second_generation
        ? first_generation
        : second_generation;
    atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
    return 1;
}

int avz_native_fast_memory_exclusive_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value,
    uint64_t expected_generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            1,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return -1;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    while (atomic_flag_test_and_set_explicit(
        &memory->write_lock,
        memory_order_acquire
    )) {
    }
    const uint64_t current_generation = avz_guest_memory_write_generation(
        memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    if (current_generation != expected_generation) {
        atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
        return 0;
    }

    const uintptr_t address = (uintptr_t)host_address;
    if (width == 1) {
        __atomic_store_n(host_address, (uint8_t)value, __ATOMIC_RELEASE);
    } else if (width == 2 && (address & 1u) == 0) {
        __atomic_store_n((uint16_t *)host_address, (uint16_t)value, __ATOMIC_RELEASE);
    } else if (width == 4 && (address & 3u) == 0) {
        __atomic_store_n((uint32_t *)host_address, (uint32_t)value, __ATOMIC_RELEASE);
    } else if (width == 8 && (address & 7u) == 0) {
        __atomic_store_n((uint64_t *)host_address, value, __ATOMIC_RELEASE);
    } else {
        memcpy(host_address, &value, width);
    }
    avz_fast_mark_dirty(fast_path, physical_address, width);
    if (fast_path->block_cache != NULL) {
        avz_native_block_cache_invalidate_physical_range(
            fast_path->block_cache,
            physical_address,
            width
        );
    }
    atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
    return 1;
}

int avz_native_fast_memory_exclusive_write_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t first_value,
    uint64_t second_value,
    uint64_t expected_generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            1,
            &first_physical,
            &first_host
        ) != AVZ_FAST_TRANSLATION_RAM ||
        avz_fast_translate(
            fast_path,
            virtual_address + width,
            width,
            1,
            &second_physical,
            &second_host
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return -1;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    while (atomic_flag_test_and_set_explicit(
        &memory->write_lock,
        memory_order_acquire
    )) {
    }
    const uint64_t first_generation = avz_guest_memory_write_generation(
        memory,
        first_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t second_generation = avz_guest_memory_write_generation(
        memory,
        second_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t current_generation = first_generation > second_generation
        ? first_generation
        : second_generation;
    if (current_generation != expected_generation) {
        atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
        return 0;
    }

    memcpy(first_host, &first_value, width);
    memcpy(second_host, &second_value, width);
    avz_fast_mark_dirty(fast_path, first_physical, width);
    avz_fast_mark_dirty(fast_path, second_physical, width);
    if (fast_path->block_cache != NULL) {
        avz_native_block_cache_invalidate_physical_range(
            fast_path->block_cache,
            first_physical,
            width
        );
        avz_native_block_cache_invalidate_physical_range(
            fast_path->block_cache,
            second_physical,
            width
        );
    }
    atomic_flag_clear_explicit(&memory->write_lock, memory_order_release);
    return 1;
}

AVZNativeMemoryFastPath *avz_native_memory_fast_path_create(
    uint8_t *ram,
    uint64_t ram_base,
    uint64_t ram_size,
    AVZNativeBlockCache *block_cache,
    void *slow_context,
    AVZNativeMemoryTranslateRAMCallback translate_ram,
    AVZNativeMemoryReadCallback slow_read,
    AVZNativeMemoryWriteCallback slow_write,
    AVZNativeMemoryCanAccessCallback slow_can_access,
    AVZNativeMemoryFillCallback slow_fill,
    AVZNativeSystemRegisterReadCallback slow_read_system_register,
    AVZNativeSystemRegisterWriteCallback slow_write_system_register,
    AVZNativeSystemInstructionCallback slow_execute_system_instruction,
    AVZNativeExceptionReturnCallback slow_exception_return,
    AVZNativeSynchronousExceptionCallback slow_synchronous_exception,
    AVZNativeWaitCallback slow_wait
) {
    if (ram_size == 0 || slow_context == 0 || translate_ram == 0) {
        return 0;
    }
    AVZNativeMemoryFastPath *fast_path = calloc(1, sizeof(*fast_path));
    if (fast_path == 0) {
        return 0;
    }
    fast_path->ram = ram;
    fast_path->ram_base = ram_base;
    fast_path->ram_size = ram_size;
    fast_path->block_cache = block_cache;
    fast_path->slow_context = slow_context;
    fast_path->translate_ram = translate_ram;
    fast_path->slow_read = slow_read;
    fast_path->slow_write = slow_write;
    fast_path->slow_can_access = slow_can_access;
    fast_path->slow_fill = slow_fill;
    fast_path->slow_read_system_register = slow_read_system_register;
    fast_path->slow_write_system_register = slow_write_system_register;
    fast_path->slow_execute_system_instruction = slow_execute_system_instruction;
    fast_path->slow_exception_return = slow_exception_return;
    fast_path->slow_synchronous_exception = slow_synchronous_exception;
    fast_path->slow_wait = slow_wait;
    fast_path->translation_generation = 1;
    if (block_cache != 0 &&
        !avz_native_block_cache_bind_physical_memory(
            block_cache,
            ram,
            ram_base,
            ram_size
        )) {
        free(fast_path);
        return 0;
    }
    return fast_path;
}

void avz_native_memory_fast_path_destroy(AVZNativeMemoryFastPath *fast_path) {
    free(fast_path);
}

void avz_native_memory_fast_path_set_ram(
    AVZNativeMemoryFastPath *fast_path,
    uint8_t *ram
) {
    if (fast_path != 0) {
        if (fast_path->ram != ram) {
            avz_fast_clear_tlbs(fast_path);
            if (fast_path->block_cache != NULL && ram != NULL) {
                avz_native_block_cache_bind_physical_memory(
                    fast_path->block_cache,
                    ram,
                    fast_path->ram_base,
                    fast_path->ram_size
                );
            }
        }
        fast_path->ram = ram;
        if (fast_path->guest_memory != NULL &&
            avz_guest_memory_bytes(fast_path->guest_memory) != ram) {
            fast_path->guest_memory = NULL;
        }
    }
}

int avz_native_memory_fast_path_set_guest_memory(
    AVZNativeMemoryFastPath *fast_path,
    AVZGuestMemory *memory
) {
    if (fast_path == NULL || memory == NULL ||
        avz_guest_memory_bytes(memory) != fast_path->ram ||
        avz_guest_memory_size(memory) != fast_path->ram_size) {
        return 0;
    }
    fast_path->guest_memory = memory;
    fast_path->observed_shared_translation_epoch = atomic_load_explicit(
        &memory->translation_epoch,
        memory_order_acquire
    );
    avz_native_block_cache_set_guest_memory(fast_path->block_cache, memory);
    return 1;
}

void avz_native_memory_fast_path_set_instruction_translator(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativeMemoryTranslateRAMCallback translate_instruction_ram
) {
    if (fast_path == NULL) {
        return;
    }
    avz_native_block_cache_invalidate_decode_window(fast_path->block_cache);
    fast_path->translate_instruction_ram = translate_instruction_ram;
    memset(
        fast_path->instruction_tlb,
        0,
        sizeof(fast_path->instruction_tlb)
    );
    fast_path->instruction_hot.valid = 0;
    memset(
        fast_path->instruction_replacement,
        0,
        sizeof(fast_path->instruction_replacement)
    );
}

void avz_native_memory_fast_path_set_physical_memory_callbacks(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativePhysicalMemoryReadCallback read_physical,
    AVZNativePhysicalMemoryWriteCallback write_physical
) {
    if (fast_path == NULL) {
        return;
    }
    fast_path->read_physical = read_physical;
    fast_path->write_physical = write_physical;
}

void avz_native_memory_fast_path_set_stage1_translation(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeStage1TranslationState *state,
    AVZNativeMemoryTranslationFaultCallback report_fault
) {
    if (fast_path == NULL) {
        return;
    }
    fast_path->report_translation_fault = report_fault;
    fast_path->translation_fault_pending = 0;
    if (state == NULL) {
        if (fast_path->native_translation_enabled) {
            fast_path->native_translation_enabled = 0;
            avz_native_block_cache_invalidate_decode_window(
                fast_path->block_cache
            );
            avz_fast_clear_tlbs(fast_path);
        }
        return;
    }
    int was_enabled = fast_path->native_translation_enabled;
    int state_changed = !was_enabled ||
        !avz_stage1_translation_state_equal(
            &fast_path->translation_state,
            state
        );
    if (state_changed) {
        int geometry_changed = !was_enabled ||
            !avz_stage1_translation_geometry_equal(
                &fast_path->translation_state,
                state
            );
        fast_path->translation_state = *state;
        fast_path->native_translation_enabled = 1;
        avz_fast_refresh_translation_context_tags(fast_path);
        avz_native_block_cache_invalidate_decode_window(fast_path->block_cache);
        if (geometry_changed) {
            avz_fast_clear_tlbs(fast_path);
        }
    }
}

void avz_native_memory_fast_path_clear_translation_fault(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path != NULL) {
        fast_path->translation_fault_pending = 0;
    }
}

void avz_native_memory_fast_path_invalidate_translation(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path == 0) {
        return;
    }
    avz_native_block_cache_invalidate_decode_window(fast_path->block_cache);
    fast_path->translation_fault_pending = 0;
    avz_fast_clear_tlbs(fast_path);
}

AVZNativeMemoryFastPathStatistics avz_native_memory_fast_path_statistics(
    const AVZNativeMemoryFastPath *fast_path
) {
    AVZNativeMemoryFastPathStatistics empty = {0};
    return fast_path == 0 ? empty : fast_path->statistics;
}

void avz_native_memory_fast_path_set_thread_registers(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeThreadRegisterState *state
) {
    if (fast_path == 0 || state == 0) {
        return;
    }
    fast_path->thread_registers = *state;
    fast_path->thread_registers.dirty_mask = 0;
}

void avz_native_memory_fast_path_get_thread_registers(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeThreadRegisterState *state
) {
    if (state == 0) {
        return;
    }
    *state = fast_path == 0
        ? (AVZNativeThreadRegisterState){0}
        : fast_path->thread_registers;
}

void avz_native_memory_fast_path_set_architectural_state(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeArchitecturalState *state
) {
    if (fast_path == NULL || state == NULL)
        return;
    fast_path->architectural_state = *state;
    fast_path->architectural_state.dirty_mask = 0;
}

void avz_native_memory_fast_path_get_architectural_state(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeArchitecturalState *state
) {
    if (state == NULL)
        return;
    *state = fast_path == NULL
        ? (AVZNativeArchitecturalState){0}
        : fast_path->architectural_state;
}

static int avz_native_timer_asserted(
    uint64_t control,
    uint64_t compare,
    uint64_t counter
) {
    return (control & 1u) != 0 && (control & 2u) == 0 && counter >= compare;
}

static uint64_t avz_native_timer_control(
    uint64_t control,
    uint64_t compare,
    uint64_t counter
) {
    return (control & 3u) | (counter >= compare ? 4u : 0u);
}

static uint64_t avz_native_timer_value(uint64_t compare, uint64_t counter) {
    return (uint64_t)(uint32_t)(compare - counter);
}

static uint64_t avz_native_timer_compare_from_value(
    uint64_t value,
    uint64_t counter
) {
    int64_t offset = (int64_t)(int32_t)(uint32_t)value;
    return counter + (uint64_t)offset;
}

int avz_native_memory_fast_path_advance_time(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t instruction_count,
    uint64_t pstate
) {
    if (fast_path == NULL)
        return 0;
    AVZNativeArchitecturalState *state = &fast_path->architectural_state;
    state->counter_ticks +=
        instruction_count * state->timer_cycles_per_instruction;
    if ((pstate & 0x80u) != 0)
        return 0;
    return state->pending_irq ||
        avz_native_timer_asserted(
            state->cntp_ctl_el0, state->cntp_cval_el0, state->counter_ticks) ||
        avz_native_timer_asserted(
            state->cntv_ctl_el0, state->cntv_cval_el0, state->counter_ticks);
}

static void avz_native_fast_set_current_el(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t pstate
) {
    uint8_t current_el = (uint8_t)((pstate >> 2) & 3u);
    if (fast_path == NULL ||
        fast_path->translation_state.current_el == current_el)
        return;
    fast_path->translation_state.current_el = current_el;
    avz_fast_refresh_translation_context_tags(fast_path);
    fast_path->instruction_hot.valid = 0;
}

int avz_native_fast_memory_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (value == NULL) {
        return 0;
    }
    int translation = avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        0,
        &physical_address,
        &host_address
    );
    if (translation == AVZ_FAST_TRANSLATION_RAM) {
        *value = avz_fast_load(host_address, width);
        fast_path->statistics.read_hits++;
        return 1;
    }
    if (translation == AVZ_FAST_TRANSLATION_PHYSICAL &&
        fast_path->read_physical != NULL &&
        fast_path->read_physical(
            fast_path->slow_context,
            physical_address,
            width,
            value
        )) {
        fast_path->statistics.physical_device_reads++;
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_read != 0
        ? fast_path->slow_read(
            fast_path->slow_context,
            virtual_address,
            width,
            value
        )
        : 0;
}

int avz_native_fast_memory_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    int translation = avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        1,
        &physical_address,
        &host_address
    );
    if (translation == AVZ_FAST_TRANSLATION_RAM) {
        avz_fast_store(
            fast_path,
            host_address,
            physical_address,
            width,
            value
        );
        fast_path->statistics.write_hits++;
        return 1;
    }
    if (translation == AVZ_FAST_TRANSLATION_PHYSICAL &&
        fast_path->write_physical != NULL &&
        fast_path->write_physical(
            fast_path->slow_context,
            physical_address,
            width,
            value
        )) {
        fast_path->statistics.physical_device_writes++;
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_write != 0
        ? fast_path->slow_write(
            fast_path->slow_context,
            virtual_address,
            width,
            value
        )
        : 0;
}

int avz_native_fast_memory_read_bytes(
    void *context,
    uint64_t virtual_address,
    void *destination,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint8_t *output = destination;
    if (fast_path == NULL || output == NULL || byte_count == 0 ||
        byte_count > 64 || virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    size_t copied = 0;
    while (copied < byte_count) {
        uint64_t address = virtual_address + copied;
        size_t page_remaining = AVZ_FAST_PAGE_SIZE -
            (size_t)(address & (AVZ_FAST_PAGE_SIZE - 1u));
        size_t chunk = byte_count - copied < page_remaining
            ? byte_count - copied
            : page_remaining;
        uint64_t physical_address = 0;
        uint8_t *host_address = NULL;
        if (avz_fast_translate(
                fast_path,
                address,
                1,
                0,
                &physical_address,
                &host_address
            ) != AVZ_FAST_TRANSLATION_RAM) {
            return 0;
        }
        memcpy(output + copied, host_address, chunk);
        copied += chunk;
    }
    fast_path->statistics.read_hits++;
    return 1;
}

int avz_native_fast_memory_write_bytes(
    void *context,
    uint64_t virtual_address,
    const void *source,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    const uint8_t *input = source;
    if (fast_path == NULL || input == NULL || byte_count == 0 ||
        byte_count > 64 || virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    typedef struct {
        uint8_t *host_address;
        uint64_t physical_address;
        size_t source_offset;
        size_t byte_count;
    } AVZNativeWriteSpan;
    AVZNativeWriteSpan spans[2];
    size_t span_count = 0;
    size_t checked = 0;
    while (checked < byte_count) {
        uint64_t address = virtual_address + checked;
        size_t page_remaining = AVZ_FAST_PAGE_SIZE -
            (size_t)(address & (AVZ_FAST_PAGE_SIZE - 1u));
        size_t chunk = byte_count - checked < page_remaining
            ? byte_count - checked
            : page_remaining;
        if (span_count >= sizeof(spans) / sizeof(spans[0])) {
            return 0;
        }
        AVZNativeWriteSpan *span = &spans[span_count];
        if (avz_fast_translate(
                fast_path,
                address,
                1,
                1,
                &span->physical_address,
                &span->host_address
            ) != AVZ_FAST_TRANSLATION_RAM) {
            return 0;
        }
        span->source_offset = checked;
        span->byte_count = chunk;
        span_count++;
        checked += chunk;
    }

    for (size_t index = 0; index < span_count; index++) {
        AVZNativeWriteSpan *span = &spans[index];
        memcpy(
            span->host_address,
            input + span->source_offset,
            span->byte_count
        );
        avz_fast_mark_dirty(
            fast_path,
            span->physical_address,
            span->byte_count
        );
        if (fast_path->block_cache != NULL) {
            avz_native_block_cache_invalidate_physical_range(
                fast_path->block_cache,
                span->physical_address,
                span->byte_count
            );
        }
    }
    fast_path->statistics.write_hits++;
    return 1;
}

int avz_native_fast_memory_map_span(
    void *context,
    uint64_t virtual_address,
    size_t byte_count,
    uint8_t is_write,
    uint8_t **host_address,
    uint64_t *physical_address
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || host_address == NULL ||
        physical_address == NULL || byte_count == 0 || byte_count > 64 ||
        virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    size_t page_offset =
        (size_t)(virtual_address & (AVZ_FAST_PAGE_SIZE - 1u));
    if (byte_count > AVZ_FAST_PAGE_SIZE - page_offset) {
        return 0;
    }

    if (avz_fast_translate(
            fast_path,
            virtual_address,
            1,
            is_write != 0,
            physical_address,
            host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    uint64_t ram_offset = *physical_address - fast_path->ram_base;
    if (ram_offset > fast_path->ram_size ||
        byte_count > fast_path->ram_size - ram_offset) {
        return 0;
    }
    if (is_write != 0) {
        fast_path->statistics.write_hits++;
    } else {
        fast_path->statistics.read_hits++;
    }
    return 1;
}

void avz_native_fast_memory_commit_write_span(
    void *context,
    uint64_t physical_address,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || byte_count == 0) {
        return;
    }
    avz_fast_mark_dirty(fast_path, physical_address, byte_count);
    if (fast_path->block_cache != NULL) {
        avz_native_block_cache_invalidate_physical_range(
            fast_path->block_cache,
            physical_address,
            byte_count
        );
    }
}

int avz_native_fast_memory_can_access(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    if (avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        is_write != 0,
        &physical_address,
        NULL
    ) == AVZ_FAST_TRANSLATION_RAM) {
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_can_access != 0
        ? fast_path->slow_can_access(
            fast_path->slow_context,
            virtual_address,
            width,
            is_write
        )
        : 0;
}

int avz_native_fast_memory_fill(
    void *context,
    uint64_t virtual_address,
    uint64_t byte_count,
    uint64_t pattern,
    uint8_t pattern_width
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && byte_count != 0 &&
        (pattern_width == 1 || pattern_width == 2 ||
         pattern_width == 4 || pattern_width == 8) &&
        virtual_address <= UINT64_MAX - (byte_count - 1)) {
        uint64_t checked = 0;
        int all_ram = 1;
        while (checked < byte_count) {
            uint64_t address = virtual_address + checked;
            uint64_t page_remaining =
                AVZ_FAST_PAGE_SIZE -
                (address & (AVZ_FAST_PAGE_SIZE - 1u));
            uint64_t chunk = byte_count - checked < page_remaining
                ? byte_count - checked
                : page_remaining;
            uint64_t physical_address = 0;
            if (avz_fast_translate(
                    fast_path,
                    address,
                    1,
                    1,
                    &physical_address,
                    NULL
                ) != AVZ_FAST_TRANSLATION_RAM) {
                all_ram = 0;
                break;
            }
            checked += chunk;
        }

        if (all_ram) {
            uint8_t pattern_bytes[8] = {0};
            memcpy(pattern_bytes, &pattern, pattern_width);
            uint64_t written = 0;
            while (written < byte_count) {
                uint64_t address = virtual_address + written;
                uint64_t page_remaining =
                    AVZ_FAST_PAGE_SIZE -
                    (address & (AVZ_FAST_PAGE_SIZE - 1u));
                uint64_t chunk = byte_count - written < page_remaining
                    ? byte_count - written
                    : page_remaining;
                uint64_t physical_address = 0;
                uint8_t *host_address = NULL;
                if (avz_fast_translate(
                        fast_path,
                        address,
                        1,
                        1,
                        &physical_address,
                        &host_address
                    ) != AVZ_FAST_TRANSLATION_RAM) {
                    fast_path->statistics.fill_misses++;
                    return 0;
                }
                uint64_t phase = written % pattern_width;
                uint8_t repeated[8];
                for (size_t index = 0; index < sizeof(repeated); index++) {
                    repeated[index] =
                        pattern_bytes[(phase + index) % pattern_width];
                }
                uint64_t index = 0;
                while (chunk - index >= sizeof(repeated)) {
                    memcpy(
                        host_address + index,
                        repeated,
                        sizeof(repeated)
                    );
                    index += sizeof(repeated);
                }
                if (index < chunk) {
                    memcpy(
                        host_address + index,
                        repeated,
                        (size_t)(chunk - index)
                    );
                }
                if (fast_path->block_cache != NULL) {
                    avz_native_block_cache_invalidate_physical_range(
                        fast_path->block_cache,
                        physical_address,
                        chunk
                    );
                }
                avz_fast_mark_dirty(
                    fast_path,
                    physical_address,
                    (size_t)chunk
                );
                written += chunk;
            }
            fast_path->statistics.fill_hits++;
            return 1;
        }
        fast_path->statistics.fill_misses++;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_fill != 0
        ? fast_path->slow_fill(
            fast_path->slow_context,
            virtual_address,
            byte_count,
            pattern,
            pattern_width
        )
        : 0;
}

int avz_native_fast_read_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t pstate,
    uint64_t sp,
    uint64_t *value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != 0 && value != 0) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        switch (avz_system_register_key(instruction)) {
        case AVZ_SYSREG_SPSR_EL1:
            *value = state->spsr_el1;
            break;
        case AVZ_SYSREG_ELR_EL1:
            *value = state->elr_el1;
            break;
        case AVZ_SYSREG_SP_EL0:
            *value = (pstate & 1u) == 0 ? sp : state->sp_el0;
            break;
        case AVZ_SYSREG_ESR_EL1:
            *value = state->esr_el1;
            break;
        case AVZ_SYSREG_FAR_EL1:
            *value = state->far_el1;
            break;
        case AVZ_SYSREG_VBAR_EL1:
            *value = state->vbar_el1;
            break;
        case AVZ_SYSREG_TPIDR_EL0:
            *value = fast_path->thread_registers.tpidr_el0;
            break;
        case AVZ_SYSREG_TPIDRRO_EL0:
            *value = fast_path->thread_registers.tpidrro_el0;
            break;
        case AVZ_SYSREG_TPIDR_EL1:
            *value = fast_path->thread_registers.tpidr_el1;
            break;
        case AVZ_SYSREG_CONTEXTIDR_EL1:
            *value = fast_path->thread_registers.contextidr_el1;
            break;
        case AVZ_SYSREG_CNTPCT_EL0:
        case AVZ_SYSREG_CNTVCT_EL0:
            *value = state->counter_ticks;
            break;
        case AVZ_SYSREG_CNTP_TVAL_EL0:
            *value = avz_native_timer_value(
                state->cntp_cval_el0, state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTP_CTL_EL0:
            *value = avz_native_timer_control(
                state->cntp_ctl_el0,
                state->cntp_cval_el0,
                state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTP_CVAL_EL0:
            *value = state->cntp_cval_el0;
            break;
        case AVZ_SYSREG_CNTV_TVAL_EL0:
            *value = avz_native_timer_value(
                state->cntv_cval_el0, state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTV_CTL_EL0:
            *value = avz_native_timer_control(
                state->cntv_ctl_el0,
                state->cntv_cval_el0,
                state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTV_CVAL_EL0:
            *value = state->cntv_cval_el0;
            break;
        default:
            goto slow_path;
        }
        fast_path->statistics.local_system_register_reads++;
        return 1;
    }

slow_path:
    return fast_path != 0 && fast_path->slow_read_system_register != 0
        ? fast_path->slow_read_system_register(
            fast_path->slow_context,
            instruction,
            pc,
            pstate,
            sp,
            value
        )
        : 0;
}

int avz_native_fast_write_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t value,
    uint64_t *pstate,
    uint64_t *sp
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != 0) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        switch (avz_system_register_key(instruction)) {
        case AVZ_SYSREG_SPSR_EL1:
            state->spsr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SPSR_EL1;
            break;
        case AVZ_SYSREG_ELR_EL1:
            state->elr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_ELR_EL1;
            break;
        case AVZ_SYSREG_SP_EL0:
            if ((*pstate & 1u) == 0) {
                *sp = value;
            } else {
                state->sp_el0 = value;
            }
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
            break;
        case AVZ_SYSREG_ESR_EL1:
            state->esr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_ESR_EL1;
            break;
        case AVZ_SYSREG_FAR_EL1:
            state->far_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_FAR_EL1;
            break;
        case AVZ_SYSREG_VBAR_EL1:
            state->vbar_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_VBAR_EL1;
            break;
        case AVZ_SYSREG_TPIDR_EL0:
            fast_path->thread_registers.tpidr_el0 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL0;
            break;
        case AVZ_SYSREG_TPIDRRO_EL0:
            fast_path->thread_registers.tpidrro_el0 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDRRO_EL0;
            break;
        case AVZ_SYSREG_TPIDR_EL1:
            fast_path->thread_registers.tpidr_el1 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL1;
            break;
        case AVZ_SYSREG_CONTEXTIDR_EL1:
            fast_path->thread_registers.contextidr_el1 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_CONTEXTIDR_EL1;
            break;
        case AVZ_SYSREG_CNTP_TVAL_EL0:
            state->cntp_cval_el0 = avz_native_timer_compare_from_value(
                value, state->counter_ticks);
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTP_CTL_EL0:
            state->cntp_ctl_el0 = value & 3u;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CTL_EL0;
            break;
        case AVZ_SYSREG_CNTP_CVAL_EL0:
            state->cntp_cval_el0 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTV_TVAL_EL0:
            state->cntv_cval_el0 = avz_native_timer_compare_from_value(
                value, state->counter_ticks);
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTV_CTL_EL0:
            state->cntv_ctl_el0 = value & 3u;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CTL_EL0;
            break;
        case AVZ_SYSREG_CNTV_CVAL_EL0:
            state->cntv_cval_el0 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CVAL_EL0;
            break;
        default:
            goto slow_path;
        }
        fast_path->statistics.local_system_register_writes++;
        return 1;
    }

slow_path:
    return fast_path != 0 && fast_path->slow_write_system_register != 0
        ? fast_path->slow_write_system_register(
            fast_path->slow_context,
            instruction,
            pc,
            value,
            pstate,
            sp
        )
        : 0;
}

int avz_native_fast_execute_system_instruction(
    void *context,
    uint32_t instruction,
    uint64_t operand
) {
    AVZNativeMemoryFastPath *fast_path = context;
    return fast_path != 0 && fast_path->slow_execute_system_instruction != 0
        ? fast_path->slow_execute_system_instruction(
            fast_path->slow_context,
            instruction,
            operand
        )
        : 0;
}

int avz_native_fast_exception_return(
    void *context,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && pstate != NULL && sp != NULL && pc != NULL) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        uint64_t old_pstate = *pstate;
        uint64_t new_pstate = state->spsr_el1;
        if ((old_pstate & 1u) == 0) {
            state->sp_el0 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
        } else {
            state->sp_el1 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL1;
        }
        *sp = (new_pstate & 1u) == 0 ? state->sp_el0 : state->sp_el1;
        *pstate = new_pstate;
        *pc = state->elr_el1;
        avz_native_fast_set_current_el(fast_path, new_pstate);
        return 1;
    }
    return fast_path != 0 && fast_path->slow_exception_return != 0
        ? fast_path->slow_exception_return(
            fast_path->slow_context,
            pstate,
            sp,
            pc
        )
        : 0;
}

int avz_native_fast_synchronous_exception(
    void *context,
    uint32_t instruction,
    uint64_t *x31,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && x31 != NULL && pstate != NULL &&
        sp != NULL && pc != NULL &&
        (instruction & 0xffe0001fu) == 0xd4000001u) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        uint64_t previous_pstate = *pstate;
        uint64_t current_el = (previous_pstate >> 2) & 3u;
        uint64_t vector_offset = current_el == 0
            ? 0x400u
            : ((previous_pstate & 1u) == 0 ? 0u : 0x200u);
        if ((previous_pstate & 1u) == 0) {
            state->sp_el0 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
        } else {
            state->sp_el1 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL1;
        }
        state->spsr_el1 = previous_pstate;
        state->elr_el1 = *pc + 4u;
        state->esr_el1 = (UINT64_C(0x15) << 26) |
            ((instruction >> 5) & 0xffffu);
        state->dirty_mask |= AVZ_NATIVE_ARCH_SPSR_EL1 |
            AVZ_NATIVE_ARCH_ELR_EL1 | AVZ_NATIVE_ARCH_ESR_EL1;
        *sp = state->sp_el1;
        *pstate = UINT64_C(0x3c5);
        *pc = state->vbar_el1 + vector_offset;
        avz_native_fast_set_current_el(fast_path, *pstate);
        return 1;
    }
    return fast_path != 0 && fast_path->slow_synchronous_exception != 0
        ? fast_path->slow_synchronous_exception(
            fast_path->slow_context,
            instruction,
            x31,
            pstate,
            sp,
            pc
        )
        : 0;
}

int avz_native_fast_wait(
    void *context,
    uint32_t instruction,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    return fast_path != 0 && fast_path->slow_wait != 0
        ? fast_path->slow_wait(fast_path->slow_context, instruction, pc)
        : 0;
}
