#define G_CPU 0
#ifndef __ASSEMBLER__
_Static_assert(G_CPU == offsetof(AGRun, cpu), "stale assembly offset");
#endif
#define G_OP 8
#ifndef __ASSEMBLER__
_Static_assert(G_OP == offsetof(AGRun, operation), "stale assembly offset");
#endif
#define G_BUDGET 16
#ifndef __ASSEMBLER__
_Static_assert(G_BUDGET == offsetof(AGRun, budget), "stale assembly offset");
#endif
#define G_LOCAL 24
#ifndef __ASSEMBLER__
_Static_assert(G_LOCAL == offsetof(AGRun, guards.local), "stale assembly offset");
#endif
#define G_SHARED0 32
#ifndef __ASSEMBLER__
_Static_assert(G_SHARED0 == offsetof(AGRun, guards.shared[0]), "stale assembly offset");
#endif
#define G_SHARED1 40
#ifndef __ASSEMBLER__
_Static_assert(G_SHARED1 == offsetof(AGRun, guards.shared[1]), "stale assembly offset");
#endif
#define G_SHARED2 48
#ifndef __ASSEMBLER__
_Static_assert(G_SHARED2 == offsetof(AGRun, guards.shared[2]), "stale assembly offset");
#endif
#define G_EPOCH0 56
#ifndef __ASSEMBLER__
_Static_assert(G_EPOCH0 == offsetof(AGRun, guards.expected[0]), "stale assembly offset");
#endif
#define G_EPOCH1 64
#ifndef __ASSEMBLER__
_Static_assert(G_EPOCH1 == offsetof(AGRun, guards.expected[1]), "stale assembly offset");
#endif
#define G_EPOCH2 72
#ifndef __ASSEMBLER__
_Static_assert(G_EPOCH2 == offsetof(AGRun, guards.expected[2]), "stale assembly offset");
#endif
#define G_EPOCH3 80
#ifndef __ASSEMBLER__
_Static_assert(G_EPOCH3 == offsetof(AGRun, guards.expected[3]), "stale assembly offset");
#endif
#define G_STEPS 88
#ifndef __ASSEMBLER__
_Static_assert(G_STEPS == offsetof(AGRun, result.steps), "stale assembly offset");
#endif
#define G_DISPATCHES 96
#ifndef __ASSEMBLER__
_Static_assert(G_DISPATCHES == offsetof(AGRun, result.generic_dispatches), "stale assembly offset");
#endif
#define G_STATUS 128
#ifndef __ASSEMBLER__
_Static_assert(G_STATUS == offsetof(AGRun, result.status), "stale assembly offset");
#endif
#define G_RAW 132
#ifndef __ASSEMBLER__
_Static_assert(G_RAW == offsetof(AGRun, result.unsupported_instruction), "stale assembly offset");
#endif
#define O_HANDLER 0
#ifndef __ASSEMBLER__
_Static_assert(O_HANDLER == offsetof(AGOperation, handler), "stale assembly offset");
#endif
#define O_PC 8
#ifndef __ASSEMBLER__
_Static_assert(O_PC == offsetof(AGOperation, next_pc), "stale assembly offset");
#endif
#define O_IMM 16
#ifndef __ASSEMBLER__
_Static_assert(O_IMM == offsetof(AGOperation, immediate), "stale assembly offset");
#endif
#define O_TAKEN 24
#ifndef __ASSEMBLER__
_Static_assert(O_TAKEN == offsetof(AGOperation, taken), "stale assembly offset");
#endif
#define O_AUX 32
#ifndef __ASSEMBLER__
_Static_assert(O_AUX == offsetof(AGOperation, auxiliary), "stale assembly offset");
#endif
#define O_RAW 40
#ifndef __ASSEMBLER__
_Static_assert(O_RAW == offsetof(AGOperation, raw), "stale assembly offset");
#endif
#define O_SRC 44
#ifndef __ASSEMBLER__
_Static_assert(O_SRC == offsetof(AGOperation, source), "stale assembly offset");
#endif
#define O_DST 46
#ifndef __ASSEMBLER__
_Static_assert(O_DST == offsetof(AGOperation, destination), "stale assembly offset");
#endif
#define O_MEM_OPERAND 34
#ifndef __ASSEMBLER__
_Static_assert(O_MEM_OPERAND == (offsetof(AGOperation, auxiliary) + AG_MEM_OPERAND_SHIFT / 8), "stale assembly constant");
#endif
#define O_MEM_SECOND 36
#ifndef __ASSEMBLER__
_Static_assert(O_MEM_SECOND == (offsetof(AGOperation, auxiliary) + AG_MEM_SECOND_SHIFT / 8), "stale assembly constant");
#endif
#define A_EXTEND 32
#ifndef __ASSEMBLER__
_Static_assert(A_EXTEND == (AG_MEM_EXTEND_SHIFT), "stale assembly constant");
#endif
#define A_SCALE 40
#ifndef __ASSEMBLER__
_Static_assert(A_SCALE == (AG_MEM_SCALE_SHIFT), "stale assembly constant");
#endif
#define A_OPERAND 16
#ifndef __ASSEMBLER__
_Static_assert(A_OPERAND == (AG_MEM_OPERAND_SHIFT), "stale assembly constant");
#endif
#define O_SIZE 48
#ifndef __ASSEMBLER__
_Static_assert(O_SIZE == (sizeof(AGOperation)), "stale assembly constant");
#endif
#define C_PC 768
#ifndef __ASSEMBLER__
_Static_assert(C_PC == offsetof(AVZNativeCPU, pc), "stale assembly offset");
#endif
#define C_FLAGS 776
#ifndef __ASSEMBLER__
_Static_assert(C_FLAGS == offsetof(AVZNativeCPU, pstate), "stale assembly offset");
#endif
#define C_LR 240
#ifndef __ASSEMBLER__
_Static_assert(C_LR == offsetof(AVZNativeCPU, x[30]), "stale assembly offset");
#endif
#define S_MAX 3
#ifndef __ASSEMBLER__
_Static_assert(S_MAX == (AVZ_NATIVE_STATUS_MAX_STEPS), "stale assembly constant");
#endif
#define S_OUT 0
#ifndef __ASSEMBLER__
_Static_assert(S_OUT == (AVZ_NATIVE_STATUS_OUTSIDE_BLOCK), "stale assembly constant");
#endif
#define S_UNSUPPORTED 2
#ifndef __ASSEMBLER__
_Static_assert(S_UNSUPPORTED == (AVZ_NATIVE_STATUS_UNSUPPORTED), "stale assembly constant");
#endif
#define S_REVALIDATE 258
#ifndef __ASSEMBLER__
_Static_assert(S_REVALIDATE == (AVZ_TP_STATUS_REVALIDATE), "stale assembly constant");
#endif
#define S_MEMORY_FAULT 259
#ifndef __ASSEMBLER__
_Static_assert(S_MEMORY_FAULT == (AVZ_TP_STATUS_MEMORY_FAULT), "stale assembly constant");
#endif
#define G_MEMORY 136
#ifndef __ASSEMBLER__
_Static_assert(G_MEMORY == offsetof(AGRun, memory), "stale assembly offset");
#endif
#define G_CHAIN 248
#ifndef __ASSEMBLER__
_Static_assert(G_CHAIN == offsetof(AGRun, chain), "stale assembly offset");
#endif
#define G_TARGETS 256
#ifndef __ASSEMBLER__
_Static_assert(G_TARGETS == offsetof(AGRun, targets), "stale assembly offset");
#endif
#define G_TARGET_COUNT 264
#ifndef __ASSEMBLER__
_Static_assert(G_TARGET_COUNT == offsetof(AGRun, target_count), "stale assembly offset");
#endif
#define TR_BASE 0
#ifndef __ASSEMBLER__
_Static_assert(TR_BASE == offsetof(AGTargetRange, base), "stale assembly offset");
#endif
#define TR_COUNT 8
#ifndef __ASSEMBLER__
_Static_assert(TR_COUNT == offsetof(AGTargetRange, count), "stale assembly offset");
#endif
#define TR_ENTRIES 16
#ifndef __ASSEMBLER__
_Static_assert(TR_ENTRIES == offsetof(AGTargetRange, entries), "stale assembly offset");
#endif
#define TR_SIZE 24
#ifndef __ASSEMBLER__
_Static_assert(TR_SIZE == (sizeof(AGTargetRange)), "stale assembly constant");
#endif
#define CH_EVENTS 0
#ifndef __ASSEMBLER__
_Static_assert(CH_EVENTS == offsetof(AGChainControl, events), "stale assembly offset");
#endif
#define CH_REMAINING 8
#ifndef __ASSEMBLER__
_Static_assert(CH_REMAINING == offsetof(AGChainControl, remaining), "stale assembly offset");
#endif
#define CH_ENTRIES 16
#ifndef __ASSEMBLER__
_Static_assert(CH_ENTRIES == offsetof(AGChainControl, entries), "stale assembly offset");
#endif
#define CH_POLLS 24
#ifndef __ASSEMBLER__
_Static_assert(CH_POLLS == offsetof(AGChainControl, polls), "stale assembly offset");
#endif
#define CH_SERVICE 32
#ifndef __ASSEMBLER__
_Static_assert(CH_SERVICE == offsetof(AGChainControl, service), "stale assembly offset");
#endif
#define BC_PROOFS 40
#ifndef __ASSEMBLER__
_Static_assert(BC_PROOFS == offsetof(AGBoundedControl, proofs), "stale assembly offset");
#endif
#define BC_COUNT 48
#ifndef __ASSEMBLER__
_Static_assert(BC_COUNT == offsetof(AGBoundedControl, count), "stale assembly offset");
#endif
#define BC_LAST 56
#ifndef __ASSEMBLER__
_Static_assert(BC_LAST == offsetof(AGBoundedControl, last_member), "stale assembly offset");
#endif
#define BC_PREVIOUS 64
#ifndef __ASSEMBLER__
_Static_assert(BC_PREVIOUS == offsetof(AGBoundedControl, previous_member), "stale assembly offset");
#endif
#define BC_START 72
#ifndef __ASSEMBLER__
_Static_assert(BC_START == offsetof(AGBoundedControl, member_start), "stale assembly offset");
#endif
#define BC_STOP 80
#ifndef __ASSEMBLER__
_Static_assert(BC_STOP == offsetof(AGBoundedControl, stop), "stale assembly offset");
#endif
#define BC_TERMINAL 84
#ifndef __ASSEMBLER__
_Static_assert(BC_TERMINAL == offsetof(AGBoundedControl, terminal), "stale assembly offset");
#endif
#define BP_SERIAL 0
#ifndef __ASSEMBLER__
_Static_assert(BP_SERIAL == offsetof(AGBoundedProof, serial), "stale assembly offset");
#endif
#define BP_SERIAL_VALUE 8
#ifndef __ASSEMBLER__
_Static_assert(BP_SERIAL_VALUE == offsetof(AGBoundedProof, expected_serial), "stale assembly offset");
#endif
#define BP_LOCAL 16
#ifndef __ASSEMBLER__
_Static_assert(BP_LOCAL == offsetof(AGBoundedProof, local_generation), "stale assembly offset");
#endif
#define BP_LOCAL_VALUE 24
#ifndef __ASSEMBLER__
_Static_assert(BP_LOCAL_VALUE == offsetof(AGBoundedProof, expected_local_generation), "stale assembly offset");
#endif
#define BP_SHARED 32
#ifndef __ASSEMBLER__
_Static_assert(BP_SHARED == offsetof(AGBoundedProof, shared_generation), "stale assembly offset");
#endif
#define BP_SHARED_VALUE 40
#ifndef __ASSEMBLER__
_Static_assert(BP_SHARED_VALUE == offsetof(AGBoundedProof, expected_shared_generation), "stale assembly offset");
#endif
#define BP_SIZE 48
#ifndef __ASSEMBLER__
_Static_assert(BP_SIZE == (sizeof(AGBoundedProof)), "stale assembly constant");
#endif
#define BC_EVENT 1
#ifndef __ASSEMBLER__
_Static_assert(BC_EVENT == (AG_BOUNDED_EVENT), "stale assembly constant");
#endif
#define S_YIELD 4
#ifndef __ASSEMBLER__
_Static_assert(S_YIELD == (AVZ_NATIVE_STATUS_YIELDED), "stale assembly constant");
#endif
#define M_PATH 0
#ifndef __ASSEMBLER__
_Static_assert(M_PATH == offsetof(AGMemory, path), "stale assembly offset");
#endif
#define M_SHARED 32
#ifndef __ASSEMBLER__
_Static_assert(M_SHARED == offsetof(AGMemory, shared), "stale assembly offset");
#endif
#define M_READ 8
#ifndef __ASSEMBLER__
_Static_assert(M_READ == offsetof(AGMemory, read_hot), "stale assembly offset");
#endif
#define M_WRITE 16
#ifndef __ASSEMBLER__
_Static_assert(M_WRITE == offsetof(AGMemory, write_hot), "stale assembly offset");
#endif
#define M_DIRTY 24
#ifndef __ASSEMBLER__
_Static_assert(M_DIRTY == offsetof(AGMemory, dirty_hot), "stale assembly offset");
#endif
#define M_BASE 40
#ifndef __ASSEMBLER__
_Static_assert(M_BASE == offsetof(AGMemory, ram_base), "stale assembly offset");
#endif
#define M_SIZE 48
#ifndef __ASSEMBLER__
_Static_assert(M_SIZE == offsetof(AGMemory, ram_size), "stale assembly offset");
#endif
#define M_GENERATION 56
#ifndef __ASSEMBLER__
_Static_assert(M_GENERATION == offsetof(AGMemory, generation), "stale assembly offset");
#endif
#define M_LOW 64
#ifndef __ASSEMBLER__
_Static_assert(M_LOW == offsetof(AGMemory, low_tag), "stale assembly offset");
#endif
#define M_HIGH 72
#ifndef __ASSEMBLER__
_Static_assert(M_HIGH == offsetof(AGMemory, high_tag), "stale assembly offset");
#endif
#define M_OBSERVED 80
#ifndef __ASSEMBLER__
_Static_assert(M_OBSERVED == offsetof(AGMemory, observed_translation), "stale assembly offset");
#endif
#define M_ELIGIBLE 104
#ifndef __ASSEMBLER__
_Static_assert(M_ELIGIBLE == offsetof(AGMemory, eligible), "stale assembly offset");
#endif
#define M_TRANSLATION 88
#ifndef __ASSEMBLER__
_Static_assert(M_TRANSLATION == offsetof(AGMemory, translation_epoch), "stale assembly offset");
#endif
#define M_CODE 96
#ifndef __ASSEMBLER__
_Static_assert(M_CODE == offsetof(AGMemory, code_epoch), "stale assembly offset");
#endif
#define T_VALID 60
#ifndef __ASSEMBLER__
_Static_assert(T_VALID == offsetof(AVZNativeFastTLBEntry, valid), "stale assembly offset");
#endif
#define T_GENERATION 40
#ifndef __ASSEMBLER__
_Static_assert(T_GENERATION == offsetof(AVZNativeFastTLBEntry, generation), "stale assembly offset");
#endif
#define T_SPAN 24
#ifndef __ASSEMBLER__
_Static_assert(T_SPAN == offsetof(AVZNativeFastTLBEntry, contiguous_span), "stale assembly offset");
#endif
#define T_VIRTUAL 0
#ifndef __ASSEMBLER__
_Static_assert(T_VIRTUAL == offsetof(AVZNativeFastTLBEntry, virtual_page), "stale assembly offset");
#endif
#define T_PHYSICAL 8
#ifndef __ASSEMBLER__
_Static_assert(T_PHYSICAL == offsetof(AVZNativeFastTLBEntry, physical_page), "stale assembly offset");
#endif
#define T_HOST 16
#ifndef __ASSEMBLER__
_Static_assert(T_HOST == offsetof(AVZNativeFastTLBEntry, host_page), "stale assembly offset");
#endif
#define T_CONTEXT 32
#ifndef __ASSEMBLER__
_Static_assert(T_CONTEXT == offsetof(AVZNativeFastTLBEntry, context_tag), "stale assembly offset");
#endif
#define T_SIZE 64
#ifndef __ASSEMBLER__
_Static_assert(T_SIZE == (sizeof(AVZNativeFastTLBEntry)), "stale assembly constant");
#endif
#define R_TRANSLATION 384
#ifndef __ASSEMBLER__
_Static_assert(R_TRANSLATION == offsetof(AVZGuestMemory, translation_epoch), "stale assembly offset");
#endif
#define R_CODE 248
#ifndef __ASSEMBLER__
_Static_assert(R_CODE == offsetof(AVZGuestMemory, code_mutation_epoch), "stale assembly offset");
#endif
#define R_FLAGS 56
#ifndef __ASSEMBLER__
_Static_assert(R_FLAGS == offsetof(AVZGuestMemory, page_observation_flags), "stale assembly offset");
#endif
#define R_PAGES 96
#ifndef __ASSEMBLER__
_Static_assert(R_PAGES == offsetof(AVZGuestMemory, page_count), "stale assembly offset");
#endif
#define R_BITS 1464
#ifndef __ASSEMBLER__
_Static_assert(R_BITS == offsetof(AVZGuestMemory, code_page_bits), "stale assembly offset");
#endif
#define R_EPOCHS 16
#ifndef __ASSEMBLER__
_Static_assert(R_EPOCHS == offsetof(AVZGuestMemory, page_epochs), "stale assembly offset");
#endif
#define R_EPOCH 104
#ifndef __ASSEMBLER__
_Static_assert(R_EPOCH == offsetof(AVZGuestMemory, current_epoch), "stale assembly offset");
#endif
#define D_PAGE 0
#ifndef __ASSEMBLER__
_Static_assert(D_PAGE == offsetof(AVZNativeDirtyHotEntry, page), "stale assembly offset");
#endif
#define D_EPOCH 8
#ifndef __ASSEMBLER__
_Static_assert(D_EPOCH == offsetof(AVZNativeDirtyHotEntry, epoch), "stale assembly offset");
#endif
#define D_VALID 16
#ifndef __ASSEMBLER__
_Static_assert(D_VALID == offsetof(AVZNativeDirtyHotEntry, valid), "stale assembly offset");
#endif
#define D_SIZE 24
#ifndef __ASSEMBLER__
_Static_assert(D_SIZE == (sizeof(AVZNativeDirtyHotEntry)), "stale assembly constant");
#endif
#define C_EX_ADDRESS 800
#ifndef __ASSEMBLER__
_Static_assert(C_EX_ADDRESS == offsetof(AVZNativeCPU, exclusive_address), "stale assembly offset");
#endif
#define C_EX_GENERATION 808
#ifndef __ASSEMBLER__
_Static_assert(C_EX_GENERATION == offsetof(AVZNativeCPU, exclusive_generation), "stale assembly offset");
#endif
#define C_EX_SIZE 816
#ifndef __ASSEMBLER__
_Static_assert(C_EX_SIZE == offsetof(AVZNativeCPU, exclusive_size), "stale assembly offset");
#endif
#define C_EX_VALID 817
#ifndef __ASSEMBLER__
_Static_assert(C_EX_VALID == offsetof(AVZNativeCPU, exclusive_valid), "stale assembly offset");
#endif
#define PAGE_SHIFT 12
#ifndef __ASSEMBLER__
_Static_assert(PAGE_SHIFT == (AVZ_FAST_PAGE_SHIFT), "stale assembly constant");
#endif
#define PAGE_SIZE 4096
#ifndef __ASSEMBLER__
_Static_assert(PAGE_SIZE == (AVZ_FAST_PAGE_SIZE), "stale assembly constant");
#endif
#define HOT_MASK 1023
#ifndef __ASSEMBLER__
_Static_assert(HOT_MASK == (AVZ_FAST_DATA_HOT_COUNT - 1), "stale assembly constant");
#endif
#define DIRTY_MASK 4095
#ifndef __ASSEMBLER__
_Static_assert(DIRTY_MASK == (AVZ_FAST_DIRTY_HOT_COUNT - 1), "stale assembly constant");
#endif
#define HOST_OBSERVER 1
#ifndef __ASSEMBLER__
_Static_assert(HOST_OBSERVER == (AVZ_GUEST_PAGE_OBSERVATION_HOST), "stale assembly constant");
#endif
