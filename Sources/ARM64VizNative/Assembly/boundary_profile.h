#ifndef PINECONE_BOUNDARY_PROFILE_H
#define PINECONE_BOUNDARY_PROFILE_H

/* Harness-only attribution. Production builds contain no clocks or counters.
 * Samples use host ticks, not CPU time: discard interrupted/outlier samples
 * when interpreting them, and use the uninstrumented cost screen for gates. */
#if defined(AG_BOUNDARY_PROFILE) && AG_BOUNDARY_PROFILE
#include <stdint.h>
#include <mach/mach_time.h>
enum {
    AG_PROFILE_ACCOUNTING, AG_PROFILE_TLBI, AG_PROFILE_TIMER,
    AG_PROFILE_ADVANCE_TIME, AG_PROFILE_ALLOWANCE,
    AG_PROFILE_CALLBACK, AG_PROFILE_VALIDATION, AG_PROFILE_SELECTION,
    AG_PROFILE_MEMORY, AG_PROFILE_STAGE_COUNT
};
typedef struct {
    uint64_t boundaries, samples, stamp;
    uint64_t ticks[AG_PROFILE_STAGE_COUNT];
    uint64_t counts[AG_PROFILE_STAGE_COUNT];
    uint32_t random;
    unsigned active;
} AGBoundaryProfile;
extern _Thread_local AGBoundaryProfile ag_boundary_profile;
static inline void ag_profile_begin(void) {
    AGBoundaryProfile *p = &ag_boundary_profile;
    /* Fixed reproducible PRNG avoids phase-locking to alternating members. */
    uint32_t x = p->random ? p->random : UINT32_C(0x91e10da5);
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    p->random = x;
    p->boundaries++;
    p->active = (x & 1023u) == 0;
    if (p->active) { p->samples++; p->stamp = mach_absolute_time(); }
}
static inline void ag_profile_mark(unsigned stage) {
    AGBoundaryProfile *p = &ag_boundary_profile;
    if (!p->active) return;
    uint64_t now = mach_absolute_time();
    p->ticks[stage] += now - p->stamp;
    p->counts[stage]++;
    p->stamp = now;
}
static inline void ag_profile_end(void) { ag_boundary_profile.active = 0; }
#else
#define ag_profile_begin() ((void)0)
#define ag_profile_mark(stage) ((void)0)
#define ag_profile_end() ((void)0)
#endif
#endif
