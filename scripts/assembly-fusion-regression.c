#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
extern void ag_imm32_subs(void), ag_imm64_subs(void);
extern void ag_cmpbranch32(void), ag_cmpbranch64(void), ag_bcond(void);

int main(void) {
    const uint64_t values[] = {0, 1, 7, 8, UINT32_MAX, UINT64_MAX,
        UINT64_C(0x80000000), UINT64_C(0x8000000000000000)};
    size_t cases = 0;
    for (unsigned wide = 0; wide < 2; wide++)
    for (unsigned form = 0; form < 6; form++)
    for (unsigned sp = 0; sp < 2; sp++)
    for (unsigned destination = 0; destination < 4; destination++)
    for (unsigned condition = 0; condition < 16; condition++)
    for (unsigned target = 0; target < 3; target++) {
        // Branch to CMP, local NOP, or outside the program.
        unsigned displacement = target == 0 ? 0x7ffff : target == 1 ? 1 : 3;
        unsigned rd = destination == 3 ? 31 : destination;
        uint32_t arithmetic = (wide ? 0xf1000000 : 0x71000000) | (7 << 10);
        if (form == 1) arithmetic |= 1 << 22; // shifted immediate
        if (form >= 2) arithmetic = (wide ? 0xeb000000 : 0x6b000000) |
            (1 << 16) | (form == 2 ? 0 : ((form - 3) << 22) | ((wide ? 63 : 31) << 10));
        uint32_t words[] = {arithmetic | ((sp ? 31 : 0) << 5) | rd,
            0x54000000 | (displacement << 5) | condition, 0xd503201f};
        AGProgram *fused = ag_create(words, 3, 0x8000);
        AGProgram *plain = ag_create(words, 3, 0x8000);
        AGProgram *single = ag_create(words, 1, 0x8000);
        CHECK(fused && plain && ag_program_capabilities(fused) == 1);
        CHECK(single && fused->operations[0].handler != single->operations[0].handler);
        CHECK(fused->operations[1].handler == ag_bcond);
        plain->operations[0].handler = single->operations[0].handler;
        ag_destroy(single);
        for (size_t v = 0; v < sizeof(values) / sizeof(*values); v++)
        for (unsigned entry = 0; entry < 2; entry++)
        for (unsigned budget = 0; budget < 9; budget++)
        for (unsigned stale = 0; stale < 2; stale++) {
            AVZNativeCPU a = {.pc = 0x8000 + 4 * entry, .sp = values[v],
                .pstate = UINT64_C(0xa00003c5)};
            a.x[0] = values[v];
            a.x[1] = 7;
            a.x[2] = UINT64_C(0xdeadbeef12345678);
            AVZNativeCPU b = a;
            uint64_t epoch = stale;
            AGGuards guards = {.local = &epoch};
            AVZNativeBlockResult ra = ag_run(fused, budget, &a, &guards);
            AVZNativeBlockResult rb = ag_run(plain, budget, &b, &guards);
            CHECK(!memcmp(&a, &b, sizeof(a)));
            CHECK(ra.steps == rb.steps && ra.status == rb.status);
            CHECK(ra.unsupported_instruction == rb.unsupported_instruction);
            if (!stale && entry == 0 && budget == 1) {
                CHECK(ra.steps == 1 && a.pc == 0x8004);
                CHECK((a.pstate & UINT64_C(0x0fffffff)) == 0x3c5);
            }
            cases++;
        }
        // Deterministically change a guard through the guest instruction itself.
        // The fused branch must not execute after CMP/SUBS changes NZCV.
        AVZNativeCPU a = {.pc = 0x8000, .pstate = UINT64_C(0xa00003c5)};
        a.x[1] = 7;
        AVZNativeCPU b = a;
        AGGuards ga = {.local = &a.pstate, .expected = {a.pstate}};
        AGGuards gb = {.local = &b.pstate, .expected = {b.pstate}};
        AVZNativeBlockResult ra = ag_run(fused, 8, &a, &ga);
        AVZNativeBlockResult rb = ag_run(plain, 8, &b, &gb);
        CHECK(ra.steps == 1 && ra.status == AVZ_TP_STATUS_REVALIDATE && a.pc == 0x8004);
        CHECK(rb.steps == ra.steps && rb.status == ra.status && !memcmp(&a, &b, sizeof(a)));
        cases++;
        ag_destroy(fused); ag_destroy(plain);
    }
    // Non-flag-setting subtraction must not use the NZCV forwarding path.
    uint32_t noncmp[] = {0xd1001c01, 0x54000020};
    AGProgram *p = ag_create(noncmp, 2, 0x8000);
    AGProgram *single = ag_create(noncmp, 1, 0x8000);
    CHECK(p && single && p->operations[0].handler == single->operations[0].handler);
    ag_destroy(single);
    ag_destroy(p);
    printf("assembly compare/branch fusion: %zu differential cases passed\n", cases);
    if (getenv("PINECONE_BENCHMARK_FUSION")) {
        const uint32_t loops[][2] = {
            {0xf1001c1f, 0x54ffffe1}, // cmp x0,#7; b.ne CMP
            {0xf1000000, 0x54ffffe0}, // subs x0,x0,#0; b.eq SUBS
            {0xeb01001f, 0x54ffffe1}, // cmp x0,x1; b.ne CMP
        };
        for (unsigned pattern = 0; pattern < sizeof(loops) / sizeof(*loops); pattern++) {
        const uint32_t *loop = loops[pattern];
        AGProgram *programs[] = {ag_create(loop, 2, 0x8000), ag_create(loop, 2, 0x8000)};
        CHECK(programs[0] && programs[1]);
        AGProgram *single = ag_create(loop, 1, 0x8000);
        CHECK(single);
        programs[0]->operations[0].handler = single->operations[0].handler;
        ag_destroy(single);
        uint64_t epoch = 0;
        AGGuards guards = {.local = &epoch};
        for (unsigned run = 0; run < 10; run++)
        for (unsigned order = 0; order < 2; order++) {
            unsigned fused = order ^ (run & 1);
            AVZNativeCPU cpu = {.pc = 0x8000};
            cpu.x[1] = 7;
            struct timespec start, end;
            clock_gettime(CLOCK_MONOTONIC, &start);
            AVZNativeBlockResult result = ag_run(programs[fused], 12000000, &cpu, &guards);
            clock_gettime(CLOCK_MONOTONIC, &end);
            CHECK(result.steps == 12000000 && cpu.pc == 0x8000 && cpu.x[0] == 0);
            double seconds = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) * 1e-9;
            printf("pattern=%u fusion=%u run=%u seconds=%.6f\n", pattern, fused, run, seconds);
        }
        ag_destroy(programs[0]); ag_destroy(programs[1]);
        }
    }
    return 0;
}
