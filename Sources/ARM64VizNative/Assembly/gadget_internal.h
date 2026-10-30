#ifndef PINECONE_PHASE3_GADGET_INTERNAL_H
#define PINECONE_PHASE3_GADGET_INTERNAL_H
#include "gadget.h"
#include "../ARM64VizGuestMemoryInternal.h"

/* Handler symbols have a private assembly convention; never call them from C. */
typedef void (*AGHandler)(void);
/* Scalar memory auxiliary layout: width[7:0], decoded load/sign/W/writeback
 * flags[11:8], register-address flag[12], signed writeback delta OR register
 * offset[31:16], extension[34:32], scaling[42:40]. For pairs, bit 13 identifies
 * the form and [47:32] holds the second register instead. Never a code pointer. */
enum {
    AG_MEM_LOAD = 1u << 8, AG_MEM_SIGN = 1u << 9,
    AG_MEM_RESULT32 = 1u << 10, AG_MEM_WRITEBACK = 1u << 11,
    AG_MEM_REGISTER = 1u << 12, AG_MEM_PAIR = 1u << 13,
    AG_MEM_SECOND_SHIFT = 32,
    AG_MEM_OPERAND_SHIFT = 16, AG_MEM_EXTEND_SHIFT = 32, AG_MEM_SCALE_SHIFT = 40
};
typedef struct AGOperation {
    AGHandler handler;
    uint64_t next_pc;
    uint64_t immediate;
    const struct AGOperation *taken;
    uint64_t auxiliary;
    uint32_t raw;
    uint16_t source, destination;
} AGOperation;
typedef struct {
    uint64_t base;
    size_t count;
    const AGOperation *entries;
} AGTargetRange;
struct AGProgram {
    AGTargetRange targets;
    uint32_t active_runs, retired, capability;
    AGOperation operations[];
};
/* Owner-confined mapping metadata cannot change without a helper exit. Shared
 * epochs/observation/dirty state remain live atomic reads, not copied proofs. */
typedef struct AGRun AGRun;
typedef struct {
    const _Atomic uint64_t *events;
    uint64_t remaining, entries, polls;
    /* NULL for the offline chain. Ordinary-ABI hook for resident visits only. */
    int (*service)(AGRun *);
} AGChainControl;
/* Bounded-only extension. Neither AGRun nor the ordinary chain ABI changes. */
typedef struct {
    const uint64_t *serial;
    uint64_t expected_serial;
    const uint64_t *local_generation;
    uint64_t expected_local_generation;
    const _Atomic uint64_t *shared_generation;
    uint64_t expected_shared_generation;
} AGBoundedProof;
enum { AG_BOUNDED_EVENT = 1 };
typedef struct {
    AGChainControl chain;
    const AGBoundedProof *proofs;
    size_t count;
    uint64_t last_member, previous_member, member_start;
    uint32_t stop, terminal;
} AGBoundedControl;
typedef struct {
    AVZNativeMemoryFastPath *path;
    AVZNativeFastTLBEntry *read_hot, *write_hot;
    AVZNativeDirtyHotEntry *dirty_hot;
    AVZGuestMemory *shared;
    uint64_t ram_base, ram_size, generation, low_tag, high_tag;
    uint64_t observed_translation, translation_epoch, code_epoch;
    uint8_t eligible;
} AGMemory;
struct AGRun {
    AVZNativeCPU *cpu;
    const AGOperation *operation;
    uint64_t budget;
    AGGuards guards;
    AVZNativeBlockResult result;
    AGMemory memory;
    AGChainControl *chain;
    const AGTargetRange *targets;
    size_t target_count;
};

_Static_assert(sizeof(AGOperation) == 48, "compact operation layout changed");
_Static_assert(sizeof(void *) == 8, "64-bit host required");
_Static_assert(sizeof(AVZNativeCPU) < INT16_MAX, "signed register offset sentinel");
_Static_assert(offsetof(AGMemory, high_tag) == offsetof(AGMemory, low_tag) + 8, "paired context load");
_Static_assert(sizeof(_Atomic uint64_t) == 8 && sizeof(_Atomic uint8_t) == 1,
    "assembly atomic storage width");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_CHAR_LOCK_FREE == 2,
    "assembly requires lock-free host atomics");

/* Private veneer: non-null CPU/operation, positive budget, live immutable
 * operation allocation, initialized result and caller-owned guard references. */
void ag_enter(AGRun *run);
/* A chain service hook returns nonzero only after validating/preparing the
 * next visit. Helpers/guard failures return without invoking that hook. */
/* Prepare per entry, never persist across helper exits or epoch changes.
 * Inlining avoids a call and lets entry setup share loads/registers. */
static inline void ag_memory_prepare_inline(AGMemory *v, AVZNativeMemoryFastPath *p) {
    v->path = p;
    v->shared = NULL;
    if (!p) return;
    v->shared = p->guest_memory;
    v->read_hot = p->read_hot;
    v->write_hot = p->write_hot;
    v->dirty_hot = p->dirty_hot;
    v->ram_base = p->ram_base;
    v->ram_size = p->ram_size;
    v->generation = p->hot_translation_generation;
    v->low_tag = p->native_translation_enabled ? p->low_translation_context_tag : 0;
    v->high_tag = p->native_translation_enabled ? p->high_translation_context_tag : 0;
    v->observed_translation = p->observed_shared_translation_epoch;
    v->eligible = p->ram && v->shared && !p->detailed_statistics_enabled;
    if (v->shared) {
        v->translation_epoch = atomic_load_explicit(&v->shared->translation_epoch, memory_order_acquire);
        v->code_epoch = atomic_load_explicit(&v->shared->code_mutation_epoch, memory_order_acquire);
    }
}
void ag_memory_prepare(AGMemory *view, AVZNativeMemoryFastPath *path);
/* Experimental only: inline preparation with guard coalescing, not production. */
AVZNativeBlockResult ag_run_memory_coalesced(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory);
/* Same inline preparation and assembly entry as production; no coalescing. */
AVZNativeBlockResult ag_run_memory_uncoalesced(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory);
/* Historical out-of-line preparation control, also without coalescing. */
AVZNativeBlockResult ag_run_memory_control(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory);
uint32_t ag_memory_slow(AGRun *run, const AGOperation *operation);
void ag_memory_commit(AGRun *run, const AGOperation *operation, uint64_t physical_address);
AVZNativeBlockResult ag_reference_cpu(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu);
AVZNativeBlockResult ag_reference_memory(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory);
AVZNativeBlockResult ag_reference_pair(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory);
#endif
