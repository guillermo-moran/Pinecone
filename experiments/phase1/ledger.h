#ifndef PHASE1_LEDGER_H
#define PHASE1_LEDGER_H
#include <stdint.h>
#include <string.h>
#include "ARM64VizThreadedPrototype.h"
enum { P1_STATUS_COUNT = 9 };
static inline int phase1_status_index(unsigned status) {
    switch (status) {
    case AVZ_NATIVE_STATUS_OUTSIDE_BLOCK: return 0;
    case AVZ_NATIVE_STATUS_HALTED: return 1;
    case AVZ_NATIVE_STATUS_UNSUPPORTED: return 2;
    case AVZ_NATIVE_STATUS_MAX_STEPS: return 3;
    case AVZ_NATIVE_STATUS_YIELDED: return 4;
    case AVZ_TP_STATUS_DISABLED: return 5;
    case AVZ_TP_STATUS_INVALID_ARGUMENT: return 6;
    case AVZ_TP_STATUS_REVALIDATE: return 7;
    case AVZ_TP_STATUS_MEMORY_FAULT: return 8;
    default: return -1;
    }
}
static const char *const phase1_status_names[P1_STATUS_COUNT] = {
    "outside_block", "halted", "unsupported", "max_steps", "yielded",
    "disabled", "invalid_argument", "revalidate", "memory_fault"
};
typedef struct {
    uint64_t chain_entries, established_entries, prototype_entries;
    uint64_t eligibility_lookups, program_lookups, program_creations, validations;
    uint64_t hot_reads, hot_writes, full_reads, full_writes, commit_calls, translation_callbacks;
    uint64_t prototype_steps, statuses[P1_STATUS_COUNT];
    uint64_t requested[4097], limits[4097], executed[4097];
} Phase1Ledger;
#ifdef P1_LEDGER
extern Phase1Ledger phase1_ledger;
#define P1_COUNT(field) (++phase1_ledger.field)
static inline void phase1_record(uint64_t requested, uint64_t limit, uint64_t steps, unsigned status) {
    int index = phase1_status_index(status);
    if (requested > 4096 || limit > requested || steps > limit || index < 0) __builtin_trap();
    phase1_ledger.prototype_steps += steps;
    phase1_ledger.requested[requested]++;
    phase1_ledger.limits[limit]++;
    phase1_ledger.executed[steps]++;
    phase1_ledger.statuses[index]++;
}
#define P1_RECORD(requested, limit, steps, status) phase1_record(requested, limit, steps, status)
#else
#define P1_COUNT(field) ((void)0)
#define P1_RECORD(requested, limit, steps, status) ((void)0)
#endif
#endif
