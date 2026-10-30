#ifndef PINECONE_ASSEMBLY_SERVICE_CHAIN_H
#define PINECONE_ASSEMBLY_SERVICE_CHAIN_H
#include "gadget.h"

/* Additive native-service runtime. This is NOT the offline ag_chain_run API.
 * Default OFF: build this unit with AG_SERVICE_CHAIN_ENABLE=1 to test/use it.
 * No AGRun/result layout changes and no VM selection are required.
 * The enable definition must also be supplied when compiling gadget_arm64.S.
 * One assembly frame remains resident across visits, with an ordinary C ABI
 * service boundary and full revalidation before each private successor gate.
 * Memory helpers remain terminal; their final service runs after assembly exit.
 */
enum { AG_SERVICE_MAX_MEMBERS = 8, AG_SERVICE_MAX_BYTES = 32768 };
typedef struct AGServiceChain AGServiceChain;
typedef struct {
    const uint32_t *words;
    size_t count;
    uint64_t base;
    const uint64_t *serial;
    uint64_t expected_serial;
    const uint64_t *local_generation;
    uint64_t expected_local_generation;
    const _Atomic uint64_t *shared_generation;
    uint64_t expected_shared_generation;
} AGServiceBlock;

/* Mandatory, owner-only, bounded validation of the WHOLE original block,
 * never an interior-PC suffix. The owner certifies resident decoded identity,
 * physical-page enrollment, one physical code page, full context/reset/memory
 * binding, and absence of ordinary/mapped semantic candidates and barriers.
 * Must not fetch/decode speculative targets, refresh captured proofs, rebuild
 * graphs or invoke devices/Swift. A failure may retire the graph on the owner.
 * Called before/after copying and around service; raw opcode eligibility alone
 * cannot certify semantic admission. Inputs/tokens remain live during create.
 */
typedef int (*AGServiceValidate)(void *owner, uint64_t base, size_t count,
    uint64_t expected_serial);
/* Equivalent whole-graph certificate for owners that already retain the
 * immutable member list. Validate every member with the same contract above,
 * but check shared binding once instead of searching by PC for each member. */
typedef int (*AGServiceValidateGraph)(void *owner);

typedef enum {
    AG_SERVICE_CONTINUE = 0,
    AG_SERVICE_IRQ,
    AG_SERVICE_DEADLINE,
    AG_SERVICE_CHECKPOINT,
    AG_SERVICE_PREEMPT,
    AG_SERVICE_REVALIDATE
} AGServiceAction;
typedef struct {
    uint64_t retired_delta, total_steps, visits;
    uint32_t status;
    uint8_t initial;
} AGServiceBoundary;
typedef struct {
    uint64_t next_steps;
    AGServiceAction action;
} AGServiceDecision;

/* Called initially (delta 0), then after EVERY attempted assembly visit,
 * including partial budget, successful helper and fault exits. CPU/PC are
 * materialized. The callback MUST charge retired_delta exactly once using the
 * authoritative native advance_time, including shared-TLBI catch-up and IRQ /
 * timer checks. It must not charge total_steps, replay a helper, clear pending
 * fault data, change CPU state, or run a Swift/device checkpoint and continue.
 * Return CHECKPOINT/PREEMPT/etc. to leave this invocation for fresh selection.
 * next_steps is a newly computed timer/deadline/native-service allowance, not
 * an elapsed-time estimate; zero returns even with CONTINUE. Masked IRQ and
 * zero cycles/instruction must be handled by the native service owner.
 * The graph stays pinned; retirement is allowed, replacing/freeing CPU, RAM,
 * token storage, fast path or validation/service context is not. No longjmp
 * or exception may cross this call. No callback may recursively run the graph.
 */
typedef AGServiceDecision (*AGServiceCallback)(void *owner,
    const AGServiceBoundary *boundary, const AVZNativeCPU *cpu);
typedef struct {
    uint64_t steps, checkpoint_steps, visits, checkpoint_visits;
    const _Atomic uint64_t *events;
} AGServiceLimits;
typedef enum {
    AG_SERVICE_STOP_NONE = 0,
    AG_SERVICE_STOP_INVALID,
    AG_SERVICE_STOP_DISABLED,
    AG_SERVICE_STOP_STEPS,
    AG_SERVICE_STOP_VISITS,
    AG_SERVICE_STOP_CHECKPOINT,
    AG_SERVICE_STOP_ALLOWANCE,
    AG_SERVICE_STOP_CALLBACK,
    AG_SERVICE_STOP_EVENT,
    AG_SERVICE_STOP_PROOF,
    AG_SERVICE_STOP_OUTSIDE,
    AG_SERVICE_STOP_EXECUTOR,
    AG_SERVICE_STOP_PREPARATION
} AGServiceStop;
typedef struct {
    AVZNativeBlockResult architectural;
    uint64_t visits, timer_accounted_steps;
    uint64_t last_member_base, last_member_serial;
    AGServiceStop stop;
    AGServiceAction service_action;
    uint8_t has_last_member;
} AGServiceResult;

/* Strict immutable snapshots, sorted/disjoint, <=16 instructions/member,
 * single virtual code page, branch only last. Copies do not mutate FIFO AGPrograms.
 * At least one generation token and a serial token per member are required;
 * owner-local tokens are ordinary uint64_t, NEVER cast to atomics. proof requires
 * local + shared[0] code + shared[1] translation/context; shared[2] is optional.
 * Captured values are never refreshed, even for unrelated code writes.
 * memory binding is fixed (NULL permits register-only members). The validate
 * context must reject changed reset/key/context/physical mapping or enrollment.
 * Peers may publish shared epochs/events only. Owner must retire this graph
 * BEFORE recycling/untracking any resident dependency, and quiesce before RAM,
 * cache/token destruction or generation reuse/wrap. Pinning alone is not code
 * enrollment. Maintain at most one published graph per vCPU, no replacement
 * while active; allocation bounds here apply to ONE graph, not all callers.
 * Bounded programs are prepared transactionally once, while inactive, on the
 * first bounded call. They clone decoded private copies without decoding again.
 * Allocation failure leaves generic execution usable and can be retried. On the
 * supported 64-bit ABI the chain is 13,928 bytes; each maximum-size program is
 * 856 bytes. Eight 16-instruction members total 20,776 bytes before preparation
 * and 27,624 after, below 32 KiB (requested bytes, excluding allocator metadata).
 * ag_service_chain_bytes grows only on successful preparation; owners caching
 * this value must refresh it after bounded calls. Inline gate storage accounts
 * for the generic-only increase from 13,992 bytes. Ordinary AGPrograms,
 * AGRun/AGChainControl layouts and hot handlers are unchanged.
 */
AGServiceChain *ag_service_chain_create(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidate validate, void *owner);
AGServiceChain *ag_service_chain_create_graph(const AGServiceBlock *blocks, size_t count,
    const AGGuards *proof, AVZNativeMemoryFastPath *memory,
    AGServiceValidateGraph validate, void *owner);
void ag_service_chain_destroy(AGServiceChain *chain);
size_t ag_service_chain_bytes(const AGServiceChain *chain);
AGServiceResult ag_service_chain_run(AGServiceChain *chain, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner);

/* Bounded production contract, deliberately NOT the every-visit contract above.
 * One assembly entry keeps the minimum of initial next_steps, steps and
 * checkpoint_steps resident across linked members. Visits/checkpoint_visits
 * count admitted suffixes, including a first-instruction fault; rejected gates
 * and zero-retirement pre-helper service stops do not admit a visit.
 * Service runs initially, before any slow memory/device helper, and finally
 * after assembly exits. retired_delta is the uncharged cumulative prefix, not
 * the last member's length. A pre-helper service may have delta zero. Final
 * service still runs with delta zero after a fault or a pre-helper rejection.
 * No callback occurs at ordinary block edges or renews an exhausted allowance.
 * A pre-helper CONTINUE with positive next_steps permits exactly one helper,
 * only after full validation and event checks. It never extends the original
 * allowance. Successful helpers and completed inline code-store publication
 * are terminal REVALIDATE exits; faults retain precedence over service/proof
 * stops. Publication/writeback of an already performed store cannot be vetoed.
 * Owner state/proofs/memory bindings MUST NOT mutate between service callbacks,
 * except inside a terminal helper/publication. Peers may publish atomic tokens
 * or events. Every edge checks ALL member serial/page tokens and global guards;
 * the full owner validator runs on entry and after every service, including the
 * final service. Memory preparation occurs once, never at ordinary edges.
 * The graph remains pinned through final service/validation. Recursive use is
 * rejected. No side effect is replayed. The generic API is unchanged.
 * Preparation allocation failure returns REVALIDATE/STOP_PREPARATION with zero
 * steps/visits and no service calls, without changing CPU or retiring the graph.
 */
AGServiceResult ag_service_chain_run_bounded(AGServiceChain *chain, AGServiceLimits limits,
    AVZNativeCPU *cpu, AGServiceCallback service, void *owner);

/* Limits must be positive: zero is never unlimited. Each admitted suffix is
 * capped to its remaining decoded length, so internal/self loops cannot hide
 * visits. Pre-entry proof/event/allowance rejection admits no visit; a fault on
 * the first instruction admits one visit but retires zero instructions.
 * Timer-accounted steps report the callback's contractual charge, not telemetry.
 * Outer native integration must charge ONLY architectural.steps minus this
 * value. Fault/unsupported/halted/helper revalidation wins over coincident
 * service stops. Last-member values are snapshots, never permission to reuse
 * an entry without revalidation. Events are polled, never acknowledged here.
 */
#endif
