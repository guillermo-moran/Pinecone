#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Diagnostic only: never installed in the production rootfs. */
static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static uint64_t nanoseconds(clockid_t clock)
{
    struct timespec ts;
    if (clock_gettime(clock, &ts) != 0) fail("clock_gettime");
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void pin(unsigned cpu)
{
    cpu_set_t requested, actual;
    CPU_ZERO(&requested);
    CPU_SET(cpu, &requested);
    if (sched_setaffinity(0, sizeof(requested), &requested) != 0)
        fail("sched_setaffinity");
    CPU_ZERO(&actual);
    if (sched_getaffinity(0, sizeof(actual), &actual) != 0)
        fail("sched_getaffinity");
    if (CPU_COUNT(&actual) != 1 || !CPU_ISSET(cpu, &actual)) {
        fputs("affinity verification failed\n", stderr);
        exit(EXIT_FAILURE);
    }
}

static void bench(unsigned cpu, const char *kind)
{
    const size_t count = 1u << 18;
    volatile uint64_t *memory = NULL;
    if (strcmp(kind, "memory") == 0) {
        memory = calloc(count, sizeof(*memory));
        if (!memory) fail("calloc");
        for (size_t i = 0; i < count; ++i) memory[i] = i;
    } else if (strcmp(kind, "scalar") != 0) {
        fputs("workload must be scalar or memory\n", stderr);
        exit(EXIT_FAILURE);
    }

    printf("VCPU_BEGIN cpu=%u kind=%s pid=%ld\n", cpu, kind, (long)getpid());
    fflush(stdout);
    uint64_t wall = nanoseconds(CLOCK_MONOTONIC);
    uint64_t thread = nanoseconds(CLOCK_THREAD_CPUTIME_ID);
    uint64_t value = UINT64_C(0x123456789abcdef0);
    if (memory) {
        for (unsigned pass = 0; pass < 16; ++pass) {
            for (size_t i = 0; i < count; ++i) {
                value += memory[i];
                memory[i] = value ^ (value >> 17);
            }
        }
    } else {
        for (unsigned i = 0; i < 8000000; ++i) {
            value ^= value << 13;
            value ^= value >> 7;
            value ^= value << 17;
        }
    }
    uint64_t thread_elapsed = nanoseconds(CLOCK_THREAD_CPUTIME_ID) - thread;
    uint64_t wall_elapsed = nanoseconds(CLOCK_MONOTONIC) - wall;
    pin(cpu);
    printf("VCPU_END cpu=%u kind=%s wall_ns=%" PRIu64
           " guest_thread_ns=%" PRIu64 " checksum=%016" PRIx64 "\n",
           cpu, kind, wall_elapsed, thread_elapsed, value);
    free((void *)memory);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s CPU scalar|memory|--exec COMMAND [ARG...]\n", argv[0]);
        return EXIT_FAILURE;
    }
    char *end;
    errno = 0;
    unsigned long cpu = strtoul(argv[1], &end, 10);
    if (errno || *end || end == argv[1] || cpu >= CPU_SETSIZE) {
        fputs("invalid CPU\n", stderr);
        return EXIT_FAILURE;
    }
    pin((unsigned)cpu);
    if (strcmp(argv[2], "--exec") == 0) {
        if (argc < 4) return EXIT_FAILURE;
        printf("VCPU_EXEC cpu=%lu pid=%ld command=%s\n", cpu, (long)getpid(), argv[3]);
        fflush(stdout);
        execvp(argv[3], argv + 3);
        fail("execvp");
    }
    bench((unsigned)cpu, argv[2]);
    return EXIT_SUCCESS;
}
