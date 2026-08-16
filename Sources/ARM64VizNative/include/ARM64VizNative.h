#ifndef ARM64VIZ_NATIVE_H
#define ARM64VIZ_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AVZ_NATIVE_STATUS_OUTSIDE_BLOCK = 0,
    AVZ_NATIVE_STATUS_HALTED = 1,
    AVZ_NATIVE_STATUS_UNSUPPORTED = 2,
    AVZ_NATIVE_STATUS_MAX_STEPS = 3,
    AVZ_NATIVE_STATUS_YIELDED = 4
};

enum {
    AVZ_NATIVE_WAIT_UNSUPPORTED = 0,
    AVZ_NATIVE_WAIT_CONTINUE = 1,
    AVZ_NATIVE_WAIT_YIELD = 2
};

enum {
    AVZ_NATIVE_OP_NOP = 1,
    AVZ_NATIVE_OP_HALT = 2,
    AVZ_NATIVE_OP_ADR = 3,
    AVZ_NATIVE_OP_CBZ = 4,
    AVZ_NATIVE_OP_TBZ = 5,
    AVZ_NATIVE_OP_BCOND = 6,
    AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE = 7,
    AVZ_NATIVE_OP_MOVE_WIDE = 8,
    AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER = 9,
    AVZ_NATIVE_OP_BRANCH = 10,
    AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE = 11,
    AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE = 12,
    AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET = 13,
    AVZ_NATIVE_OP_LOAD_STORE_PAIR = 14,
    AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER = 15,
    AVZ_NATIVE_OP_LOGICAL_IMMEDIATE = 16,
    AVZ_NATIVE_OP_REGISTER_BRANCH = 17,
    AVZ_NATIVE_OP_CONDITIONAL_SELECT = 18,
    AVZ_NATIVE_OP_BITFIELD_MOVE = 19,
    AVZ_NATIVE_OP_DATA_PROCESSING_ONE_SOURCE = 20,
    AVZ_NATIVE_OP_DATA_PROCESSING_TWO_SOURCE = 21,
    AVZ_NATIVE_OP_LOAD_LITERAL = 22,
    AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER = 23,
    AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE = 24,
    AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER = 25,
    AVZ_NATIVE_OP_MULTIPLY_ADD_SUBTRACT = 26,
    AVZ_NATIVE_OP_SIGNED_MULTIPLY_LONG_ADD_SUBTRACT = 27,
    AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_LONG_ADD_SUBTRACT = 28,
    AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE = 29,
    AVZ_NATIVE_OP_ADD_SUB_CARRY = 30,
    AVZ_NATIVE_OP_EXTRACT_REGISTER = 31,
    AVZ_NATIVE_OP_SIGNED_MULTIPLY_HIGH = 32,
    AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_HIGH = 33,
    AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL = 34,
    AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE = 35,
    AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE = 36,
    AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP = 37,
    AVZ_NATIVE_OP_SIMD_INSERT_GENERAL_TO_ELEMENT = 38,
    AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D = 39,
    AVZ_NATIVE_OP_SIMD_ADD_VECTOR = 40,
    AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL = 41,
    AVZ_NATIVE_OP_SIMD_MOVI_ZERO = 42,
    AVZ_NATIVE_OP_SIMD_MOVI_BYTE = 43,
    AVZ_NATIVE_OP_SIMD_MVNI_IMMEDIATE = 44,
    AVZ_NATIVE_OP_SIMD_MOVI_D_IMMEDIATE = 45,
    AVZ_NATIVE_OP_SIMD_TABLE_LOOKUP = 46,
    AVZ_NATIVE_OP_SIMD_PERMUTE_TWO_VECTOR = 47,
    AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE = 48,
    AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE_PAIR = 49,
    AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE = 50,
    AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR = 51,
    AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP = 52,
    AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC = 53,
    AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_SELECT = 54,
    AVZ_NATIVE_OP_FP_SCALAR_COMPARE = 55,
    AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER = 56,
    AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR = 57,
    AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS = 58,
    AVZ_NATIVE_OP_SIMD_ORR_VECTOR = 59,
    AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE = 60,
    AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE = 61,
    AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE = 62,
    AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET = 63,
    AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION = 64,
    AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE = 65,
    AVZ_NATIVE_OP_SYSTEM_REGISTER_READ = 66,
    AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE = 67,
    AVZ_NATIVE_OP_BARRIER = 68,
    AVZ_NATIVE_OP_SYSTEM_INSTRUCTION = 69,
    AVZ_NATIVE_OP_EXCEPTION_RETURN = 70,
    AVZ_NATIVE_OP_PSTATE_IMMEDIATE = 71,
    AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION = 72,
    AVZ_NATIVE_OP_WAIT = 73,
    AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE = 74,
    AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT = 75,
    AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE = 76,
    AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR = 77,
    AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD = 78,
    AVZ_NATIVE_OP_FP_SCALAR_UNARY = 79,
    AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE = 80,
    AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE = 81,
    AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY = 82,
    AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG = 83,
    AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE = 84,
    AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL = 85,
    AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE = 86,
    AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE = 87,
    AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG = 88,
    AVZ_NATIVE_OP_SIMD_NARROW_HIGH = 89,
    AVZ_NATIVE_OP_SIMD_BITWISE_NOT = 90,
    AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT = 91,
    AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE = 92,
    AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT = 93,
    AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER = 94,
    AVZ_NATIVE_OP_FP_SCALAR_MINMAX = 95,
    AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX = 96,
    AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS = 97,
    AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR = 98,
    AVZ_NATIVE_OP_SIMD_FP_CONVERT_NARROW_WIDEN = 99,
    AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR = 100,
    AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD = 101,
    AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE = 102,
    AVZ_NATIVE_OP_FP_RECIPROCAL_STEP = 103,
    AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER = 104,
    AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS = 105,
    AVZ_NATIVE_OP_COUNT = 106
};

typedef struct {
    uint64_t low;
    uint64_t high;
} AVZNativeVectorRegister;

typedef struct {
    uint64_t x[31];
    AVZNativeVectorRegister v[32];
    uint64_t sp;
    uint64_t pc;
    uint64_t pstate;
    uint64_t fpcr;
    uint64_t fpsr;
    uint64_t exclusive_address;
    uint64_t exclusive_generation;
    uint8_t exclusive_size;
    uint8_t exclusive_valid;
    uint8_t halted;
} AVZNativeCPU;

typedef struct {
    uint64_t steps;
    uint64_t generic_dispatches;
    uint64_t fast_path_steps;
    uint64_t fast_path_hits;
    uint32_t status;
    uint32_t unsupported_instruction;
} AVZNativeBlockResult;

typedef struct {
    uint32_t raw;
    uint16_t kind;
    uint8_t rd;
    uint8_t rn;
    uint8_t rm;
    uint8_t rt;
    uint8_t width;
    uint8_t bits;
    uint8_t flags;
    uint8_t condition;
    uint8_t shift_type;
    uint8_t shift_amount;
    int64_t immediate;
    int64_t immediate2;
} AVZNativeInstruction;

enum {
    AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS = 32,
    AVZ_NATIVE_BLOCK_MAX_CODE_PAGES = 2,
    AVZ_NATIVE_BLOCK_DECODE_OK = 0,
    AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT = 1,
    AVZ_NATIVE_BLOCK_DECODE_UNSUPPORTED = 2
};

typedef struct {
    uint64_t pc;
    uint64_t sctlr_el1;
    uint64_t tcr_el1;
    uint64_t ttbr0_el1;
    uint64_t ttbr1_el1;
    uint8_t current_el;
} AVZNativeBlockKey;

typedef struct AVZNativeBlockCache AVZNativeBlockCache;
typedef struct AVZNativeDecodedBlock AVZNativeDecodedBlock;
typedef struct AVZGuestMemory AVZGuestMemory;
typedef struct AVZNativeMemoryFastPath AVZNativeMemoryFastPath;
typedef struct AVZNativeExecutionContext AVZNativeExecutionContext;

typedef struct {
    void *base;
    size_t length;
} AVZBlockIOSegment;

int64_t avz_block_io_preadv(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
);
int64_t avz_block_io_pwritev(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
);

typedef int (*AVZNativeInstructionFetchCallback)(
    void *context,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint32_t *instruction
);

typedef struct {
    uint64_t hits;
    uint64_t misses;
    uint64_t decodes;
    uint64_t evictions;
    uint64_t invalidations;
    uint64_t invalidation_checks;
    uint64_t invalidation_skips;
    uint64_t front_hits;
    uint64_t code_page_generation_bumps;
    uint64_t stale_block_discards;
    uint64_t direct_code_fetches;
    uint64_t decode_window_hits;
    uint64_t decode_window_misses;
    uint64_t batch_prefetched_blocks;
    uint64_t batch_prefetch_hits;
    uint64_t batch_prefetch_unused;
    uint64_t batch_prefetch_limit_changes;
    uint32_t batch_prefetch_limit;
} AVZNativeBlockCacheStatistics;

typedef struct {
    uint64_t steps;
    uint64_t blocks;
    uint64_t direct_link_hits;
    uint64_t direct_link_misses;
    uint64_t superblock_hits;
    uint64_t superblock_front_hits;
    uint64_t superblock_blocks;
    uint64_t superblock_dispatches;
    uint64_t generic_dispatches;
    uint64_t fast_path_steps;
    uint64_t fast_path_hits;
    uint32_t status;
    uint32_t decode_status;
    uint32_t unsupported_instruction;
} AVZNativeChainResult;

typedef struct {
    uint64_t pc;
    uint64_t samples;
    uint32_t instruction0;
    uint32_t instruction1;
    uint32_t instruction2;
    uint32_t instruction3;
    uint8_t instruction_count;
} AVZNativeHotPC;

typedef uint64_t (*AVZNativeChainCheckpointCallback)(
    void *context,
    uint64_t execution_steps,
    uint64_t execution_blocks,
    uint64_t total_steps,
    uint64_t pc,
    uint64_t pstate,
    uint64_t remaining_steps
);

AVZNativeBlockCache *avz_native_block_cache_create(void);
void avz_native_block_cache_destroy(AVZNativeBlockCache *cache);
void avz_native_block_cache_clear(AVZNativeBlockCache *cache);
int avz_native_block_cache_configure_physical_range(
    AVZNativeBlockCache *cache,
    uint64_t physical_address,
    uint64_t byte_count
);
int avz_native_block_cache_bind_physical_memory(
    AVZNativeBlockCache *cache,
    uint8_t *ram,
    uint64_t physical_address,
    uint64_t byte_count
);
void avz_native_block_cache_set_guest_memory(
    AVZNativeBlockCache *cache,
    AVZGuestMemory *memory
);
void avz_native_block_cache_invalidate_decode_window(
    AVZNativeBlockCache *cache
);

const AVZNativeDecodedBlock *avz_native_block_cache_get_or_decode(
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    uint32_t *decode_status,
    uint32_t *unsupported_instruction
);

void avz_native_block_cache_invalidate_physical_range(
    AVZNativeBlockCache *cache,
    uint64_t physical_address,
    uint64_t byte_count
);

AVZNativeBlockCacheStatistics avz_native_block_cache_statistics(
    const AVZNativeBlockCache *cache
);

const AVZNativeInstruction *avz_native_decoded_block_instructions(
    const AVZNativeDecodedBlock *block
);
size_t avz_native_decoded_block_instruction_count(const AVZNativeDecodedBlock *block);
uint64_t avz_native_decoded_block_pc(const AVZNativeDecodedBlock *block);
int avz_native_decoded_block_uses_vector_state(const AVZNativeDecodedBlock *block);
size_t avz_native_decoded_block_code_page_count(
    const AVZNativeDecodedBlock *block
);
uint64_t avz_native_decoded_block_physical_code_page(
    const AVZNativeDecodedBlock *block,
    size_t index
);
const uint8_t *avz_native_decoded_block_host_code_page(
    const AVZNativeDecodedBlock *block,
    size_t index
);
int avz_native_block_cache_register_trace_code_page(
    AVZNativeBlockCache *cache,
    uint64_t physical_code_page,
    const uint64_t **generation_token,
    uint64_t *generation
);
uint64_t avz_native_decoded_block_serial(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
);
const uint64_t *avz_native_decoded_block_serial_token(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
);
int avz_native_decoded_block_code_is_current(
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block
);
int avz_native_block_cache_validate_block(
    const AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *block,
    uint64_t serial,
    const AVZNativeBlockKey *key
);
uint64_t avz_native_block_cache_generation(
    const AVZNativeBlockCache *cache
);
uint64_t avz_native_block_cache_mutation_epoch(
    const AVZNativeBlockCache *cache
);
uint64_t avz_native_block_cache_code_mutation_epoch(
    const AVZNativeBlockCache *cache
);
const uint64_t *avz_native_block_cache_code_mutation_epoch_token(
    const AVZNativeBlockCache *cache
);
uint64_t avz_native_block_cache_reset_epoch(
    const AVZNativeBlockCache *cache
);

typedef int (*AVZNativeMemoryReadCallback)(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value
);

typedef int (*AVZNativeMemoryWriteCallback)(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value
);

typedef int (*AVZNativePhysicalMemoryReadCallback)(
    void *context,
    uint64_t physical_address,
    uint8_t width,
    uint64_t *value
);

typedef int (*AVZNativePhysicalMemoryWriteCallback)(
    void *context,
    uint64_t physical_address,
    uint8_t width,
    uint64_t value
);

typedef int (*AVZNativeMemoryCanAccessCallback)(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write
);

typedef int (*AVZNativeMemoryFillCallback)(
    void *context,
    uint64_t virtual_address,
    uint64_t byte_count,
    uint64_t pattern,
    uint8_t pattern_width
);

typedef int (*AVZNativeSystemRegisterReadCallback)(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t pstate,
    uint64_t sp,
    uint64_t *value
);

typedef int (*AVZNativeSystemRegisterWriteCallback)(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t value,
    uint64_t *pstate,
    uint64_t *sp
);

typedef int (*AVZNativeSystemInstructionCallback)(
    void *context,
    uint32_t instruction,
    uint64_t operand
);

typedef int (*AVZNativeExceptionReturnCallback)(
    void *context,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
);

typedef int (*AVZNativeSynchronousExceptionCallback)(
    void *context,
    uint32_t instruction,
    uint64_t *x31,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
);

typedef int (*AVZNativeWaitCallback)(
    void *context,
    uint32_t instruction,
    uint64_t *pc
);

typedef int (*AVZNativeMemoryTranslateRAMCallback)(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *physical_address
);

enum {
    AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION = 0,
    AVZ_NATIVE_MEMORY_ACCESS_READ = 1,
    AVZ_NATIVE_MEMORY_ACCESS_WRITE = 2
};

typedef struct {
    uint64_t sctlr_el1;
    uint64_t tcr_el1;
    uint64_t ttbr0_el1;
    uint64_t ttbr1_el1;
    uint8_t current_el;
} AVZNativeStage1TranslationState;

typedef void (*AVZNativeMemoryTranslationFaultCallback)(
    void *context,
    uint64_t virtual_address,
    uint8_t access,
    uint8_t level,
    uint8_t status_code
);

typedef struct {
    uint64_t read_hits;
    uint64_t write_hits;
    uint64_t read_tlb_hits;
    uint64_t read_tlb_misses;
    uint64_t write_tlb_hits;
    uint64_t write_tlb_misses;
    uint64_t fill_hits;
    uint64_t fill_misses;
    uint64_t local_system_register_reads;
    uint64_t local_system_register_writes;
    uint64_t instruction_fetch_hits;
    uint64_t instruction_tlb_hits;
    uint64_t instruction_tlb_misses;
    uint64_t native_page_table_walks;
    uint64_t native_page_table_faults;
    uint64_t translation_callback_walks;
    uint64_t physical_device_reads;
    uint64_t physical_device_writes;
} AVZNativeMemoryFastPathStatistics;

enum {
    AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL0 = 1u << 0,
    AVZ_NATIVE_THREAD_REGISTER_TPIDRRO_EL0 = 1u << 1,
    AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL1 = 1u << 2,
    AVZ_NATIVE_THREAD_REGISTER_CONTEXTIDR_EL1 = 1u << 3
};

typedef struct {
    uint64_t tpidr_el0;
    uint64_t tpidrro_el0;
    uint64_t tpidr_el1;
    uint64_t contextidr_el1;
    uint32_t dirty_mask;
} AVZNativeThreadRegisterState;

enum {
    AVZ_NATIVE_ARCH_SP_EL0 = 1u << 0,
    AVZ_NATIVE_ARCH_SP_EL1 = 1u << 1,
    AVZ_NATIVE_ARCH_SPSR_EL1 = 1u << 2,
    AVZ_NATIVE_ARCH_ELR_EL1 = 1u << 3,
    AVZ_NATIVE_ARCH_ESR_EL1 = 1u << 4,
    AVZ_NATIVE_ARCH_FAR_EL1 = 1u << 5,
    AVZ_NATIVE_ARCH_VBAR_EL1 = 1u << 6,
    AVZ_NATIVE_ARCH_CNTP_CTL_EL0 = 1u << 7,
    AVZ_NATIVE_ARCH_CNTP_CVAL_EL0 = 1u << 8,
    AVZ_NATIVE_ARCH_CNTV_CTL_EL0 = 1u << 9,
    AVZ_NATIVE_ARCH_CNTV_CVAL_EL0 = 1u << 10
};

typedef struct {
    uint64_t sp_el0;
    uint64_t sp_el1;
    uint64_t spsr_el1;
    uint64_t elr_el1;
    uint64_t esr_el1;
    uint64_t far_el1;
    uint64_t vbar_el1;
    uint64_t counter_ticks;
    uint64_t cntp_ctl_el0;
    uint64_t cntp_cval_el0;
    uint64_t cntv_ctl_el0;
    uint64_t cntv_cval_el0;
    uint64_t timer_cycles_per_instruction;
    uint32_t dirty_mask;
    uint8_t pending_irq;
} AVZNativeArchitecturalState;

AVZGuestMemory *avz_guest_memory_create(size_t size);
void avz_guest_memory_destroy(AVZGuestMemory *memory);
uint8_t *avz_guest_memory_bytes(AVZGuestMemory *memory);
size_t avz_guest_memory_size(const AVZGuestMemory *memory);
uint64_t avz_guest_memory_page_write_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_page,
    uint64_t ram_base
);

typedef struct {
    size_t offset;
    size_t length;
} AVZGuestDirtyRange;

void avz_guest_memory_mark_dirty(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
);
void avz_guest_memory_note_write(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
);
void avz_guest_memory_invalidate_translations(AVZGuestMemory *memory);
uint64_t avz_guest_memory_translation_epoch(const AVZGuestMemory *memory);
uint64_t avz_guest_memory_advance_dirty_epoch(AVZGuestMemory *memory);
size_t avz_guest_memory_dirty_ranges(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint64_t after_epoch,
    uint64_t through_epoch,
    AVZGuestDirtyRange *ranges,
    size_t range_capacity
);

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
);
void avz_native_memory_fast_path_destroy(AVZNativeMemoryFastPath *fast_path);
void avz_native_memory_fast_path_set_ram(
    AVZNativeMemoryFastPath *fast_path,
    uint8_t *ram
);
int avz_native_memory_fast_path_set_guest_memory(
    AVZNativeMemoryFastPath *fast_path,
    AVZGuestMemory *memory
);
void avz_native_memory_fast_path_set_instruction_translator(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativeMemoryTranslateRAMCallback translate_instruction_ram
);
void avz_native_memory_fast_path_set_physical_memory_callbacks(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativePhysicalMemoryReadCallback read_physical,
    AVZNativePhysicalMemoryWriteCallback write_physical
);
void avz_native_memory_fast_path_set_stage1_translation(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeStage1TranslationState *state,
    AVZNativeMemoryTranslationFaultCallback report_fault
);
void avz_native_memory_fast_path_clear_translation_fault(
    AVZNativeMemoryFastPath *fast_path
);
void avz_native_memory_fast_path_invalidate_translation(
    AVZNativeMemoryFastPath *fast_path
);
void avz_native_memory_fast_path_set_thread_registers(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeThreadRegisterState *state
);
void avz_native_memory_fast_path_get_thread_registers(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeThreadRegisterState *state
);
void avz_native_memory_fast_path_set_architectural_state(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeArchitecturalState *state
);
void avz_native_memory_fast_path_get_architectural_state(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeArchitecturalState *state
);
int avz_native_memory_fast_path_advance_time(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t instruction_count,
    uint64_t pstate
);
AVZNativeMemoryFastPathStatistics avz_native_memory_fast_path_statistics(
    const AVZNativeMemoryFastPath *fast_path
);

int avz_native_fast_fetch_instruction(
    void *context,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint32_t *instruction
);

int avz_native_fast_memory_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value
);
int avz_native_fast_memory_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value
);
int avz_native_fast_memory_reservation_generation(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *generation
);
int avz_native_fast_memory_exclusive_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value,
    uint64_t *generation
);
int avz_native_fast_memory_exclusive_read_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *first_value,
    uint64_t *second_value,
    uint64_t *generation
);
int avz_native_fast_memory_exclusive_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value,
    uint64_t expected_generation
);
int avz_native_fast_memory_exclusive_write_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t first_value,
    uint64_t second_value,
    uint64_t expected_generation
);
int avz_native_fast_memory_read_bytes(
    void *context,
    uint64_t virtual_address,
    void *destination,
    size_t byte_count
);
int avz_native_fast_memory_write_bytes(
    void *context,
    uint64_t virtual_address,
    const void *source,
    size_t byte_count
);
int avz_native_fast_memory_map_span(
    void *context,
    uint64_t virtual_address,
    size_t byte_count,
    uint8_t is_write,
    uint8_t **host_address,
    uint64_t *physical_address
);
void avz_native_fast_memory_commit_write_span(
    void *context,
    uint64_t physical_address,
    size_t byte_count
);
int avz_native_fast_memory_can_access(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write
);
int avz_native_fast_memory_fill(
    void *context,
    uint64_t virtual_address,
    uint64_t byte_count,
    uint64_t pattern,
    uint8_t pattern_width
);
int avz_native_fast_read_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t pstate,
    uint64_t sp,
    uint64_t *value
);
int avz_native_fast_write_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t value,
    uint64_t *pstate,
    uint64_t *sp
);
int avz_native_fast_execute_system_instruction(
    void *context,
    uint32_t instruction,
    uint64_t operand
);
int avz_native_fast_exception_return(
    void *context,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
);
int avz_native_fast_synchronous_exception(
    void *context,
    uint32_t instruction,
    uint64_t *x31,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
);
int avz_native_fast_wait(
    void *context,
    uint32_t instruction,
    uint64_t *pc
);

int avz_native_instruction_supported(uint32_t instruction);

int avz_native_decode_instruction(uint32_t instruction, AVZNativeInstruction *decoded);

AVZNativeBlockResult avz_native_run_block(
    const uint32_t *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    AVZNativeCPU *cpu
);

AVZNativeBlockResult avz_native_run_block_registers(
    const uint32_t *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted
);

AVZNativeBlockResult avz_native_run_decoded_block_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
);

AVZNativeBlockResult avz_native_run_threaded_decoded_block_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
);

AVZNativeBlockResult avz_native_run_threaded_decoded_block_full_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
);

AVZNativeBlockResult avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
);

AVZNativeExecutionContext *avz_native_execution_context_create(void);
void avz_native_execution_context_destroy(AVZNativeExecutionContext *context);
void avz_native_execution_context_load(
    AVZNativeExecutionContext *context,
    const uint64_t *x31,
    const uint64_t *v32_low,
    const uint64_t *v32_high,
    uint64_t sp,
    uint64_t pc,
    uint64_t pstate,
    uint64_t fpcr,
    uint64_t fpsr,
    uint64_t exclusive_address,
    uint8_t exclusive_size,
    uint8_t exclusive_valid,
    uint8_t halted
);
void avz_native_execution_context_store(
    const AVZNativeExecutionContext *context,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted
);
uint64_t avz_native_execution_context_pc(
    const AVZNativeExecutionContext *context
);
uint64_t avz_native_execution_context_pstate(
    const AVZNativeExecutionContext *context
);
uint8_t avz_native_execution_context_halted(
    const AVZNativeExecutionContext *context
);
size_t avz_native_execution_context_copy_hot_pcs(
    const AVZNativeExecutionContext *context,
    AVZNativeHotPC *entries,
    size_t capacity
);
void avz_native_execution_context_reset_hot_pc_profile(
    AVZNativeExecutionContext *context
);
void avz_native_execution_context_set_hot_pc_profiling(
    AVZNativeExecutionContext *context,
    int enabled
);
AVZNativeChainResult avz_native_execution_context_run_cached_chain(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key_template,
    uint64_t max_steps,
    uint64_t max_blocks,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
);
AVZNativeChainResult avz_native_execution_context_run_cached_chain_checkpointed(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key_template,
    uint64_t initial_block_step_limit,
    uint64_t max_steps,
    uint64_t max_blocks,
    uint64_t checkpoint_block_interval,
    AVZNativeChainCheckpointCallback checkpoint,
    void *checkpoint_context,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
);

enum {
    AVZ_FRAMEBUFFER_MAX_DAMAGE_RECTS = 512
};

typedef struct {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
} AVZFramebufferDamageRect;

typedef struct AVZFramebufferSurface AVZFramebufferSurface;

AVZFramebufferSurface *avz_framebuffer_surface_create(size_t byte_count);
void avz_framebuffer_surface_destroy(AVZFramebufferSurface *surface);
uint8_t *avz_framebuffer_surface_bytes(AVZFramebufferSurface *surface);
size_t avz_framebuffer_surface_byte_count(const AVZFramebufferSurface *surface);
size_t avz_framebuffer_surface_allocation_size(const AVZFramebufferSurface *surface);
void avz_framebuffer_surface_clear(AVZFramebufferSurface *surface);

int avz_framebuffer_normalize_bgra8(
    uint8_t *pixels,
    size_t stride,
    size_t width,
    size_t height,
    uint32_t format
);

int avz_framebuffer_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
);

int avz_framebuffer_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
);

int avz_framebuffer_scale_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
);

int avz_framebuffer_scale_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
);

int avz_framebuffer_bilinear_scale_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
);

int avz_framebuffer_bilinear_scale_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
);

int avz_framebuffer_fill_bgra8(
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    uint32_t premultiplied_bgra
);

int avz_framebuffer_fill_over_bgra8(
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    uint32_t premultiplied_bgra
);

int avz_framebuffer_masked_composite_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    const uint8_t *mask,
    size_t mask_stride,
    uint8_t solid_mask_alpha,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height,
    uint32_t premultiplied_bgra,
    uint32_t operation,
    int bilinear_filtering
);

int avz_framebuffer_composite_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    const uint8_t *mask,
    size_t mask_stride,
    uint8_t solid_mask_alpha,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height,
    uint32_t premultiplied_bgra,
    uint32_t blend_operator,
    int source_is_solid,
    int bilinear_filtering,
    int component_alpha_mask,
    int mask_is_packed_a8
);

size_t avz_framebuffer_commit_dirty_tiles(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    size_t tile_width,
    size_t tile_height,
    AVZFramebufferDamageRect *damage_rects,
    size_t damage_capacity,
    size_t *changed_byte_count
);

#ifdef __cplusplus
}
#endif

#endif
