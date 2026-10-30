#include "gadget_internal.h"
/* Canonical precompiled assembly executor, shared by VM and offline tests. */
#include <stdlib.h>

#if defined(AG_ENABLE) && AG_ENABLE && defined(__APPLE__) && defined(__aarch64__) && !defined(__arm64e__)
#include "offsets.h"
#define DECLARE(name) extern void ag_##name(void)
DECLARE(outside); DECLARE(unsupported); DECLARE(nop); DECLARE(move); DECLARE(movk);
DECLARE(branch); DECLARE(link); DECLARE(bcond); DECLARE(zero); DECLARE(nonzero);
DECLARE(indirect); DECLARE(indirect_link);
#define CONDITIONAL(bits) \
    DECLARE(csel##bits); DECLARE(csinc##bits); DECLARE(csinv##bits); DECLARE(csneg##bits); \
    DECLARE(ccmpreg##bits); DECLARE(ccmnreg##bits); DECLARE(ccmpimm##bits); DECLARE(ccmnimm##bits)
CONDITIONAL(32); CONDITIONAL(64);
#define ARITHMETIC(prefix) \
    DECLARE(prefix##32_add); DECLARE(prefix##32_sub); \
    DECLARE(prefix##32_adds); DECLARE(prefix##32_subs); \
    DECLARE(prefix##64_add); DECLARE(prefix##64_sub); \
    DECLARE(prefix##64_adds); DECLARE(prefix##64_subs)
ARITHMETIC(imm); ARITHMETIC(reg); ARITHMETIC(carry);
ARITHMETIC(lsl); ARITHMETIC(lsr); ARITHMETIC(asr);
#define LOGICAL(prefix, bits) \
    DECLARE(prefix##and##bits); DECLARE(prefix##orr##bits); \
    DECLARE(prefix##eor##bits); DECLARE(prefix##ands##bits)
#define LOGICAL_WIDTHS(prefix) LOGICAL(prefix, 32); LOGICAL(prefix, 64)
LOGICAL_WIDTHS(); LOGICAL_WIDTHS(inv); LOGICAL_WIDTHS(imm);
LOGICAL_WIDTHS(lsl); LOGICAL_WIDTHS(lsr); LOGICAL_WIDTHS(asr); LOGICAL_WIDTHS(ror);
LOGICAL_WIDTHS(lslinv); LOGICAL_WIDTHS(lsrinv); LOGICAL_WIDTHS(asrinv); LOGICAL_WIDTHS(rorinv);
#define MEMORY(bits) DECLARE(load##bits); DECLARE(store##bits); \
    DECLARE(regload##bits); DECLARE(regstore##bits); DECLARE(wbload##bits); DECLARE(wbstore##bits)
MEMORY(8); MEMORY(16); MEMORY(32); MEMORY(64);
#define SIGNED_MEMORY(name) DECLARE(name); DECLARE(reg##name); DECLARE(wb##name)
SIGNED_MEMORY(loads8x); SIGNED_MEMORY(loads8w);
SIGNED_MEMORY(loads16x); SIGNED_MEMORY(loads16w); SIGNED_MEMORY(loads32x);
#define PAIR(name) DECLARE(pair##name); DECLARE(wbpair##name)
PAIR(load32); PAIR(load64); PAIR(loads32x); PAIR(store32); PAIR(store64);
#define ARITHMETIC_TABLE(prefix) {ag_##prefix##32_add, ag_##prefix##32_sub, \
    ag_##prefix##32_adds, ag_##prefix##32_subs, ag_##prefix##64_add, ag_##prefix##64_sub, \
    ag_##prefix##64_adds, ag_##prefix##64_subs}
#define LOGICAL_TABLE(prefix) {ag_##prefix##and32, ag_##prefix##orr32, \
    ag_##prefix##eor32, ag_##prefix##ands32, ag_##prefix##and64, ag_##prefix##orr64, \
    ag_##prefix##eor64, ag_##prefix##ands64}

int ag_available(void) { return 1; }
static uint16_t reg_offset(unsigned reg, int sp) {
    return reg == 31 ? (sp ? (uint16_t)offsetof(AVZNativeCPU, sp) : UINT16_MAX) :
        (uint16_t)(offsetof(AVZNativeCPU, x) + reg * sizeof(uint64_t));
}
static const AGOperation *lookup(const AGProgram *p, uint64_t pc) {
    uint64_t delta = pc - p->targets.base;
    return pc < p->targets.base || (delta & 3) || delta / 4 >= p->targets.count ?
        &p->operations[p->targets.count] : &p->operations[delta / 4];
}
static uint16_t conditions(unsigned condition) {
    uint16_t table = 0;
    for (unsigned f = 0; f < 16; f++) {
        unsigned n = f >> 3, z = (f >> 2) & 1, c = (f >> 1) & 1, v = f & 1;
        unsigned values[] = {z, c, n, v, c && !z, n == v, !z && n == v, 1};
        unsigned match = values[condition >> 1];
        if ((condition & 1) && condition != 15) match = !match;
        table |= (uint16_t)(match << f);
    }
    return table;
}
AGProgram *ag_create(const uint32_t *words, size_t count, uint64_t base) {
    if (!words || !count || count > AVZ_TP_MAX_INSTRUCTIONS || (base & 3) ||
        count - 1 > (UINT64_MAX - base) / 4) return NULL;
    AGProgram *p = calloc(1, sizeof(*p) + (count + 1) * sizeof(AGOperation));
    if (!p) return NULL;
    p->targets = (AGTargetRange){base, count, p->operations};
    p->capability = 1;
    p->operations[count].handler = ag_outside;
    for (size_t i = 0; i < count; i++) {
        AGOperation *op = &p->operations[i];
        uint64_t pc = base + i * 4;
        op->handler = ag_unsupported; op->raw = words[i]; op->next_pc = pc + 4;
        AVZNativeInstruction d;
        if (!avz_native_decode_instruction(words[i], &d)) continue;
        op->source = reg_offset(d.rn, 0); op->destination = reg_offset(d.rd, 0);
        op->immediate = (uint64_t)d.immediate;
        switch (d.kind) {
        case AVZ_NATIVE_OP_LOAD_STORE_PAIR: {
            p->capability = 2;
            static const AGHandler handlers[2][5] = {
                {ag_pairstore32, ag_pairstore64, ag_pairload32, ag_pairload64, ag_pairloads32x},
                {ag_wbpairstore32, ag_wbpairstore64, ag_wbpairload32, ag_wbpairload64, ag_wbpairloads32x}};
            if ((d.raw & (1u << 26)) || (d.width != 4 && d.width != 8) ||
                (d.flags & ~11u) || ((d.flags & 2) && (!(d.flags & 1) || d.width != 4))) break;
            // Constrained-unpredictable load destinations and writeback aliases.
            if (((d.flags & 1) && d.rt == d.rd) ||
                ((d.flags & 8) && d.rn != 31 && (d.rn == d.rt || d.rn == d.rd))) break;
            unsigned index = d.flags & 2 ? 4 : ((d.flags & 1) ? 2 : 0) + (d.width == 8);
            op->handler = handlers[(d.flags >> 3) & 1][index];
            op->source = reg_offset(d.rn, 1);
            op->destination = reg_offset(d.rt, 0);
            op->auxiliary = d.width | ((uint64_t)d.flags << 8) | AG_MEM_PAIR |
                ((uint64_t)(uint16_t)d.immediate2 << AG_MEM_OPERAND_SHIFT) |
                ((uint64_t)reg_offset(d.rd, 0) << AG_MEM_SECOND_SHIFT);
            break;
        }
        case AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE:
        case AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE:
        case AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET: {
            p->capability = 2;
            static const AGHandler loads[] = {ag_load8, ag_load16, ag_load32, ag_load64};
            static const AGHandler stores[] = {ag_store8, ag_store16, ag_store32, ag_store64};
            static const AGHandler wbloads[] = {ag_wbload8, ag_wbload16, ag_wbload32, ag_wbload64};
            static const AGHandler wbstores[] = {ag_wbstore8, ag_wbstore16, ag_wbstore32, ag_wbstore64};
            static const AGHandler regloads[] = {ag_regload8, ag_regload16, ag_regload32, ag_regload64};
            static const AGHandler regstores[] = {ag_regstore8, ag_regstore16, ag_regstore32, ag_regstore64};
            static const AGHandler signed_loads[2][3] = {
                {ag_loads8x, ag_loads16x, ag_loads32x}, {ag_loads8w, ag_loads16w, NULL}};
            static const AGHandler signed_regloads[2][3] = {
                {ag_regloads8x, ag_regloads16x, ag_regloads32x}, {ag_regloads8w, ag_regloads16w, NULL}};
            static const AGHandler signed_wbloads[2][3] = {
                {ag_wbloads8x, ag_wbloads16x, ag_wbloads32x}, {ag_wbloads8w, ag_wbloads16w, NULL}};
            if ((d.raw & (1u << 26)) || d.flags > 15 ||
                (d.width != 1 && d.width != 2 && d.width != 4 && d.width != 8)) break;
            if (d.kind == AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE) {
                // LDTR/STTR require an unprivileged permission check. Bit 21
                // excludes reserved/other encodings accepted by a broad decoder.
                if ((d.raw & (1u << 21)) || ((d.raw >> 10) & 3) == 2) break;
                if ((d.flags & 8) && d.rn == d.rt && d.rn != 31) break;
            }
            unsigned size = d.width == 8 ? 3 : d.width == 4 ? 2 : d.width == 2 ? 1 : 0;
            int reg = d.kind == AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET;
            AGHandler handler;
            if (d.flags & 2) {
                if (!(d.flags & 1) || size == 3 || ((d.flags & 4) && size == 2)) break;
                handler = reg ? signed_regloads[(d.flags >> 2) & 1][size] :
                    d.flags & 8 ? signed_wbloads[(d.flags >> 2) & 1][size] :
                    signed_loads[(d.flags >> 2) & 1][size];
            } else {
                if (d.flags & 4) break;
                handler = reg ? (d.flags & 1 ? regloads[size] : regstores[size]) :
                    d.flags & 8 ? (d.flags & 1 ? wbloads[size] : wbstores[size]) :
                    (d.flags & 1 ? loads[size] : stores[size]);
            }
            op->source = reg_offset(d.rn, 1);
            op->destination = reg_offset(d.rt, 0);
            op->auxiliary = d.width | ((uint64_t)d.flags << 8);
            if (reg) {
                if (!(d.condition == 2 || d.condition == 3 || d.condition == 6 || d.condition == 7) ||
                    (d.shift_amount != 0 && d.shift_amount != size)) break;
                op->auxiliary |= AG_MEM_REGISTER |
                    ((uint64_t)reg_offset(d.rm, 0) << AG_MEM_OPERAND_SHIFT) |
                    ((uint64_t)d.condition << AG_MEM_EXTEND_SHIFT) |
                    ((uint64_t)d.shift_amount << AG_MEM_SCALE_SHIFT);
            } else if (d.flags & 8) {
                op->auxiliary |= (uint64_t)(uint16_t)d.immediate2 << AG_MEM_OPERAND_SHIFT;
            }
            op->handler = handler;
            break;
        }
        case AVZ_NATIVE_OP_NOP:
            if (d.raw == UINT32_C(0xd503201f)) op->handler = ag_nop;
            break;
        case AVZ_NATIVE_OP_CONDITIONAL_SELECT: {
            static const AGHandler handlers[2][4] = {
                {ag_csel32, ag_csinc32, ag_csinv32, ag_csneg32},
                {ag_csel64, ag_csinc64, ag_csinv64, ag_csneg64}};
            // S must be zero, including when the shared decoder is permissive.
            if ((d.raw & UINT32_C(0x3fe00800)) != UINT32_C(0x1a800000) || (d.flags & ~5u)) break;
            op->handler = handlers[d.bits == 64][(d.flags & 1) | ((d.flags & 4) >> 1)];
            op->auxiliary = reg_offset(d.rm, 0);
            op->immediate = conditions(d.condition);
            break;
        }
        case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER:
        case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE: {
            static const AGHandler handlers[2][2][2] = {
                {{ag_ccmnreg32, ag_ccmpreg32}, {ag_ccmnreg64, ag_ccmpreg64}},
                {{ag_ccmnimm32, ag_ccmpimm32}, {ag_ccmnimm64, ag_ccmpimm64}}};
            int immediate = d.kind == AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE;
            if (d.flags > 1) break;
            uint64_t flags = (uint64_t)(immediate ? d.immediate2 : d.immediate);
            op->handler = handlers[immediate][d.bits == 64][d.flags];
            op->auxiliary = reg_offset(d.rm, 0) |
                ((uint64_t)conditions(d.condition) << 16) | ((flags >> 28) << 32);
            op->immediate = immediate ? (uint64_t)d.immediate : 0;
            break;
        }
        case AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE: {
            static const AGHandler handlers[] = ARITHMETIC_TABLE(imm);
            if ((d.raw & UINT32_C(0x00800000)) || d.flags > 3) break;
            op->handler = handlers[(d.bits == 64 ? 4 : 0) + d.flags];
            op->source = reg_offset(d.rn, 1);
            op->destination = reg_offset(d.rd, !(d.flags & 2));
            break;
        }
        case AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER:
        case AVZ_NATIVE_OP_ADD_SUB_CARRY: {
            static const AGHandler handlers[2][8] = {ARITHMETIC_TABLE(reg), ARITHMETIC_TABLE(carry)};
            static const AGHandler shifted[3][8] = {
                ARITHMETIC_TABLE(lsl), ARITHMETIC_TABLE(lsr), ARITHMETIC_TABLE(asr)};
            if (d.flags > 3) break;
            op->auxiliary = reg_offset(d.rm, 0);
            unsigned index = (d.bits == 64 ? 4 : 0) + d.flags;
            if (d.kind == AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER && d.shift_amount) {
                if (d.shift_type > 2 || d.shift_amount >= d.bits) break;
                op->immediate = d.shift_amount;
                op->handler = shifted[d.shift_type][index];
            } else op->handler = handlers[d.kind == AVZ_NATIVE_OP_ADD_SUB_CARRY][index];
            break;
        }
        case AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER: {
            static const AGHandler handlers[2][8] = {LOGICAL_TABLE(), LOGICAL_TABLE(inv)};
            static const AGHandler shifted[2][4][8] = {
                {LOGICAL_TABLE(lsl), LOGICAL_TABLE(lsr), LOGICAL_TABLE(asr), LOGICAL_TABLE(ror)},
                {LOGICAL_TABLE(lslinv), LOGICAL_TABLE(lsrinv), LOGICAL_TABLE(asrinv), LOGICAL_TABLE(rorinv)}};
            if (d.flags > 7 || d.shift_type > 3 || d.shift_amount >= d.bits) break;
            op->auxiliary = reg_offset(d.rm, 0);
            unsigned index = (d.bits == 64 ? 4 : 0) + (d.flags & 3);
            op->immediate = d.shift_amount;
            op->handler = d.shift_amount ? shifted[d.flags >> 2][d.shift_type][index] :
                handlers[d.flags >> 2][index];
            break;
        }
        case AVZ_NATIVE_OP_LOGICAL_IMMEDIATE: {
            static const AGHandler handlers[] = LOGICAL_TABLE(imm);
            if (d.flags > 3) break;
            // Rn is XZR; Rd is SP except for flag-setting ANDS/TST.
            op->destination = reg_offset(d.rd, d.flags != 3);
            op->handler = handlers[(d.bits == 64 ? 4 : 0) + d.flags];
            break;
        }
        case AVZ_NATIVE_OP_MOVE_WIDE: {
            uint64_t mask = d.bits == 64 ? UINT64_MAX : UINT32_MAX;
            op->auxiliary = mask & ~(UINT64_C(0xffff) << d.shift_amount);
            if (d.flags == 0) op->immediate = ~op->immediate;
            op->immediate &= mask;
            op->source = op->destination;
            op->handler = d.flags == 3 ? ag_movk : ag_move;
            break;
        }
        case AVZ_NATIVE_OP_ADR:
            op->immediate += (d.flags & 1) ? pc & ~UINT64_C(4095) : pc;
            op->handler = ag_move;
            break;
        case AVZ_NATIVE_OP_REGISTER_BRANCH:
            op->source = reg_offset(d.rn, 0);
            op->handler = d.flags & 1 ? ag_indirect_link : ag_indirect;
            break;
        case AVZ_NATIVE_OP_BRANCH:
        case AVZ_NATIVE_OP_BCOND:
        case AVZ_NATIVE_OP_CBZ:
        case AVZ_NATIVE_OP_TBZ:
            op->immediate += pc;
            op->taken = lookup(p, op->immediate);
            if (d.kind == AVZ_NATIVE_OP_BRANCH) op->handler = d.flags & 1 ? ag_link : ag_branch;
            else if (d.kind == AVZ_NATIVE_OP_BCOND) {
                op->handler = ag_bcond; op->auxiliary = conditions(d.condition);
            } else {
                op->source = reg_offset(d.rt, 0);
                op->auxiliary = d.kind == AVZ_NATIVE_OP_TBZ ? UINT64_C(1) << d.shift_amount :
                    d.bits == 64 ? UINT64_MAX : UINT32_MAX;
                op->handler = d.flags & 1 ? ag_nonzero : ag_zero;
            }
            break;
        default: break;
        }
    }
    for (size_t i = 0; i < count; i++) {
        if (p->operations[i].handler == ag_unsupported) { p->capability = 0; break; }
    }
    return p;
}
void ag_destroy(AGProgram *p) {
    if (!p) return;
    p->retired = 1;
    if (!p->active_runs) free(p);
}
unsigned ag_program_capabilities(const AGProgram *p) {
    return p && !p->retired ? p->capability : 0;
}
size_t ag_program_bytes(const AGProgram *p) {
    return p ? sizeof(*p) + (p->targets.count + 1) * sizeof(AGOperation) : 0;
}
AVZNativeBlockResult ag_run(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards) {
    return ag_run_memory(p, budget, cpu, guards, NULL);
}
/* Constant-specialized entries share semantics and the exact same assembly
 * addresses. Preparation and guard coalescing have independent controls. */
static inline __attribute__((always_inline)) AVZNativeBlockResult run_memory(
    const AGProgram *p, uint64_t budget, AVZNativeCPU *cpu,
    const AGGuards *guards, AVZNativeMemoryFastPath *memory,
    int inline_prepare, int coalesce_guards) {
    AGRun run;
    run.cpu = cpu;
    run.budget = budget;
    run.result = (AVZNativeBlockResult){0};
    if (!p || !cpu) run.result.status = AVZ_TP_STATUS_INVALID_ARGUMENT;
    else if (!budget) run.result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    else if (cpu->halted) run.result.status = AVZ_NATIVE_STATUS_HALTED;
    else if (p->retired) run.result.status = AVZ_TP_STATUS_REVALIDATE;
    else if (p->active_runs == UINT32_MAX) run.result.status = AVZ_TP_STATUS_INVALID_ARGUMENT;
    else {
        AGProgram *owned = (AGProgram *)p;
        owned->active_runs++;
        run.guards = guards ? *guards : (AGGuards){0};
        if (inline_prepare) ag_memory_prepare_inline(&run.memory, memory);
        else ag_memory_prepare(&run.memory, memory);
        /* Keep the later memory-view acquire check only for the identical
         * proof. Never replace a pre-selection expectation with a newer epoch. */
        if (coalesce_guards && run.memory.shared &&
            !run.guards.shared[1] && !run.guards.shared[2] &&
            run.guards.shared[0] == &run.memory.shared->code_mutation_epoch &&
            run.guards.expected[1] == run.memory.code_epoch)
            run.guards.shared[0] = NULL;
        run.operation = lookup(p, cpu->pc);
        run.targets = &p->targets;
        run.target_count = 1;
        run.chain = NULL;
        if (run.memory.shared && run.memory.translation_epoch != run.memory.observed_translation)
            run.result.status = AVZ_TP_STATUS_REVALIDATE;
        else ag_enter(&run);
        if (--owned->active_runs == 0 && owned->retired) free(owned);
    }
    return run.result;
}
AVZNativeBlockResult ag_run_memory(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory) {
    return run_memory(p, budget, cpu, guards, memory, 1, 0);
}
AVZNativeBlockResult ag_run_memory_coalesced(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory) {
    return run_memory(p, budget, cpu, guards, memory, 1, 1);
}
AVZNativeBlockResult ag_run_memory_uncoalesced(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory) {
    return run_memory(p, budget, cpu, guards, memory, 1, 0);
}
AVZNativeBlockResult ag_run_memory_control(const AGProgram *p, uint64_t budget,
    AVZNativeCPU *cpu, const AGGuards *guards, AVZNativeMemoryFastPath *memory) {
    return run_memory(p, budget, cpu, guards, memory, 0, 0);
}
#else
int ag_available(void) { return 0; }
unsigned ag_program_capabilities(const AGProgram *p) { (void)p; return 0; }
AGProgram *ag_create(const uint32_t *w, size_t n, uint64_t b) { (void)w; (void)n; (void)b; return NULL; }
void ag_destroy(AGProgram *p) { (void)p; }
size_t ag_program_bytes(const AGProgram *p) { (void)p; return 0; }
AVZNativeBlockResult ag_run(const AGProgram *p, uint64_t n, AVZNativeCPU *c, const AGGuards *g) {
    (void)p; (void)n; (void)c; (void)g;
    return (AVZNativeBlockResult){.status = AVZ_TP_STATUS_DISABLED};
}
AVZNativeBlockResult ag_run_memory(const AGProgram *p, uint64_t n, AVZNativeCPU *c,
    const AGGuards *g, AVZNativeMemoryFastPath *m) {
    (void)m;
    return ag_run(p, n, c, g);
}
AVZNativeBlockResult ag_run_memory_control(const AGProgram *p, uint64_t n, AVZNativeCPU *c,
    const AGGuards *g, AVZNativeMemoryFastPath *m) {
    return ag_run_memory(p, n, c, g, m);
}
AVZNativeBlockResult ag_run_memory_uncoalesced(const AGProgram *p, uint64_t n, AVZNativeCPU *c,
    const AGGuards *g, AVZNativeMemoryFastPath *m) {
    return ag_run_memory(p, n, c, g, m);
}
AVZNativeBlockResult ag_run_memory_coalesced(const AGProgram *p, uint64_t n, AVZNativeCPU *c,
    const AGGuards *g, AVZNativeMemoryFastPath *m) {
    return ag_run_memory(p, n, c, g, m);
}
#endif
