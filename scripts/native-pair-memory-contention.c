#define _POSIX_C_SOURCE 200809L
#include "ARM64VizGuestMemoryInternal.h"
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned ready;
    int start;
} Gate;

typedef struct {
    Gate *gate;
    AVZGuestMemory *memory;
    uint64_t iterations;
    uint64_t mismatch;
    int writer;
} Worker;

static void *work(void *opaque) {
    Worker *worker = opaque;
    Gate *gate = worker->gate;
    CHECK(pthread_mutex_lock(&gate->mutex) == 0);
    gate->ready++;
    CHECK(pthread_cond_broadcast(&gate->condition) == 0);
    while (!gate->start) CHECK(pthread_cond_wait(&gate->condition, &gate->mutex) == 0);
    CHECK(pthread_mutex_unlock(&gate->mutex) == 0);

    uint64_t mismatch = 0;
    if (worker->writer) {
        // Model exactly the ticket RMW, not a guest write or exclusive store.
        for (uint64_t i = 0; i < worker->iterations; i++) {
            uint64_t ticket = atomic_fetch_add_explicit(
                &worker->memory->current_write_generation, 1, memory_order_acq_rel);
            mismatch |= ticket ^ (i + 1);
        }
    } else {
        for (uint64_t i = 0; i < worker->iterations; i++) {
            uint64_t epoch = atomic_load_explicit(
                &worker->memory->code_mutation_epoch, memory_order_acquire);
            mismatch |= epoch ^ UINT64_C(1);
        }
    }
    worker->mismatch = mismatch;
    return NULL;
}

static uint64_t nanos(void) {
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static void check_memory(AVZGuestMemory *memory, uint64_t ticket) {
    CHECK(atomic_load_explicit(&memory->current_write_generation, memory_order_acquire) == ticket);
    CHECK(atomic_load_explicit(&memory->code_mutation_epoch, memory_order_acquire) == 1);
    CHECK(avz_guest_memory_code_mutation_epoch(memory) == 1);
    CHECK(avz_guest_memory_code_mutation_epoch_token(memory) ==
        (const uint64_t *)&memory->code_mutation_epoch);
    CHECK(atomic_load_explicit(&memory->translation_epoch, memory_order_acquire) == 1);
}

static void exercise(unsigned mode, uint64_t iterations, int timed) {
    const char *names[] = {"epoch-reader", "ticket-writer", "epoch-ticket-shared", "epoch-ticket-separate"};
    AVZGuestMemory *first = avz_guest_memory_create(4096);
    AVZGuestMemory *second = mode == 3 ? avz_guest_memory_create(4096) : NULL;
    CHECK(first && (mode != 3 || second));
    check_memory(first, 1);
    if (second) check_memory(second, 1);
    Gate gate = {0};
    CHECK(pthread_mutex_init(&gate.mutex, NULL) == 0);
    CHECK(pthread_cond_init(&gate.condition, NULL) == 0);
    Worker workers[2] = {
        {.gate = &gate, .memory = first, .iterations = iterations, .writer = mode == 1},
        {.gate = &gate, .memory = second ? second : first, .iterations = iterations, .writer = 1}
    };
    unsigned count = mode < 2 ? 1 : 2;
    pthread_t threads[2];
    for (unsigned i = 0; i < count; i++) CHECK(pthread_create(&threads[i], NULL, work, &workers[i]) == 0);
    CHECK(pthread_mutex_lock(&gate.mutex) == 0);
    while (gate.ready != count) CHECK(pthread_cond_wait(&gate.condition, &gate.mutex) == 0);
    uint64_t start = timed ? nanos() : 0;
    gate.start = 1;
    CHECK(pthread_cond_broadcast(&gate.condition) == 0);
    CHECK(pthread_mutex_unlock(&gate.mutex) == 0);
    for (unsigned i = 0; i < count; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    uint64_t elapsed = timed ? nanos() - start : 0;
    for (unsigned i = 0; i < count; i++) CHECK(workers[i].mismatch == 0);
    uint64_t final_ticket = mode == 0 ? 1 : iterations + 1;
    check_memory(first, mode == 1 || mode == 2 ? final_ticket : 1);
    if (second) check_memory(second, final_ticket);
    CHECK(pthread_cond_destroy(&gate.condition) == 0);
    CHECK(pthread_mutex_destroy(&gate.mutex) == 0);
    if (timed) {
        printf("workload=%s steps=%" PRIu64 " threads=%u ns=%" PRIu64
            " epoch=1 final_ticket=%" PRIu64 " mismatch=0\n",
            names[mode], iterations, count, elapsed, final_ticket);
    }
    avz_guest_memory_destroy(second);
    avz_guest_memory_destroy(first);
}

static void layout(void) {
    AVZGuestMemory *memory = avz_guest_memory_create(4096);
    CHECK(memory);
    uintptr_t ticket = (uintptr_t)&memory->current_write_generation;
    uintptr_t epoch = (uintptr_t)&memory->code_mutation_epoch;
    uintptr_t translation = (uintptr_t)&memory->translation_epoch;
    printf("size=%zu alignment=%zu ticket_offset=%zu code_offset=%zu translation_offset=%zu"
        " allocation_mod128=%" PRIuPTR " ticket_code_share64=%d ticket_code_share128=%d"
        " code_translation_share128=%d\n",
        sizeof(*memory), _Alignof(AVZGuestMemory),
        offsetof(AVZGuestMemory, current_write_generation),
        offsetof(AVZGuestMemory, code_mutation_epoch), offsetof(AVZGuestMemory, translation_epoch),
        (uintptr_t)memory % 128, ticket / 64 == epoch / 64, ticket / 128 == epoch / 128,
        epoch / 128 == translation / 128);
    avz_guest_memory_destroy(memory);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--layout")) { layout(); return 0; }
    int timed = argc == 3 && !strcmp(argv[1], "--benchmark");
    CHECK(argc == 1 || timed);
    uint64_t iterations = 50000;
    if (timed) {
        char *end = NULL;
        errno = 0;
        iterations = strtoull(argv[2], &end, 10);
        CHECK(errno == 0 && end != argv[2] && *end == '\0');
        CHECK(iterations >= 1024 && iterations <= UINT64_C(1000000000));
    }
    for (unsigned mode = 0; mode < 4; mode++) exercise(mode, iterations, timed);
    if (!timed) printf("PASS contention cases=4 iterations=%" PRIu64
        " reader_checks=%" PRIu64 " ticket_updates=%" PRIu64
        " epoch=1 writer_final_ticket=%" PRIu64 " mismatch=0\n",
        iterations, iterations * 3, iterations * 3, iterations + 1);
    return 0;
}
