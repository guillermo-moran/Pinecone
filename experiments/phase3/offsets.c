#include "gadget_internal.h"
#include <stdio.h>
#define FIELD(name, type, member) do { \
    printf("#define " #name " %zu\n", offsetof(type, member)); \
    printf("#ifndef __ASSEMBLER__\n_Static_assert(" #name " == offsetof(" #type ", " #member "), \"stale assembly offset\");\n#endif\n"); \
} while (0)
#define VALUE(name, value) do { \
    printf("#define " #name " %zu\n", (size_t)(value)); \
    printf("#ifndef __ASSEMBLER__\n_Static_assert(" #name " == (" #value "), \"stale assembly constant\");\n#endif\n"); \
} while (0)
int main(void) {
    FIELD(G_CPU, AGRun, cpu); FIELD(G_OP, AGRun, operation);
    FIELD(G_BUDGET, AGRun, budget); FIELD(G_LOCAL, AGRun, guards.local);
    FIELD(G_SHARED0, AGRun, guards.shared[0]); FIELD(G_SHARED1, AGRun, guards.shared[1]);
    FIELD(G_SHARED2, AGRun, guards.shared[2]);
    FIELD(G_EPOCH0, AGRun, guards.expected[0]); FIELD(G_EPOCH1, AGRun, guards.expected[1]);
    FIELD(G_EPOCH2, AGRun, guards.expected[2]); FIELD(G_EPOCH3, AGRun, guards.expected[3]);
    FIELD(G_STEPS, AGRun, result.steps); FIELD(G_DISPATCHES, AGRun, result.generic_dispatches);
    FIELD(G_STATUS, AGRun, result.status); FIELD(G_RAW, AGRun, result.unsupported_instruction);
    FIELD(O_HANDLER, AGOperation, handler); FIELD(O_PC, AGOperation, next_pc);
    FIELD(O_IMM, AGOperation, immediate); FIELD(O_TAKEN, AGOperation, taken);
    FIELD(O_AUX, AGOperation, auxiliary); FIELD(O_RAW, AGOperation, raw);
    FIELD(O_SRC, AGOperation, source); FIELD(O_DST, AGOperation, destination);
    VALUE(O_MEM_OPERAND, offsetof(AGOperation, auxiliary) + AG_MEM_OPERAND_SHIFT / 8);
    VALUE(O_MEM_SECOND, offsetof(AGOperation, auxiliary) + AG_MEM_SECOND_SHIFT / 8);
    VALUE(A_EXTEND, AG_MEM_EXTEND_SHIFT);
    VALUE(A_SCALE, AG_MEM_SCALE_SHIFT); VALUE(A_OPERAND, AG_MEM_OPERAND_SHIFT);
    VALUE(O_SIZE, sizeof(AGOperation)); FIELD(C_PC, AVZNativeCPU, pc);
    FIELD(C_FLAGS, AVZNativeCPU, pstate); FIELD(C_LR, AVZNativeCPU, x[30]);
    VALUE(S_MAX, AVZ_NATIVE_STATUS_MAX_STEPS); VALUE(S_OUT, AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
    VALUE(S_UNSUPPORTED, AVZ_NATIVE_STATUS_UNSUPPORTED); VALUE(S_REVALIDATE, AVZ_TP_STATUS_REVALIDATE);
    VALUE(S_MEMORY_FAULT, AVZ_TP_STATUS_MEMORY_FAULT);
    FIELD(G_MEMORY, AGRun, memory);
    FIELD(G_CHAIN, AGRun, chain);
    FIELD(G_TARGETS, AGRun, targets); FIELD(G_TARGET_COUNT, AGRun, target_count);
    FIELD(TR_BASE, AGTargetRange, base); FIELD(TR_COUNT, AGTargetRange, count);
    FIELD(TR_ENTRIES, AGTargetRange, entries); VALUE(TR_SIZE, sizeof(AGTargetRange));
    FIELD(CH_EVENTS, AGChainControl, events); FIELD(CH_REMAINING, AGChainControl, remaining);
    FIELD(CH_ENTRIES, AGChainControl, entries); FIELD(CH_POLLS, AGChainControl, polls);
    FIELD(CH_SERVICE, AGChainControl, service);
    FIELD(BC_PROOFS, AGBoundedControl, proofs); FIELD(BC_COUNT, AGBoundedControl, count);
    FIELD(BC_LAST, AGBoundedControl, last_member); FIELD(BC_PREVIOUS, AGBoundedControl, previous_member);
    FIELD(BC_START, AGBoundedControl, member_start); FIELD(BC_STOP, AGBoundedControl, stop);
    FIELD(BC_TERMINAL, AGBoundedControl, terminal);
    FIELD(BP_SERIAL, AGBoundedProof, serial); FIELD(BP_SERIAL_VALUE, AGBoundedProof, expected_serial);
    FIELD(BP_LOCAL, AGBoundedProof, local_generation);
    FIELD(BP_LOCAL_VALUE, AGBoundedProof, expected_local_generation);
    FIELD(BP_SHARED, AGBoundedProof, shared_generation);
    FIELD(BP_SHARED_VALUE, AGBoundedProof, expected_shared_generation);
    VALUE(BP_SIZE, sizeof(AGBoundedProof));
    VALUE(BC_EVENT, AG_BOUNDED_EVENT);
    VALUE(S_YIELD, AVZ_NATIVE_STATUS_YIELDED);
    FIELD(M_PATH, AGMemory, path); FIELD(M_SHARED, AGMemory, shared);
    FIELD(M_READ, AGMemory, read_hot); FIELD(M_WRITE, AGMemory, write_hot);
    FIELD(M_DIRTY, AGMemory, dirty_hot); FIELD(M_BASE, AGMemory, ram_base);
    FIELD(M_SIZE, AGMemory, ram_size); FIELD(M_GENERATION, AGMemory, generation);
    FIELD(M_LOW, AGMemory, low_tag); FIELD(M_HIGH, AGMemory, high_tag);
    FIELD(M_OBSERVED, AGMemory, observed_translation); FIELD(M_ELIGIBLE, AGMemory, eligible);
    FIELD(M_TRANSLATION, AGMemory, translation_epoch); FIELD(M_CODE, AGMemory, code_epoch);
    FIELD(T_VALID, AVZNativeFastTLBEntry, valid); FIELD(T_GENERATION, AVZNativeFastTLBEntry, generation);
    FIELD(T_SPAN, AVZNativeFastTLBEntry, contiguous_span); FIELD(T_VIRTUAL, AVZNativeFastTLBEntry, virtual_page);
    FIELD(T_PHYSICAL, AVZNativeFastTLBEntry, physical_page); FIELD(T_HOST, AVZNativeFastTLBEntry, host_page);
    FIELD(T_CONTEXT, AVZNativeFastTLBEntry, context_tag); VALUE(T_SIZE, sizeof(AVZNativeFastTLBEntry));
    FIELD(R_TRANSLATION, AVZGuestMemory, translation_epoch); FIELD(R_CODE, AVZGuestMemory, code_mutation_epoch);
    FIELD(R_FLAGS, AVZGuestMemory, page_observation_flags); FIELD(R_PAGES, AVZGuestMemory, page_count);
    FIELD(R_BITS, AVZGuestMemory, code_page_bits); FIELD(R_EPOCHS, AVZGuestMemory, page_epochs);
    FIELD(R_EPOCH, AVZGuestMemory, current_epoch);
    FIELD(D_PAGE, AVZNativeDirtyHotEntry, page); FIELD(D_EPOCH, AVZNativeDirtyHotEntry, epoch);
    FIELD(D_VALID, AVZNativeDirtyHotEntry, valid); VALUE(D_SIZE, sizeof(AVZNativeDirtyHotEntry));
    FIELD(C_EX_ADDRESS, AVZNativeCPU, exclusive_address); FIELD(C_EX_GENERATION, AVZNativeCPU, exclusive_generation);
    FIELD(C_EX_SIZE, AVZNativeCPU, exclusive_size); FIELD(C_EX_VALID, AVZNativeCPU, exclusive_valid);
    VALUE(PAGE_SHIFT, AVZ_FAST_PAGE_SHIFT); VALUE(PAGE_SIZE, AVZ_FAST_PAGE_SIZE);
    VALUE(HOT_MASK, AVZ_FAST_DATA_HOT_COUNT - 1); VALUE(DIRTY_MASK, AVZ_FAST_DIRTY_HOT_COUNT - 1);
    VALUE(HOST_OBSERVER, AVZ_GUEST_PAGE_OBSERVATION_HOST);
    return 0;
}
