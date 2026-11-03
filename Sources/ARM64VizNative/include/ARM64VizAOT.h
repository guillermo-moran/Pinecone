#ifndef ARM64VIZ_AOT_H
#define ARM64VIZ_AOT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Process-wide monotonic diagnostic counts. No reset while vCPUs are active. */
typedef struct {
    uint64_t compiled_blocks, bindings, runs, steps;
    uint64_t span_runs, span_steps;
} AVZNativeAOTStatistics;
AVZNativeAOTStatistics avz_native_aot_statistics(void);
#ifdef __cplusplus
}
#endif
#endif
