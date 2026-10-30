#include "ledger.h"
#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
Phase1Ledger phase1_ledger;
int main(void) {
    const unsigned values[P1_STATUS_COUNT] = {
        AVZ_NATIVE_STATUS_OUTSIDE_BLOCK, AVZ_NATIVE_STATUS_HALTED,
        AVZ_NATIVE_STATUS_UNSUPPORTED, AVZ_NATIVE_STATUS_MAX_STEPS,
        AVZ_NATIVE_STATUS_YIELDED, AVZ_TP_STATUS_DISABLED,
        AVZ_TP_STATUS_INVALID_ARGUMENT, AVZ_TP_STATUS_REVALIDATE,
        AVZ_TP_STATUS_MEMORY_FAULT
    };
    for (unsigned i = 0; i < P1_STATUS_COUNT; ++i) {
        assert(phase1_status_index(values[i]) == (int)i);
        phase1_record(4096, 4, 1, values[i]);
        assert(phase1_ledger.statuses[i] == 1);
    }
    assert(phase1_ledger.prototype_steps == P1_STATUS_COUNT);
    assert(phase1_status_index(42) == -1);
    pid_t child = fork(); assert(child >= 0);
    if (child == 0) { phase1_record(4, 4, 1, 42); _exit(1); }
    int status = 0; assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status));
    puts("PASS nine explicit statuses including REVALIDATE/MEMORY_FAULT; unknown status traps");
    return 0;
}
