/* Isolate bounded edge-proof scaling: the executed loop is identical while
 * the number of retained (otherwise unused) graph members changes. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../Sources/ARM64VizNative/ARM64VizNative.c"
#include "../Sources/ARM64VizNative/Assembly/service_chain.h"
#include "../Sources/ARM64VizNative/Assembly/gadget_internal.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); abort(); } } while (0)
typedef struct { uint64_t charged, calls; } Owner;
static uint64_t *mutate_local;
static _Atomic uint64_t *mutate_shared;
static unsigned expand_duplicate_proofs;
/* Mutation after the final C validation exercises the live assembly gate,
 * rather than relying on the runtime's entry validator to reject staleness. */
void proof_benchmark_enter(AGRun *run) {
    if (mutate_local) { *mutate_local = 2; mutate_local = NULL; }
    if (mutate_shared) { atomic_store(mutate_shared, 2); mutate_shared = NULL; }
    AGBoundedControl *control = (AGBoundedControl *)run->chain;
    const AGBoundedProof *original = control->proofs;
    AGBoundedProof copies[8];
    CHECK(control->count <= 8);
    memcpy(copies, original, control->count * sizeof(*copies));
    // Same-binary timing control: restore redundant same-page reads only in
    // the private run snapshot. Every serial and distinct token is unchanged.
    if (expand_duplicate_proofs) for (size_t i = 1; i < control->count; i++) {
        copies[i].local_generation = copies[0].local_generation;
        copies[i].expected_local_generation = copies[0].expected_local_generation;
        copies[i].shared_generation = copies[0].shared_generation;
        copies[i].expected_shared_generation = copies[0].expected_shared_generation;
    }
    control->proofs = copies;
    ag_enter(run);
    control->proofs = original;
}
static int validate_graph(void *owner) { (void)owner; return 1; }
static AGServiceDecision service(void *opaque, const AGServiceBoundary *b,
    const AVZNativeCPU *cpu) {
    (void)cpu;
    Owner *o = opaque;
    o->charged += b->retired_delta;
    o->calls++;
    return (AGServiceDecision){.next_steps = 4096, .action = AG_SERVICE_CONTINUE};
}
static uint64_t thread_ns(void) {
    struct timespec ts;
    CHECK(!clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts));
    return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
int main(void) {
    int shared_tokens = getenv("PINECONE_BENCHMARK_SHARED_PAGE") != NULL;
    uint64_t local = 1, serial[8], page[8];
    _Atomic uint64_t code = 1, translation = 1, shared_page[8];
    AGGuards proof = {.local = &local, .shared = {&code, &translation},
        .expected = {1, 1, 1}};
    AGServiceChain *graphs[4][4];
    Owner owners[4][4] = {0};
    const unsigned members[] = {1, 2, 4, 8}, lengths[] = {2, 4, 8, 16};
    for (unsigned l = 0; l < 4; l++) for (unsigned n = 0; n < 4; n++) {
        AGServiceBlock blocks[8];
        uint32_t words[8][16];
        for (unsigned i = 0; i < members[n]; i++) {
            serial[i] = page[i] = 1;
            atomic_init(&shared_page[i], 1);
            for (unsigned j = 0; j < lengths[l] - 1; j++) words[i][j] = 0x91000400;
            // Self-loop; every graph runs member zero exclusively.
            words[i][lengths[l] - 1] = 0x14000000 |
                ((uint32_t)(1 - (int)lengths[l]) & 0x3ffffff);
            blocks[i] = (AGServiceBlock){.words = words[i], .count = lengths[l],
                .base = 0x1000 + i * 0x1000, .serial = &serial[i], .expected_serial = 1,
                .local_generation = &page[shared_tokens ? 0 : i], .expected_local_generation = 1,
                .shared_generation = &shared_page[shared_tokens ? 0 : i], .expected_shared_generation = 1};
        }
        graphs[l][n] = ag_service_chain_create_graph(blocks, members[n], &proof,
            NULL, validate_graph, &owners[l][n]);
        CHECK(graphs[l][n]);
        // Aliasing token pointers with inconsistent expected values cannot
        // produce an admissible graph, in either local or shared role.
        if (shared_tokens && members[n] > 1) {
            blocks[1].expected_local_generation = 2;
            CHECK(!ag_service_chain_create_graph(blocks, members[n], &proof,
                NULL, validate_graph, &owners[l][n]));
            blocks[1].expected_local_generation = 1;
            blocks[1].expected_shared_generation = 2;
            CHECK(!ag_service_chain_create_graph(blocks, members[n], &proof,
                NULL, validate_graph, &owners[l][n]));
            blocks[1].expected_shared_generation = 1;
        }
        // Includes lazy preparation outside timing.
        AVZNativeCPU cpu = {.pc = 0x1000};
        AGServiceLimits limits = {4096, 4096, 4096, 4096, NULL};
        AGServiceResult r = ag_service_chain_run_bounded(graphs[l][n], limits,
            &cpu, service, &owners[l][n]);
        CHECK(r.architectural.steps == 4096 && r.visits == 4096 / lengths[l]);
        // Staleness of an unexecuted member still rejects the whole graph.
        for (unsigned i = 0; i < members[n]; i++) {
            unsigned token = shared_tokens ? 0 : i;
            atomic_store(&shared_page[token], 2);
            cpu = (AVZNativeCPU){.pc = 0x1000};
            r = ag_service_chain_run_bounded(graphs[l][n], limits, &cpu,
                service, &owners[l][n]);
            CHECK(r.architectural.steps == 0 && r.stop == AG_SERVICE_STOP_PROOF);
            atomic_store(&shared_page[token], 1);
            for (unsigned kind = 0; kind < 3; kind++) {
                if (kind == 0) mutate_shared = &shared_page[token];
                else mutate_local = kind == 1 ? &page[token] : &serial[i];
                cpu = (AVZNativeCPU){.pc = 0x1000};
                r = ag_service_chain_run_bounded(graphs[l][n], limits, &cpu,
                    service, &owners[l][n]);
                CHECK(!mutate_local && !mutate_shared);
                CHECK(r.architectural.steps == 0 && r.stop == AG_SERVICE_STOP_PROOF);
                atomic_store(&shared_page[token], 1);
                page[token] = serial[i] = 1;
            }
        }
    }
    puts("PASS all-member stale-page rejection, including unexecuted members");
    for (unsigned round = 0; round < 8; round++)
    for (unsigned l = 0; l < 4; l++) for (unsigned order = 0; order < 4; order++)
    for (unsigned comparison = 0; comparison < (shared_tokens ? 2u : 1u); comparison++) {
        unsigned n = (order + round) % 4;
        expand_duplicate_proofs = shared_tokens && (comparison ^ (round & 1));
        Owner *o = &owners[l][n];
        uint64_t before_calls = o->calls, before_charge = o->charged;
        uint64_t retired = 0, visits = 0;
        AVZNativeCPU cpu = {.pc = 0x1000};
        AGServiceLimits limits = {4096, 4096, 4096, 4096, NULL};
        uint64_t start = thread_ns();
        for (unsigned slice = 0; slice < 256; slice++) {
            AGServiceResult r = ag_service_chain_run_bounded(graphs[l][n], limits,
                &cpu, service, o);
            CHECK(r.architectural.steps == 4096 && r.visits == 4096 / lengths[l]);
            CHECK(r.timer_accounted_steps == 4096 && r.stop == AG_SERVICE_STOP_STEPS);
            retired += r.architectural.steps;
            visits += r.visits;
        }
        uint64_t elapsed = thread_ns() - start;
        CHECK(o->calls - before_calls == 512 && o->charged - before_charge == retired);
        CHECK(cpu.pc == 0x1000 && cpu.x[0] == retired - visits);
        printf("round=%u length=%u members=%u redundant=%u ns_per_instruction=%.4f\n",
            round, lengths[l], members[n], expand_duplicate_proofs, (double)elapsed / retired);
    }
    for (unsigned l = 0; l < 4; l++) for (unsigned n = 0; n < 4; n++)
        ag_service_chain_destroy(graphs[l][n]);
    return 0;
}
