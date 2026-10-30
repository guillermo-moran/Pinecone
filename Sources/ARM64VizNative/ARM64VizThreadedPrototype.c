#include "ARM64VizThreadedPrototype.h"

#ifndef AVZ_THREADED_PROTOTYPE_ENABLE
#define AVZ_THREADED_PROTOTYPE_ENABLE 0
#endif

#if AVZ_THREADED_PROTOTYPE_ENABLE
#ifndef AVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL
#if defined(__clang__) && defined(__has_attribute)
#define AVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL __has_attribute(musttail)
#else
#define AVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL 0
#endif
#endif
#if !AVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL
#error "threaded prototype requires compiler-enforced musttail; no fallback"
#endif

#include <stdlib.h>
#include <string.h>
#include "ARM64VizGuestMemoryInternal.h"

typedef struct TPOperation TPOperation;
typedef struct {
    AVZNativeCPU *cpu;
    uint64_t remaining;
    AVZNativeBlockResult result;
    AVZNativeMemoryFastPath *memory;
    AVZThreadedPrototype *program;
    const uint64_t *code_token, *shared_code_token;
    uint64_t code_epoch, shared_code_epoch;
    const _Atomic uint64_t *translation_token, *memory_code_token;
    uint64_t translation_epoch, memory_code_epoch;
} TPExecution;
typedef void (*TPHandler)(TPExecution *, const TPOperation *);

struct TPOperation {
    TPHandler handler;
    const TPOperation *next;
    const TPOperation *taken;
    uint64_t next_pc;
    uint64_t target_pc;
    uint64_t immediate;
    uint64_t mask;
    uint32_t raw;
    uint16_t source;
    uint16_t destination;
    uint16_t conditions;
    uint16_t source2;
    uint8_t rotate;
    uint8_t width;
    uint64_t sign_fill;
};

struct AVZThreadedPrototype {
    uint64_t base_pc;
    size_t count;
    uint8_t uses_memory;
    /* Cache and execution are vCPU-confined. Callbacks may drop the owner,
     * but only the last active run may reclaim the immutable operations. */
    uint8_t retired;
    size_t active_runs;
    TPOperation operations[];
};

static __attribute__((always_inline)) inline int tp_is_current(const TPExecution *e)
{
    return !e->program->retired &&
        (!e->code_token || *e->code_token == e->code_epoch) &&
        (!e->shared_code_token || __atomic_load_n(e->shared_code_token,
            __ATOMIC_ACQUIRE) == e->shared_code_epoch) &&
        (!e->translation_token || atomic_load_explicit(e->translation_token,
            memory_order_acquire) == e->translation_epoch) &&
        (!e->memory_code_token || atomic_load_explicit(e->memory_code_token,
            memory_order_acquire) == e->memory_code_epoch);
}

/* Register offsets are specialized at preparation, including SP versus XZR.
 * memcpy avoids aliasing and subobject pointer arithmetic assumptions. */
static inline uint64_t tp_read(const AVZNativeCPU *cpu, uint16_t offset)
{
    uint64_t value = 0;
    if (offset != UINT16_MAX)
        memcpy(&value, (const unsigned char *)cpu + offset, sizeof(value));
    return value;
}

static inline void tp_write(AVZNativeCPU *cpu, uint16_t offset, uint64_t value)
{
    if (offset != UINT16_MAX)
        memcpy((unsigned char *)cpu + offset, &value, sizeof(value));
}

#define TP_HANDLER(name) \
    static __attribute__((noinline)) void name(TPExecution *execution, const TPOperation *op)

/* Each handler commits one complete instruction before dispatch. There is no
 * central switch or shared dispatch loop. musttail enforces identical ABI and
 * bounded stack even at -O0 / -fno-optimize-sibling-calls. */
#define TP_NEXT(next_operation) do { \
    const TPOperation *next = (next_operation); \
    execution->result.steps++; \
    --execution->remaining; \
    if (!tp_is_current(execution)) { \
        execution->result.status = AVZ_TP_STATUS_REVALIDATE; \
        return; \
    } \
    if (execution->remaining == 0) { \
        execution->result.status = AVZ_NATIVE_STATUS_MAX_STEPS; \
        return; \
    } \
    __attribute__((musttail)) return next->handler(execution, next); \
} while (0)

TP_HANDLER(tp_outside)
{
    (void)op;
    execution->result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
}

TP_HANDLER(tp_unsupported)
{
    execution->result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
    execution->result.unsupported_instruction = op->raw;
}

TP_HANDLER(tp_nop)
{
    execution->cpu->pc = op->next_pc;
    TP_NEXT(op->next);
}

#define TP_ALU(name, type, bits, subtract, flags) \
    TP_HANDLER(name) { \
        AVZNativeCPU *cpu = execution->cpu; \
        uint64_t a = (type)tp_read(cpu, op->source); \
        uint64_t b = op->immediate; \
        uint64_t value = (type)((subtract) ? a - b : a + b); \
        if (flags) { \
            uint64_t n = value >> ((bits) - 1); \
            uint64_t z = value == 0; \
            uint64_t c = (subtract) ? a >= b : value < a; \
            uint64_t v = (((subtract) ? (a ^ b) : ~(a ^ b)) & \
                           (a ^ value)) >> ((bits) - 1); \
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | \
                (n << 31) | (z << 30) | (c << 29) | ((v & 1) << 28); \
        } \
        tp_write(cpu, op->destination, value); \
        cpu->pc = op->next_pc; \
        TP_NEXT(op->next); \
    }

TP_ALU(tp_add32, uint32_t, 32, 0, 0)
TP_ALU(tp_sub32, uint32_t, 32, 1, 0)
TP_ALU(tp_adds32, uint32_t, 32, 0, 1)
TP_ALU(tp_subs32, uint32_t, 32, 1, 1)
TP_ALU(tp_add64, uint64_t, 64, 0, 0)
TP_ALU(tp_sub64, uint64_t, 64, 1, 0)
TP_ALU(tp_adds64, uint64_t, 64, 0, 1)
TP_ALU(tp_subs64, uint64_t, 64, 1, 1)

/* Every supported shift becomes a rotation, a retained-bit mask and a sign-fill
 * mask at preparation. No runtime opcode/shift-kind switch is necessary. */
static inline uint64_t tp_shifted(const AVZNativeCPU *cpu, const TPOperation *op,
                                unsigned bits)
{
    uint64_t value = tp_read(cpu, op->source2);
    if (bits == 32) value = (uint32_t)value;
    uint64_t sign = UINT64_C(0) - (value >> (bits - 1));
    return (((value >> op->rotate) |
        (value << ((bits - op->rotate) & (bits - 1)))) & op->mask) |
        (sign & op->sign_fill);
}

static inline uint64_t tp_extended(const AVZNativeCPU *cpu, const TPOperation *op)
{
    uint64_t value = tp_read(cpu, op->source2) & op->mask;
    return ((value ^ op->immediate) - op->immediate) << op->rotate;
}

#define TP_REGISTER_ALU(name, type, bits, subtract, flags, rhs, carry_in) \
    TP_HANDLER(name) { \
        AVZNativeCPU *cpu = execution->cpu; \
        uint64_t a = (type)tp_read(cpu, op->source); \
        uint64_t b = (type)(rhs); \
        if (subtract) b = (type)~b; \
        uint64_t carry = (carry_in); \
        uint64_t partial = (type)(a + b); \
        uint64_t value = (type)(partial + carry); \
        if (flags) { \
            uint64_t c = partial < a || value < partial; \
            uint64_t v = (~(a ^ b) & (a ^ value)) >> ((bits) - 1); \
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | \
                ((value >> ((bits) - 1)) << 31) | ((uint64_t)(value == 0) << 30) | \
                (c << 29) | ((v & 1) << 28); \
        } \
        tp_write(cpu, op->destination, value); \
        cpu->pc = op->next_pc; \
        TP_NEXT(op->next); \
    }

#define TP_REGISTER_SET(prefix, type, bits, rhs, add_carry, sub_carry) \
    TP_REGISTER_ALU(prefix##_add, type, bits, 0, 0, rhs, add_carry) \
    TP_REGISTER_ALU(prefix##_sub, type, bits, 1, 0, rhs, sub_carry) \
    TP_REGISTER_ALU(prefix##_adds, type, bits, 0, 1, rhs, add_carry) \
    TP_REGISTER_ALU(prefix##_subs, type, bits, 1, 1, rhs, sub_carry)

TP_REGISTER_SET(tp_reg32, uint32_t, 32, tp_shifted(cpu, op, 32), 0, 1)
TP_REGISTER_SET(tp_reg64, uint64_t, 64, tp_shifted(cpu, op, 64), 0, 1)
TP_REGISTER_SET(tp_ext32, uint32_t, 32, tp_extended(cpu, op), 0, 1)
TP_REGISTER_SET(tp_ext64, uint64_t, 64, tp_extended(cpu, op), 0, 1)
TP_REGISTER_SET(tp_adc32, uint32_t, 32, tp_read(cpu, op->source2),
    (cpu->pstate >> 29) & 1, (cpu->pstate >> 29) & 1)
TP_REGISTER_SET(tp_adc64, uint64_t, 64, tp_read(cpu, op->source2),
    (cpu->pstate >> 29) & 1, (cpu->pstate >> 29) & 1)

#define TP_LOGICAL(name, type, bits, operation, flags) \
    TP_HANDLER(name) { \
        AVZNativeCPU *cpu = execution->cpu; \
        uint64_t a = (type)tp_read(cpu, op->source); \
        uint64_t b = (type)(tp_shifted(cpu, op, bits) ^ op->immediate); \
        uint64_t value = a operation b; \
        if (flags) { \
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | \
                ((value >> ((bits) - 1)) << 31) | ((uint64_t)(value == 0) << 30); \
        } \
        tp_write(cpu, op->destination, value); \
        cpu->pc = op->next_pc; \
        TP_NEXT(op->next); \
    }
TP_LOGICAL(tp_and32, uint32_t, 32, &, 0)
TP_LOGICAL(tp_orr32, uint32_t, 32, |, 0)
TP_LOGICAL(tp_eor32, uint32_t, 32, ^, 0)
TP_LOGICAL(tp_ands32, uint32_t, 32, &, 1)
TP_LOGICAL(tp_and64, uint64_t, 64, &, 0)
TP_LOGICAL(tp_orr64, uint64_t, 64, |, 0)
TP_LOGICAL(tp_eor64, uint64_t, 64, ^, 0)
TP_LOGICAL(tp_ands64, uint64_t, 64, &, 1)

/* Only an existing hot-RAM proof permits continuation. The complete helper is
 * still authoritative on misses/observers/MMIO/faults, and always terminates
 * this invocation. A hot code store may retire the pinned program; TP_NEXT
 * checks retirement and local/shared epochs before executing its successor. */
#define TP_MEMORY(name, load) \
    TP_HANDLER(name) { \
        if (!execution->memory) { \
            execution->result.status = AVZ_NATIVE_STATUS_UNSUPPORTED; \
            execution->result.unsupported_instruction = op->raw; \
            return; \
        } \
        AVZNativeCPU *cpu = execution->cpu; \
        uint64_t address = tp_read(cpu, op->source) + op->immediate; \
        uint16_t destination = op->destination; \
        uint64_t next_pc = op->next_pc; \
        uint8_t width = op->width; \
        uint64_t value = (load) ? 0 : tp_read(cpu, destination) & op->mask; \
        int hot = (load) ? avz_native_fast_memory_try_read_hot(execution->memory, address, width, &value) \
                        : avz_native_fast_memory_try_write_hot(execution->memory, address, width, value); \
        int ok = hot || ((load) ? avz_native_fast_memory_read(execution->memory, address, width, &value) \
                        : avz_native_fast_memory_write(execution->memory, address, width, value)); \
        if (!ok) { \
            execution->result.status = AVZ_TP_STATUS_MEMORY_FAULT; \
            return; \
        } \
        if (load) tp_write(cpu, destination, value); \
        else { \
            cpu->exclusive_address = 0; \
            cpu->exclusive_generation = 0; \
            cpu->exclusive_size = 0; \
            cpu->exclusive_valid = 0; \
        } \
        cpu->pc = next_pc; \
        if (hot) { TP_NEXT(op->next); } \
        execution->result.steps++; \
        execution->result.status = AVZ_TP_STATUS_REVALIDATE; \
    }
TP_MEMORY(tp_load, 1)
TP_MEMORY(tp_store, 0)

TP_HANDLER(tp_move)
{
    tp_write(execution->cpu, op->destination, op->immediate);
    execution->cpu->pc = op->next_pc;
    TP_NEXT(op->next);
}

TP_HANDLER(tp_movk)
{
    tp_write(execution->cpu, op->destination,
        (tp_read(execution->cpu, op->destination) & op->mask) | op->immediate);
    execution->cpu->pc = op->next_pc;
    TP_NEXT(op->next);
}

TP_HANDLER(tp_branch)
{
    execution->cpu->pc = op->target_pc;
    TP_NEXT(op->taken);
}

TP_HANDLER(tp_link)
{
    execution->cpu->x[30] = op->next_pc;
    execution->cpu->pc = op->target_pc;
    TP_NEXT(op->taken);
}

TP_HANDLER(tp_bcond)
{
    unsigned nzcv = (unsigned)((execution->cpu->pstate >> 28) & 15);
    int taken = (op->conditions >> nzcv) & 1;
    execution->cpu->pc = taken ? op->target_pc : op->next_pc;
    TP_NEXT(taken ? op->taken : op->next);
}

#define TP_TEST_BRANCH(name, nonzero) \
    TP_HANDLER(name) { \
        uint64_t value = tp_read(execution->cpu, op->source) & op->mask; \
        int taken = (value != 0) == (nonzero); \
        execution->cpu->pc = taken ? op->target_pc : op->next_pc; \
        TP_NEXT(taken ? op->taken : op->next); \
    }
TP_TEST_BRANCH(tp_zero, 0)
TP_TEST_BRANCH(tp_nonzero, 1)

static uint16_t tp_register(unsigned reg, int sp)
{
    _Static_assert(sizeof(AVZNativeCPU) < UINT16_MAX, "register offset fits");
    if (reg == 31) return sp ? (uint16_t)offsetof(AVZNativeCPU, sp) : UINT16_MAX;
    return (uint16_t)(offsetof(AVZNativeCPU, x) + reg * sizeof(uint64_t));
}

static uint16_t tp_conditions(unsigned condition)
{
    uint16_t table = 0;
    for (unsigned flags = 0; flags < 16; flags++) {
        int n = (flags >> 3) & 1, z = (flags >> 2) & 1;
        int c = (flags >> 1) & 1, v = flags & 1;
        const int matches[] = {z, c, n, v, c && !z, n == v, !z && n == v, 1};
        int match = matches[condition >> 1];
        if ((condition & 1) && condition != 15) match = !match;
        table |= (uint16_t)(match << flags);
    }
    return table;
}

static const TPOperation *tp_lookup(const AVZThreadedPrototype *program, uint64_t pc)
{
    uint64_t delta = pc - program->base_pc;
    if (pc < program->base_pc || (delta & 3) || delta / 4 >= program->count)
        return &program->operations[program->count];
    return &program->operations[delta / 4];
}

int avz_tp_available(void) { return 1; }

int avz_tp_supports_instruction(const AVZNativeInstruction *instruction)
{
    if (!instruction) return 0;
    switch (instruction->kind) {
    case AVZ_NATIVE_OP_NOP:
        return instruction->raw == UINT32_C(0xd503201f);
    case AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE:
        return !(instruction->raw & UINT32_C(0x00800000));
    case AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER:
    case AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER:
        return (instruction->bits == 32 || instruction->bits == 64) &&
            instruction->shift_amount < instruction->bits &&
            instruction->shift_type < (instruction->kind == AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER ? 3 : 4);
    case AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER:
        return !(instruction->raw & UINT32_C(0x00c00000)) &&
            instruction->shift_amount <= 4 && instruction->condition < 8 &&
            (instruction->bits == 64 || (instruction->bits == 32 &&
                (instruction->condition & 3) != 3));
    case AVZ_NATIVE_OP_ADD_SUB_CARRY:
        return instruction->bits == 32 || instruction->bits == 64;
    case AVZ_NATIVE_OP_MOVE_WIDE:
    case AVZ_NATIVE_OP_ADR:
    case AVZ_NATIVE_OP_BRANCH:
    case AVZ_NATIVE_OP_BCOND:
    case AVZ_NATIVE_OP_CBZ:
    case AVZ_NATIVE_OP_TBZ:
        return 1;
    default:
        return 0;
    }
}

int avz_tp_supports_instruction_with_memory(const AVZNativeInstruction *instruction)
{
    if (avz_tp_supports_instruction(instruction)) return 1;
    return instruction && instruction->kind == AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE &&
        instruction->flags <= 1 && (instruction->width == 1 || instruction->width == 2 ||
        instruction->width == 4 || instruction->width == 8);
}

static void tp_prepare_shift(TPOperation *op, const AVZNativeInstruction *decoded)
{
    unsigned bits = decoded->bits, shift = decoded->shift_amount;
    uint64_t mask = bits == 64 ? UINT64_MAX : UINT32_MAX;
    op->rotate = (uint8_t)shift;
    op->mask = mask;
    if (decoded->shift_type == 0) {
        op->rotate = (uint8_t)((bits - shift) & (bits - 1));
        op->mask = (mask << shift) & mask;
    } else if (decoded->shift_type != 3) {
        op->mask = mask >> shift;
        if (decoded->shift_type == 2) op->sign_fill = mask ^ op->mask;
    }
}

AVZThreadedPrototype *avz_tp_create(const uint32_t *words, size_t count, uint64_t base_pc)
{
    if (!words || !count || count > AVZ_TP_MAX_INSTRUCTIONS || (base_pc & 3) ||
        count - 1 > (UINT64_MAX - base_pc) / 4) return NULL;
    AVZThreadedPrototype *program = calloc(1, sizeof(*program) +
        (count + 1) * sizeof(TPOperation));
    if (!program) return NULL;
    program->base_pc = base_pc;
    program->count = count;
    program->operations[count].handler = tp_outside;
    for (size_t i = 0; i < count; i++) {
        TPOperation *op = &program->operations[i];
        AVZNativeInstruction decoded;
        uint64_t pc = base_pc + i * 4;
        op->handler = tp_unsupported;
        op->raw = words[i];
        op->next = &program->operations[i + 1];
        op->next_pc = pc + 4;
        if (!avz_native_decode_instruction(words[i], &decoded) ||
            !avz_tp_supports_instruction_with_memory(&decoded)) continue;
        op->immediate = (uint64_t)decoded.immediate;
        op->target_pc = pc + op->immediate;
        op->taken = tp_lookup(program, op->target_pc);
        op->destination = tp_register(decoded.rd, 0);
        op->source = tp_register(decoded.rn, 0);
        op->source2 = tp_register(decoded.rm, 0);
        switch (decoded.kind) {
        case AVZ_NATIVE_OP_NOP:
            /* Do not claim other hints, waits or synchronization instructions. */
            if (words[i] == UINT32_C(0xd503201f)) op->handler = tp_nop;
            break;
        case AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE: {
            /* The reference decoder also accepts reserved bit 23; we do not. */
            if (words[i] & UINT32_C(0x00800000)) break;
            static const TPHandler handlers[] = {
                tp_add32, tp_sub32, tp_adds32, tp_subs32,
                tp_add64, tp_sub64, tp_adds64, tp_subs64
            };
            op->handler = handlers[(decoded.bits == 64 ? 4 : 0) + decoded.flags];
            op->source = tp_register(decoded.rn, 1);
            op->destination = tp_register(decoded.rd, !(decoded.flags & 2));
            break;
        }
        case AVZ_NATIVE_OP_MOVE_WIDE: {
            uint64_t mask = decoded.bits == 64 ? UINT64_MAX : UINT32_MAX;
            op->mask = mask & ~(UINT64_C(0xffff) << decoded.shift_amount);
            if (decoded.flags == 0) op->immediate = ~op->immediate;
            op->immediate &= mask;
            op->handler = decoded.flags == 3 ? tp_movk : tp_move;
            break;
        }
        case AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER:
        case AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER:
        case AVZ_NATIVE_OP_ADD_SUB_CARRY: {
            static const TPHandler handlers[3][8] = {
                {tp_reg32_add, tp_reg32_sub, tp_reg32_adds, tp_reg32_subs,
                 tp_reg64_add, tp_reg64_sub, tp_reg64_adds, tp_reg64_subs},
                {tp_ext32_add, tp_ext32_sub, tp_ext32_adds, tp_ext32_subs,
                 tp_ext64_add, tp_ext64_sub, tp_ext64_adds, tp_ext64_subs},
                {tp_adc32_add, tp_adc32_sub, tp_adc32_adds, tp_adc32_subs,
                 tp_adc64_add, tp_adc64_sub, tp_adc64_adds, tp_adc64_subs}
            };
            unsigned family = decoded.kind == AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER ? 0 :
                decoded.kind == AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER ? 1 : 2;
            op->handler = handlers[family][(decoded.bits == 64 ? 4 : 0) + decoded.flags];
            if (family == 0) tp_prepare_shift(op, &decoded);
            if (family == 1) {
                unsigned size = 8u << (decoded.condition & 3);
                op->mask = UINT64_MAX >> (64 - size);
                op->immediate = (decoded.condition & 4) ? UINT64_C(1) << (size - 1) : 0;
                op->rotate = decoded.shift_amount;
                op->source = tp_register(decoded.rn, 1);
                op->destination = tp_register(decoded.rd, !(decoded.flags & 2));
            }
            break;
        }
        case AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER: {
            static const TPHandler handlers[] = {
                tp_and32, tp_orr32, tp_eor32, tp_ands32,
                tp_and64, tp_orr64, tp_eor64, tp_ands64
            };
            tp_prepare_shift(op, &decoded);
            op->immediate = (decoded.flags & 4) ? UINT64_MAX : 0;
            op->handler = handlers[(decoded.bits == 64 ? 4 : 0) + (decoded.flags & 3)];
            break;
        }
        case AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE:
            op->source = tp_register(decoded.rn, 1);
            op->destination = tp_register(decoded.rt, 0);
            op->width = decoded.width;
            op->mask = UINT64_MAX >> (64u - decoded.width * 8u);
            program->uses_memory = 1;
            op->handler = (decoded.flags & 1) ? tp_load : tp_store;
            break;
        case AVZ_NATIVE_OP_ADR:
            op->immediate += (decoded.flags & 1) ? pc & ~UINT64_C(4095) : pc;
            op->handler = tp_move;
            break;
        case AVZ_NATIVE_OP_BRANCH:
            op->handler = (decoded.flags & 1) ? tp_link : tp_branch;
            break;
        case AVZ_NATIVE_OP_BCOND:
            op->conditions = tp_conditions(decoded.condition);
            op->handler = tp_bcond;
            break;
        case AVZ_NATIVE_OP_CBZ:
        case AVZ_NATIVE_OP_TBZ:
            op->source = tp_register(decoded.rt, 0);
            op->mask = decoded.kind == AVZ_NATIVE_OP_TBZ
                ? UINT64_C(1) << decoded.shift_amount
                : decoded.bits == 64 ? UINT64_MAX : UINT32_MAX;
            op->handler = (decoded.flags & 1) ? tp_nonzero : tp_zero;
            break;
        default:
            break;
        }
    }
    return program;
}

void avz_tp_destroy(AVZThreadedPrototype *program)
{
    if (!program) return;
    program->retired = 1;
    if (!program->active_runs) free(program);
}

int avz_tp_program_uses_memory(const AVZThreadedPrototype *program)
{
    return program != NULL && program->uses_memory;
}

size_t avz_tp_program_bytes(const AVZThreadedPrototype *program)
{
    return program ? sizeof(*program) + (program->count + 1) * sizeof(TPOperation) : 0;
}

AVZNativeBlockResult avz_tp_run(const AVZThreadedPrototype *program,
                              uint64_t max_steps, AVZNativeCPU *cpu)
{
    return avz_tp_run_with_memory(program, max_steps, cpu, NULL);
}

AVZNativeBlockResult avz_tp_run_with_memory(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory)
{
    AVZNativeBlockCache *cache = memory ? memory->block_cache : NULL;
    return avz_tp_run_guarded(program, max_steps, cpu, memory, cache,
        avz_native_block_cache_code_mutation_epoch(cache),
        avz_native_block_cache_shared_code_mutation_epoch(cache));
}

AVZNativeBlockResult avz_tp_run_guarded(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory,
    AVZNativeBlockCache *cache, uint64_t code_epoch, uint64_t shared_code_epoch)
{
    TPExecution execution = {.cpu = cpu, .remaining = max_steps, .memory = memory};
    if (!program || !cpu) execution.result.status = AVZ_TP_STATUS_INVALID_ARGUMENT;
    else if (!max_steps) execution.result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    else if (cpu->halted) execution.result.status = AVZ_NATIVE_STATUS_HALTED;
    else {
        AVZThreadedPrototype *pinned = (AVZThreadedPrototype *)program;
        pinned->active_runs++;
        execution.program = pinned;
        execution.code_token = avz_native_block_cache_code_mutation_epoch_token(cache);
        execution.shared_code_token = avz_native_block_cache_shared_code_mutation_epoch_token(cache);
        execution.code_epoch = code_epoch;
        execution.shared_code_epoch = shared_code_epoch;
        if (memory && memory->guest_memory) {
            execution.translation_token = &memory->guest_memory->translation_epoch;
            execution.translation_epoch = memory->observed_shared_translation_epoch;
            execution.memory_code_token = &memory->guest_memory->code_mutation_epoch;
            execution.memory_code_epoch = atomic_load_explicit(
                execution.memory_code_token, memory_order_acquire);
        }
        if (!tp_is_current(&execution)) {
            execution.result.status = AVZ_TP_STATUS_REVALIDATE;
        } else {
            const TPOperation *op = tp_lookup(program, cpu->pc);
            op->handler(&execution, op);
        }
        if (--pinned->active_runs == 0 && pinned->retired) free(pinned);
    }
    execution.result.generic_dispatches = execution.result.steps;
    return execution.result;
}

#else

int avz_tp_available(void) { return 0; }
int avz_tp_program_uses_memory(const AVZThreadedPrototype *program)
{
    (void)program;
    return 0;
}
int avz_tp_supports_instruction(const AVZNativeInstruction *instruction)
{
    (void)instruction;
    return 0;
}
int avz_tp_supports_instruction_with_memory(const AVZNativeInstruction *instruction)
{
    (void)instruction;
    return 0;
}
AVZThreadedPrototype *avz_tp_create(const uint32_t *words, size_t count, uint64_t base_pc)
{
    (void)words; (void)count; (void)base_pc;
    return NULL;
}
void avz_tp_destroy(AVZThreadedPrototype *program) { (void)program; }
size_t avz_tp_program_bytes(const AVZThreadedPrototype *program)
{
    (void)program;
    return 0;
}
AVZNativeBlockResult avz_tp_run(const AVZThreadedPrototype *program,
                              uint64_t max_steps, AVZNativeCPU *cpu)
{
    (void)program; (void)max_steps; (void)cpu;
    return (AVZNativeBlockResult){.status = AVZ_TP_STATUS_DISABLED};
}
AVZNativeBlockResult avz_tp_run_with_memory(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory)
{
    (void)memory;
    return avz_tp_run(program, max_steps, cpu);
}

AVZNativeBlockResult avz_tp_run_guarded(const AVZThreadedPrototype *program,
    uint64_t max_steps, AVZNativeCPU *cpu, AVZNativeMemoryFastPath *memory,
    AVZNativeBlockCache *cache, uint64_t code_epoch, uint64_t shared_code_epoch)
{
    (void)cache; (void)code_epoch; (void)shared_code_epoch;
    return avz_tp_run_with_memory(program, max_steps, cpu, memory);
}

#endif
