#define _POSIX_C_SOURCE 200809L
#include "gadget_internal.h"
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d case=%" PRIu64 ": %s\n", __LINE__, cases, #x); abort(); } } while (0)
static uint64_t cases, seed = UINT64_C(0xe17235be93406fa1);
static uint64_t random64(void) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; }
static AVZNativeCPU initial(uint64_t pc) {
    AVZNativeCPU c; memset(&c, 0, sizeof(c));
    for (unsigned i = 0; i < 31; i++) c.x[i] = random64();
    for (unsigned i = 0; i < 32; i++) { c.v[i].low = random64(); c.v[i].high = random64(); }
    c.pc = pc; c.sp = random64(); c.pstate = random64(); c.fpcr = 0x400000; c.fpsr = 0x1234;
    c.exclusive_address = 0x12000; c.exclusive_generation = 7; c.exclusive_valid = 1; c.exclusive_size = 8;
    return c;
}
static AVZNativeBlockResult reference(const AVZNativeInstruction *code, size_t count,
    uint64_t base, uint64_t budget, AVZNativeCPU *cpu, int threaded) {
    if (threaded) return avz_native_run_threaded_decoded_block_registers(code, count, base,
        budget, cpu->x, &cpu->sp, &cpu->pc, &cpu->pstate, &cpu->halted,
        NULL, NULL, NULL, NULL, NULL);
    return avz_native_run_decoded_block_registers(code, count, base, budget,
        cpu->x, &cpu->sp, &cpu->pc, &cpu->pstate, &cpu->halted, NULL, NULL, NULL, NULL, NULL);
}
static void compare(const uint32_t *words, size_t count, uint64_t base,
    uint64_t budget, AVZNativeCPU start) {
    AVZNativeInstruction code[16]; CHECK(count <= 16);
    for (size_t i = 0; i < count; i++) CHECK(avz_native_decode_instruction(words[i], &code[i]));
    AGProgram *p = ag_create(words, count, base); CHECK(p);
    AVZNativeCPU actual = start;
    AVZNativeBlockResult r = ag_run(p, budget, &actual, NULL);
    for (int threaded = 0; threaded < 3; threaded++) {
        if (threaded && start.halted) continue;
        AVZNativeCPU expected = start;
        AVZNativeBlockResult e = threaded == 2 ? ag_reference_cpu(code, count, base, budget, &expected) :
            reference(code, count, base, budget, &expected, threaded);
        if (r.status != e.status || r.steps != e.steps || memcmp(&actual, &expected, sizeof(actual)))
            fprintf(stderr, "raw=%08x budget=%" PRIu64 " status=%u/%u steps=%" PRIu64 "/%" PRIu64 " pc=%" PRIx64 "/%" PRIx64 "\n",
                words[0], budget, r.status, e.status, r.steps, e.steps, actual.pc, expected.pc);
        CHECK(r.status == e.status && r.steps == e.steps && r.unsupported_instruction == e.unsupported_instruction);
        CHECK(memcmp(&actual, &expected, sizeof(actual)) == 0);
    }
    CHECK(r.generic_dispatches == r.steps && !r.fast_path_hits && !r.fast_path_steps && !r.mapped_blocks);
    ag_destroy(p); cases++;
}
static void singles(void) {
    const uint64_t edge[] = {0, 1, UINT32_MAX, UINT64_MAX, 0x7fffffff, 0x80000000,
        UINT64_C(0x7fffffffffffffff), UINT64_C(0x8000000000000000)};
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < 4; op++)
    for (unsigned rn = 0; rn < 32; rn++)
    for (unsigned rd = 0; rd < 32; rd++)
    for (unsigned e = 0; e < 8; e++) {
        uint32_t word = 0x11000000 | (sf << 31) | ((op & 1) << 30) | ((op >> 1) << 29) |
            ((e & 1) << 22) | (((rn + rd) & 1 ? 4095u : 1u) << 10) | (rn << 5) | rd;
        AVZNativeCPU c = initial(0x8000);
        for (unsigned r = 0; r < 31; r++) c.x[r] = edge[e];
        c.sp = edge[e]; compare(&word, 1, 0x8000, 1, c);
    }
    for (unsigned family = 0; family < 3; family++)
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < 4; op++)
    for (unsigned i = 0; i < 32; i++)
    for (unsigned e = 0; e < 16; e++) {
        unsigned rn = i, rm = (i + 7) % 32, rd = (i + 15) % 32;
        uint32_t word = (family == 0 ? 0x0b000000 : family == 1 ? 0x1a000000 : 0x0a000000) |
            (sf << 31) | (rm << 16) | (rn << 5) | rd;
        word |= family == 2 ? op << 29 : ((op & 1) << 30) | ((op >> 1) << 29);
        AVZNativeCPU c = initial(0x8000);
        if (rn < 31) c.x[rn] = edge[e % 8];
        if (rm < 31) c.x[rm] = edge[(e * 3 + 1) % 8];
        c.pstate = (c.pstate & ~UINT64_C(0xf0000000)) | ((uint64_t)e << 28);
        compare(&word, 1, 0x8000, 1, c);
    }
    const unsigned move_ops[] = {0, 2, 3};
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned k = 0; k < 3; k++)
    for (unsigned hw = 0; hw < (sf ? 4u : 2u); hw++)
    for (unsigned rd = 0; rd < 32; rd++) {
        uint32_t word = 0x12800000 | (sf << 31) | (move_ops[k] << 29) | (hw << 21) | (0xa55au << 5) | rd;
        compare(&word, 1, 0x8000, 1, initial(0x8000));
    }
}
static void indirect_branches(void) {
    const uint32_t forms[] = {0xd61f0000, 0xd63f0000, 0xd65f0000};
    const uint64_t bases[] = {0x8000, UINT64_C(0xffff800000008000)};
    unsigned checked = 0;
    for (unsigned b = 0; b < 2; b++)
    for (unsigned form = 0; form < 3; form++)
    for (unsigned rn = 0; rn < 32; rn++) {
        uint64_t base = bases[b];
        uint64_t targets[] = {base, base + 4, base + 8, base + 12,
            base - 4, base + 1, base + 7, 0, UINT64_MAX};
        for (unsigned t = 0; t < 9; t++) {
            uint32_t words[] = {forms[form] | (rn << 5), 0xd503201f, 0xd503201f};
            AVZNativeCPU start = initial(base);
            if (rn < 31) start.x[rn] = targets[t];
            for (unsigned budget = 0; budget < 5; budget++) {
                compare(words, 3, base, budget, start); checked++;
            }
            AVZNativeCPU expected = start, actual = start;
            expected.pc = rn == 31 ? 0 : targets[t];
            if (form == 1) expected.x[30] = base + 4;
            AGProgram *p = ag_create(words, 3, base); CHECK(p);
            AVZNativeBlockResult r = ag_run(p, 1, &actual, NULL);
            CHECK(r.steps == 1 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            CHECK(!memcmp(&actual, &expected, sizeof(actual)));
            ag_destroy(p);
        }
    }
    printf("PASS phase6 indirect branches: %u BR/BLR/RET differential budgets plus independent target/LR expectations\n", checked);
}
static void branches(void) {
    for (unsigned cond = 0; cond < 16; cond++)
    for (unsigned flags = 0; flags < 16; flags++)
    for (unsigned budget = 0; budget < 13; budget++) {
        uint32_t words[] = {0x54000040 | cond, 0x91000400, 0x17fffffe};
        AVZNativeCPU c = initial(0x8000);
        c.pstate = (c.pstate & ~UINT64_C(0xf0000000)) | ((uint64_t)flags << 28);
        compare(words, 3, 0x8000, budget, c);
    }
    const uint32_t words[] = {0x91000400, 0xf100043f, 0x54000040, 0x17fffffd, 0x94000002};
    const uint64_t budgets[] = {0, 1, 2, 3, 4, 15, 16, 17, 63, 64, 65, 255, 256, 257, 4096, 4097};
    for (unsigned i = 0; i < sizeof(budgets) / sizeof(budgets[0]); i++)
    for (unsigned pc = 0; pc < 6; pc++) compare(words, 5, 0x8000, budgets[i], initial(0x8000 + pc * 4));
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned nz = 0; nz < 2; nz++)
    for (unsigned bit = 0; bit < 64; bit++)
    for (unsigned reg = 30; reg < 32; reg++) {
        uint32_t branch[] = {0x34000000 | (sf << 31) | (nz << 24) | (2u << 5) | reg,
            0x36000000 | ((bit >> 5) << 31) | (nz << 24) | ((bit & 31) << 19) | (2u << 5) | reg,
            0xd503201f};
        AVZNativeCPU c = initial(0x8000); c.x[30] = UINT64_C(1) << bit;
        compare(branch, 3, 0x8000, 8, c);
    }
    const uint32_t adr[] = {0x10000000, 0xb0000001, 0x10ffffe2};
    compare(adr, 3, 0x8ffc, 8, initial(0x8ffc));
    uint32_t nop = 0xd503201f;
    compare(&nop, 1, UINT64_MAX - 3, 2, initial(UINT64_MAX - 3));
}
static void shifted_and_masks(void) {
    const uint64_t edge[] = {0, 1, UINT32_MAX, UINT64_MAX, 0x7fffffff, 0x80000000,
        UINT64_C(0x7fffffffffffffff), UINT64_C(0x8000000000000000)};
    for (unsigned logical = 0; logical < 2; logical++)
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < (logical ? 8u : 4u); op++)
    for (unsigned shift = 0; shift < (logical ? 4u : 3u); shift++)
    for (unsigned amount = 0; amount < (sf ? 64u : 32u); amount++)
    for (unsigned alias = 0; alias < 8; alias++) {
        unsigned rn = alias & 1 ? 31 : 0, rm = alias & 2 ? 31 : 1;
        unsigned rd = alias & 4 ? 31 : alias % 2;
        uint32_t word = (logical ? 0x0a000000 : 0x0b000000) | (sf << 31) |
            (shift << 22) | (rm << 16) | (amount << 10) | (rn << 5) | rd;
        word |= logical ? ((op & 3) << 29) | ((op >> 2) << 21) :
            ((op & 1) << 30) | ((op >> 1) << 29);
        AVZNativeCPU c = initial(0x8000);
        c.x[0] = edge[alias]; c.x[1] = edge[(alias + amount) % 8];
        compare(&word, 1, 0x8000, 1, c);
    }
    // Exhaust the logical-immediate encoding space. Unallocated words must
    // side-exit without retiring or changing even non-integer CPU state.
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < 4; op++)
    for (unsigned encoding = 0; encoding < 8192; encoding++) {
        unsigned rn = encoding & 1 ? 31 : 0, rd = encoding & 2 ? 31 : 0;
        uint32_t word = 0x12000000 | (sf << 31) | (op << 29) |
            ((encoding >> 12) << 22) | (((encoding >> 6) & 63) << 16) |
            ((encoding & 63) << 10) | (rn << 5) | rd;
        AVZNativeInstruction d;
        AVZNativeCPU c = initial(0x8000);
        if (avz_native_decode_instruction(word, &d)) compare(&word, 1, 0x8000, 1, c);
        else {
            AGProgram *p = ag_create(&word, 1, 0x8000); CHECK(p);
            AVZNativeCPU before = c;
            AVZNativeBlockResult r = ag_run(p, 1, &c, NULL);
            CHECK(r.status == AVZ_NATIVE_STATUS_UNSUPPORTED && !r.steps && r.unsupported_instruction == word);
            CHECK(!memcmp(&before, &c, sizeof(c))); ag_destroy(p); cases++;
        }
    }
    // Observed Phosh/Settings prefixes, including Squeekboard's SP alignment.
    const uint32_t words[] = {0x0b0d15ad, 0x91000484, 0x0b0d002d, 0xaa4414c4,
        0xaa440884, 0xaa441084, 0x8a230042, 0x121c08a6, 0x927ef426, 0xf26c001f,
        0xb2407fe1, 0x9279e13f, 0x17fffff4};
    for (unsigned budget = 0; budget < 65; budget++)
        compare(words, sizeof(words) / sizeof(words[0]), 0x8000, budget, initial(0x8000));
    const uint32_t align_sp = 0x9279e13f;
    AGProgram *p = ag_create(&align_sp, 1, 0x8000); CHECK(p);
    AVZNativeCPU c = initial(0x8000), before;
    c.x[9] = UINT64_C(0x123456789abcdef1); before = c;
    AVZNativeBlockResult r = ag_run(p, 1, &c, NULL);
    before.sp = UINT64_C(0x123456789abcde80); before.pc += 4;
    CHECK(r.steps == 1 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
    CHECK(!memcmp(&before, &c, sizeof(c))); ag_destroy(p); cases++;
}
extern uint64_t ag_abi_probe(AGRun *run);
static int expected_condition(unsigned condition, unsigned flags) {
    unsigned n = flags >> 3, z = (flags >> 2) & 1, c = (flags >> 1) & 1, v = flags & 1;
    switch (condition) {
    case 0: return z; case 1: return !z; case 2: return c; case 3: return !c;
    case 4: return n; case 5: return !n; case 6: return v; case 7: return !v;
    case 8: return c && !z; case 9: return !c || z;
    case 10: return n == v; case 11: return n != v;
    case 12: return !z && n == v; case 13: return z || n != v;
    default: return 1; // Both AL and NV are unconditional for these A64 forms.
    }
}
static uint64_t native_compare_flags(uint64_t lhs, uint64_t rhs, int sf, int subtract) {
    uint64_t flags;
    if (sf && subtract) __asm__ volatile("subs xzr, %1, %2\n\tmrs %0, nzcv" : "=r"(flags) : "r"(lhs), "r"(rhs) : "cc");
    else if (sf) __asm__ volatile("adds xzr, %1, %2\n\tmrs %0, nzcv" : "=r"(flags) : "r"(lhs), "r"(rhs) : "cc");
    else if (subtract) __asm__ volatile("subs wzr, %w1, %w2\n\tmrs %0, nzcv" : "=r"(flags) : "r"(lhs), "r"(rhs) : "cc");
    else __asm__ volatile("adds wzr, %w1, %w2\n\tmrs %0, nzcv" : "=r"(flags) : "r"(lhs), "r"(rhs) : "cc");
    return flags;
}
static void conditional_forms(void) {
    const uint64_t edges[] = {0, 1, UINT32_MAX, UINT64_MAX, 0x7fffffff, 0x80000000,
        UINT64_C(0x7fffffffffffffff), UINT64_C(0x8000000000000000)};
    unsigned selects = 0, compares = 0;
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < 4; op++)
    for (unsigned condition = 0; condition < 16; condition++)
    for (unsigned flags = 0; flags < 16; flags++)
    for (unsigned rd = 0; rd < 32; rd++) {
        unsigned rn = (rd + flags) % 32, rm = (rd + op * 3) % 32;
        uint32_t word = 0x1a800000 | (sf << 31) | ((op >> 1) << 30) |
            ((op & 1) << 10) | (rm << 16) | (condition << 12) | (rn << 5) | rd;
        AVZNativeCPU c = initial(0x8000);
        c.pstate = (c.pstate & ~UINT64_C(0xf0000000)) | ((uint64_t)flags << 28);
        if (rn != 31) c.x[rn] = edges[(rd + flags) % 8];
        if (rm != 31) c.x[rm] = edges[(condition + op) % 8];
        uint64_t lhs = rn == 31 ? 0 : c.x[rn], rhs = rm == 31 ? 0 : c.x[rm];
        uint64_t alternative = op == 0 ? rhs : op == 1 ? rhs + 1 : op == 2 ? ~rhs : 0 - rhs;
        uint64_t value = expected_condition(condition, flags) ? lhs : alternative;
        AVZNativeCPU expected = c, actual = c;
        if (rd != 31) expected.x[rd] = sf ? value : (uint32_t)value;
        expected.pc += 4;
        AGProgram *p = ag_create(&word, 1, c.pc); CHECK(p);
        AVZNativeBlockResult r = ag_run(p, 1, &actual, NULL);
        CHECK(r.steps == 1 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(!memcmp(&expected, &actual, sizeof(actual))); ag_destroy(p);
        for (unsigned budget = 0; budget <= 2; budget++) compare(&word, 1, c.pc, budget, c);
        selects++;
    }
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned subtract = 0; subtract < 2; subtract++)
    for (unsigned immediate = 0; immediate < 2; immediate++)
    for (unsigned condition = 0; condition < 16; condition++)
    for (unsigned flags = 0; flags < 16; flags++)
    for (unsigned nzcv = 0; nzcv < 16; nzcv++)
    for (unsigned variant = 0; variant < 4; variant++) {
        unsigned rn = (flags + condition + variant) % 32;
        unsigned operand = (flags + nzcv + variant) % 32;
        uint32_t word = 0x3a400000 | (sf << 31) | (subtract << 30) | (immediate << 11) |
            (operand << 16) | (condition << 12) | (rn << 5) | nzcv;
        AVZNativeCPU c = initial(0x8000);
        c.pstate = (c.pstate & ~UINT64_C(0xf0000000)) | ((uint64_t)flags << 28);
        if (rn != 31) c.x[rn] = edges[(flags + variant) % 8];
        if (!immediate && operand != 31) c.x[operand] = edges[(nzcv + variant * 3) % 8];
        uint64_t lhs = rn == 31 ? 0 : c.x[rn];
        uint64_t rhs = immediate ? operand : operand == 31 ? 0 : c.x[operand];
        uint64_t result_flags = expected_condition(condition, flags) ?
            native_compare_flags(lhs, rhs, sf, subtract) : (uint64_t)nzcv << 28;
        AVZNativeCPU expected = c, actual = c;
        expected.pstate = (c.pstate & ~UINT64_C(0xf0000000)) | result_flags;
        expected.pc += 4;
        AGProgram *p = ag_create(&word, 1, c.pc); CHECK(p);
        AVZNativeBlockResult r = ag_run(p, 1, &actual, NULL);
        CHECK(r.steps == 1 && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
        CHECK(!memcmp(&expected, &actual, sizeof(actual))); ag_destroy(p);
        compare(&word, 1, c.pc, 1, c); compares++;
    }
    for (unsigned sf = 0; sf < 2; sf++)
    for (unsigned op = 0; op < 4; op++) {
        uint32_t word = 0x3a800000 | (sf << 31) | ((op >> 1) << 30) | ((op & 1) << 10);
        AGProgram *p = ag_create(&word, 1, 0x8000); CHECK(p);
        AVZNativeCPU c = initial(0x8000), before = c;
        AVZNativeBlockResult r = ag_run(p, 1, &c, NULL);
        CHECK(!r.steps && r.status == AVZ_NATIVE_STATUS_UNSUPPORTED && r.unsupported_instruction == word);
        CHECK(!memcmp(&c, &before, sizeof(c))); ag_destroy(p);
    }
    printf("PASS conditional forms: %u independent selects, %u host-NZCV compares, three C references and 8 reserved exits\n", selects, compares);
}
static void boundaries(void) {
    const uint32_t loop[] = {0x91000400, 0x17ffffff};
    AGProgram *p = ag_create(loop, 2, 0x8000); CHECK(p);
    uint64_t local = 1; _Atomic uint64_t shared[3] = {2, 3, 4};
    AGGuards guards = {.local = &local, .shared = {&shared[0], &shared[1], &shared[2]}, .expected = {1, 2, 3, 4}};
    for (unsigned stale = 0; stale < 5; stale++)
    for (unsigned halted = 0; halted < 2; halted++)
    for (unsigned budget = 0; budget < 2; budget++) {
        AGGuards g = guards;
        if (stale) g.expected[stale - 1]++;
        AVZNativeCPU c = initial(0x8000), before;
        c.halted = halted; before = c;
        AVZNativeBlockResult r = ag_run(p, budget, &c, &g);
        uint32_t status = !budget ? AVZ_NATIVE_STATUS_MAX_STEPS : halted ? AVZ_NATIVE_STATUS_HALTED :
            stale ? AVZ_TP_STATUS_REVALIDATE : AVZ_NATIVE_STATUS_MAX_STEPS;
        uint64_t steps = budget && !halted && !stale;
        if (steps) { before.x[0]++; before.pc += 4; }
        CHECK(r.status == status && r.steps == steps && memcmp(&c, &before, sizeof(c)) == 0); cases++;
    }
    const uint64_t pcs[] = {0x8001, 0x7ffc, 0x8008};
    for (unsigned i = 0; i < 3; i++) {
        AVZNativeCPU c = initial(pcs[i]), before = c;
        CHECK(ag_run(p, 3, &c, NULL).status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        CHECK(memcmp(&c, &before, sizeof(c)) == 0);
    }
    AVZNativeCPU c = initial(0x8000), before = c;
    CHECK(ag_run(NULL, 0, &c, NULL).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(ag_run(p, 0, NULL, NULL).status == AVZ_TP_STATUS_INVALID_ARGUMENT);
    CHECK(memcmp(&c, &before, sizeof(c)) == 0);
    CHECK(!ag_create(loop, 0, 0) && !ag_create(loop, 4097, 0) && !ag_create(loop, 2, 1));
    CHECK(!ag_create(loop, 2, UINT64_MAX - 3));
    const uint32_t rejected[] = {0xf9400000, 0xd5033fdf, 0xd5033f9f, 0xd503207f,
        0xd4000001, 0xffffffff, 0x11800000, 0x8bc10000, 0x0b018000, 0x0a018000, 0x1200fc00};
    for (unsigned i = 0; i < sizeof(rejected) / sizeof(rejected[0]); i++) {
        uint32_t code[] = {0x91000400, rejected[i], 0x91000800};
        AGProgram *q = ag_create(code, 3, 0x8000); CHECK(q);
        c = initial(0x8000); before = c; before.x[0]++; before.pc += 4;
        AVZNativeBlockResult r = ag_run(q, 9, &c, &guards);
        CHECK(r.status == AVZ_NATIVE_STATUS_UNSUPPORTED && r.steps == 1 && r.unsupported_instruction == rejected[i]);
        CHECK(memcmp(&c, &before, sizeof(c)) == 0);
        AGRun run = {.cpu = &c, .operation = &q->operations[1], .budget = 1, .guards = guards};
        CHECK(ag_abi_probe(&run) == 0 && run.result.status == AVZ_NATIVE_STATUS_UNSUPPORTED);
        ag_destroy(q); cases++;
    }
    for (unsigned mode = 0; mode < 3; mode++) {
        c = initial(0x8000);
        AGRun run = {.cpu = &c, .operation = &p->operations[mode == 1 ? 2 : 0],
            .budget = 1000000, .guards = guards};
        if (mode == 2) run.guards.expected[0]++;
        CHECK(ag_abi_probe(&run) == 0);
        CHECK(run.result.status == (mode == 0 ? AVZ_NATIVE_STATUS_MAX_STEPS : mode == 1 ?
            AVZ_NATIVE_STATUS_OUTSIDE_BLOCK : AVZ_TP_STATUS_REVALIDATE));
    }
    ag_destroy(p);
}
typedef struct { const AGProgram *p; AGGuards guards; AVZNativeCPU cpu; AVZNativeBlockResult result; _Atomic int started; } Worker;
static void *worker(void *opaque) {
    Worker *w = opaque; atomic_store(&w->started, 1);
    w->result = ag_run(w->p, UINT64_C(100000000), &w->cpu, &w->guards); return NULL;
}
static void invalidation(void) {
    const uint32_t words[] = {0x91000400, 0x17ffffff};
    AGProgram *p = ag_create(words, 2, 0x8000); CHECK(p);
    for (unsigned token = 0; token < 3; token++) {
        _Atomic uint64_t shared[3] = {1, 1, 1};
        Worker w = {.p = p, .guards = {.shared = {&shared[0], &shared[1], &shared[2]}, .expected = {0, 1, 1, 1}}, .cpu = initial(0x8000)};
        AVZNativeCPU before = w.cpu;
        pthread_t t; CHECK(!pthread_create(&t, NULL, worker, &w));
        while (!atomic_load(&w.started)) sched_yield();
        const struct timespec delay = {.tv_nsec = 5000000};
        CHECK(!nanosleep(&delay, NULL));
        atomic_store_explicit(&shared[token], 2, memory_order_release);
        CHECK(!pthread_join(t, NULL));
        CHECK(w.result.status == AVZ_TP_STATUS_REVALIDATE && w.result.steps > 0 && w.result.steps < 100000000);
        before.x[0] += (w.result.steps + 1) / 2; before.pc += (w.result.steps % 2) * 4;
        CHECK(memcmp(&before, &w.cpu, sizeof(before)) == 0); cases++;
    }
    ag_destroy(p);
}
static uint64_t ns(clockid_t clock) {
    struct timespec t; CHECK(!clock_gettime(clock, &t));
    return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}
static void benchmark(int hot) {
    const uint32_t arithmetic[] = {0x8b010000, 0x9a020000, 0x8a030000, 0x17fffffd};
    const uint32_t branch[] = {0xb1000400, 0x54000040, 0x14000001, 0x17fffffd};
    // Sampled operands arranged into bounded synthetic loops, not guest replay.
    const uint32_t shifted[] = {0x0b0d15ad, 0xaa4414c4, 0x8a230042, 0x17fffffd};
    const uint32_t masks[] = {0x121c08a6, 0x927ef426, 0xb2407fe1, 0x17fffffd};
    const uint32_t indirect[] = {0x91000400, 0x91000421, 0x91000442, 0xd61f0140};
    const uint32_t calls[] = {0xd63f0140, 0x91000400, 0xd61f0160, 0xd65f03c0};
    const uint32_t selects[] = {0x9a820020, 0x1a9f1463, 0xda9fb0a4, 0x17fffffd};
    const uint32_t compares[] = {0xfa421025, 0x3a5f086a, 0xda88a4e6, 0x17fffffd};
    const unsigned windows[] = {4, 64, 256, 4096};
    puts("workload,window,round,mode,steps,wall_ns,cpu_ns,prepare_ns,bytes");
    for (unsigned workload = 0; workload < 2; workload++) {
        const uint32_t *words = hot == 3 ? (workload ? compares : selects) :
            hot == 2 ? (workload ? calls : indirect) :
            hot ? (workload ? masks : shifted) : (workload ? branch : arithmetic);
        AVZNativeInstruction decoded[4];
        for (unsigned i = 0; i < 4; i++) CHECK(avz_native_decode_instruction(words[i], &decoded[i]));
        uint64_t t = ns(CLOCK_MONOTONIC);
        AGProgram *p = ag_create(words, 4, 0x8000); CHECK(p);
        uint64_t prepare = ns(CLOCK_MONOTONIC) - t;
        AVZThreadedPrototype *tp = avz_tp_create(words, 4, 0x8000); CHECK(tp);
        uint64_t local = 1; _Atomic uint64_t shared[3] = {1, 1, 1};
        AGGuards guards = {.local = &local, .shared = {&shared[0], &shared[1], &shared[2]}, .expected = {1, 1, 1, 1}};
        AVZNativeCPU start = initial(0x8000); start.x[0] = 17; start.x[1] = 3; start.x[2] = 2; start.x[3] = UINT64_MAX;
        if (hot == 2) { start.x[10] = workload ? 0x800c : 0x8000; start.x[11] = 0x8000; }
        AVZNativeCPU expected = start;
        CHECK(reference(decoded, 4, 0x8000, 1048576, &expected, 1).steps == 1048576);
        for (unsigned w = 0; w < 4; w++)
        for (unsigned round = 0; round < 15; round++)
        for (unsigned slot = 0; slot < 5; slot++) {
            unsigned mode = (slot + round) % 5;
            // The old C prototype lacks these extended forms. Do not count an
            // unsupported exit as completed work or add an implicit fallback.
            if (hot && mode == 1) continue;
            AVZNativeCPU c = start;
            if (mode == 4) (void)ag_reference_cpu(decoded, 4, 0x8000, 8192, &c);
            else if (mode >= 2) (void)ag_run(p, 8192, &c, mode == 3 ? &guards : NULL);
            else if (mode == 1) (void)avz_tp_run(tp, 8192, &c);
            else (void)reference(decoded, 4, 0x8000, 8192, &c, 1);
            c = start;
            uint64_t ct = ns(CLOCK_THREAD_CPUTIME_ID), wt = ns(CLOCK_MONOTONIC);
            for (uint64_t done = 0; done < 1048576; done += windows[w]) {
                AVZNativeBlockResult r = mode == 4 ? ag_reference_cpu(decoded, 4, 0x8000, windows[w], &c) :
                    mode >= 2 ? ag_run(p, windows[w], &c, mode == 3 ? &guards : NULL) :
                    mode == 1 ? avz_tp_run(tp, windows[w], &c) : reference(decoded, 4, 0x8000, windows[w], &c, 1);
                if (r.steps != windows[w] || r.status != AVZ_NATIVE_STATUS_MAX_STEPS)
                    fprintf(stderr, "benchmark workload=%u mode=%u window=%u steps=%" PRIu64 " status=%u raw=%08x\n",
                        workload, mode, windows[w], r.steps, r.status, r.unsupported_instruction);
                CHECK(r.steps == windows[w] && r.status == AVZ_NATIVE_STATUS_MAX_STEPS);
            }
            wt = ns(CLOCK_MONOTONIC) - wt; ct = ns(CLOCK_THREAD_CPUTIME_ID) - ct;
            CHECK(memcmp(&c, &expected, sizeof(c)) == 0);
            printf("%s,%u,%u,%u,1048576,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%zu\n",
                hot == 3 ? (workload ? "conditional_compare" : "conditional_select") :
                hot == 2 ? (workload ? "call_return" : "indirect") :
                    hot ? (workload ? "masks" : "shifted") : (workload ? "branch" : "arithmetic"),
                windows[w], round, mode, wt, ct, prepare, ag_program_bytes(p));
        }
        ag_destroy(p); avz_tp_destroy(tp);
    }
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && !strcmp(argv[1], "--disabled")) {
        AVZNativeCPU c = initial(0x8000), before = c;
        CHECK(!ag_available() && !ag_create(NULL, 0, 0));
        CHECK(ag_run(NULL, 100, &c, NULL).status == AVZ_TP_STATUS_DISABLED);
        CHECK(ag_run_memory(NULL, 100, &c, NULL, NULL).status == AVZ_TP_STATUS_DISABLED);
        CHECK(!ag_chain_create(NULL, 0, NULL, NULL));
        CHECK(ag_chain_run(NULL, (AGLimits){0}, &c, NULL).status == AVZ_TP_STATUS_DISABLED);
        CHECK(!memcmp(&before, &c, sizeof(c)));
        puts("PASS disabled gadget: no execution or allocation"); return 0;
    }
    CHECK(ag_available());
    if (argc == 2 && !strcmp(argv[1], "--classify")) {
        extern void ag_unsupported(void);
        uint32_t word;
        while (scanf("%" SCNx32, &word) == 1) {
            AVZNativeInstruction d = {0};
            int decoded = avz_native_decode_instruction(word, &d);
            AGProgram *p = ag_create(&word, 1, 0x8000); CHECK(p);
            printf("%08x,%u,%u,%u,%u,%u,%d\n", word, d.kind, d.bits, d.flags,
                d.shift_type, d.shift_amount, decoded && p->operations[0].handler != ag_unsupported);
            ag_destroy(p);
        }
        CHECK(feof(stdin)); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--benchmark")) { benchmark(0); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-hot")) { benchmark(1); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-indirect")) { benchmark(2); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-conditional")) { benchmark(3); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-memory")) {
        extern void ag_memory_benchmark(int addressing);
        ag_memory_benchmark(0); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-entry")) {
        extern void ag_memory_benchmark(int addressing);
        ag_memory_benchmark(3); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-address")) {
        extern void ag_memory_benchmark(int addressing);
        ag_memory_benchmark(1); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-pair")) {
        extern void ag_memory_benchmark(int addressing);
        ag_memory_benchmark(2); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--benchmark-chain")) {
        extern void ag_chain_benchmark(void);
        ag_chain_benchmark(); return 0;
    }
    CHECK(argc == 1);
    singles(); shifted_and_masks(); branches(); indirect_branches(); conditional_forms(); boundaries(); invalidation();
    printf("PASS phase3: %" PRIu64 " differential/boundary cases; ABI preservation, bounded stack, peer invalidation\n", cases);
    extern void ag_memory_tests(void);
    ag_memory_tests();
    extern void ag_chain_tests(void);
    ag_chain_tests();
    return 0;
}
