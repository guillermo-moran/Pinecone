#ifndef PINECONE_GTK_FRAME_PROFILE_H
#define PINECONE_GTK_FRAME_PROFILE_H

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* Diagnostic accounting only: no allocation, pixel access, or I/O in marks.
 * Reentrant calls of one stage count once in its inclusive duration. Different
 * stages can overlap and must never be summed as exclusive CPU attribution. */
enum { PC_FRAME_STAGE_COUNT = 10 };
static const char *const pc_frame_names[PC_FRAME_STAGE_COUNT] = {
    "frame", "update", "layout", "paint", "gsk_diff",
    "cairo_begin", "cairo_draw", "cairo_end", "texture_diff", "texture_download"
};
struct pc_frame_stage {
    uint64_t calls, wall_start, cpu_start, wall_ns, thread_ns;
    unsigned depth;
};
struct pc_frame_profile {
    struct pc_frame_stage stages[PC_FRAME_STAGE_COUNT];
    uint64_t frame, seq_begin, mono_begin_ns, mono_end_ns;
    unsigned marks;
    int active, valid, ready;
};
static _Thread_local struct pc_frame_profile pc_frame;

static uint64_t pc_frame_clock(clockid_t clock)
{
    struct timespec t;
    if (clock_gettime(clock, &t)) return 0;
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static void pc_frame_mark_at(const char *name, int entering,
                             uint64_t wall, uint64_t cpu)
{
    if (!pc_frame.active) return;
    unsigned i;
    for (i = 0; i < PC_FRAME_STAGE_COUNT; ++i)
        if (strcmp(name, pc_frame_names[i]) == 0) break;
    if (i == PC_FRAME_STAGE_COUNT || !wall || !cpu) {
        pc_frame.valid = 0;
        return;
    }
    struct pc_frame_stage *s = &pc_frame.stages[i];
    if (entering) {
        ++s->calls;
        if (s->depth++ == 0) {
            s->wall_start = wall;
            s->cpu_start = cpu;
        }
    } else if (s->depth == 0) {
        pc_frame.valid = 0;
    } else if (--s->depth == 0) {
        if (wall < s->wall_start || cpu < s->cpu_start) {
            pc_frame.valid = 0;
            return;
        }
        s->wall_ns += wall - s->wall_start;
        s->thread_ns += cpu - s->cpu_start;
    }
}

static void pc_frame_mark(const char *name, int entering)
{
    if (!pc_frame.active) return;
    if (pc_frame.marks >= 8192) {
        pc_frame.valid = 0;
        return;
    }
    ++pc_frame.marks;
    uint64_t wall = pc_frame_clock(CLOCK_MONOTONIC);
    uint64_t cpu = pc_frame_clock(CLOCK_THREAD_CPUTIME_ID);
    pc_frame_mark_at(name, entering, wall, cpu);
}

static void pc_frame_begin(uint64_t frame, uint64_t sequence)
{
    int interrupted = pc_frame.active;
    memset(&pc_frame, 0, sizeof pc_frame);
    pc_frame.active = 1;
    pc_frame.valid = !interrupted;
    pc_frame.frame = frame;
    pc_frame.seq_begin = sequence;
    pc_frame_mark("frame", 1);
    pc_frame.mono_begin_ns = pc_frame.stages[0].wall_start;
}

static void pc_frame_stop(void)
{
    if (!pc_frame.active) return;
    pc_frame_mark("frame", 0);
    pc_frame.mono_end_ns = pc_frame.stages[0].wall_start + pc_frame.stages[0].wall_ns;
    pc_frame.active = 0;
    pc_frame.ready = 1;
    for (unsigned i = 0; i < PC_FRAME_STAGE_COUNT; ++i)
        if (pc_frame.stages[i].depth) pc_frame.valid = 0;
}

/* One bounded record after the timing endpoint. A failed/partial write can
 * only lose a record, never block midway through a measured render stage. */
static size_t pc_frame_finish(char *out, size_t capacity, long pid, uint64_t sequence)
{
    pc_frame_stop();
    if (!pc_frame.ready) return 0;
    pc_frame.ready = 0;
    int n = snprintf(out, capacity,
        "PINECONE_GTK_FRAME {\"version\":1,\"pid\":%ld,\"frame\":%" PRIu64
        ",\"seqBegin\":%" PRIu64 ",\"seqEnd\":%" PRIu64
        ",\"beginNs\":%" PRIu64 ",\"endNs\":%" PRIu64
        ",\"valid\":%d,\"stages\":{", pid, pc_frame.frame,
        pc_frame.seq_begin, sequence, pc_frame.mono_begin_ns,
        pc_frame.mono_end_ns, pc_frame.valid);
    if (n < 0 || (size_t)n >= capacity) return 0;
    size_t used = (size_t)n;
    for (unsigned i = 0; i < PC_FRAME_STAGE_COUNT; ++i) {
        const struct pc_frame_stage *s = &pc_frame.stages[i];
        n = snprintf(out + used, capacity - used,
            "%s\"%s\":{\"calls\":%" PRIu64 ",\"wallNs\":%" PRIu64
            ",\"threadNs\":%" PRIu64 "}", i ? "," : "",
            pc_frame_names[i], s->calls, s->wall_ns, s->thread_ns);
        if (n < 0 || (size_t)n >= capacity - used) return 0;
        used += (size_t)n;
    }
    n = snprintf(out + used, capacity - used, "}}\n");
    if (n < 0 || (size_t)n >= capacity - used) return 0;
    return used + (size_t)n;
}
#endif
