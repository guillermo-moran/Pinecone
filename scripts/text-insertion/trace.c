#define _POSIX_C_SOURCE 200809L
#include "trace.h"
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef PC_TEXT_CAPACITY
#define PC_TEXT_CAPACITY 16384
#endif

typedef struct {
  const char *name;
  unsigned parent, edit, complete;
  uint64_t start, end, cpu_start, cpu_end;
} Record;

/* Only the loader/main thread records. No locks, allocation or I/O on edits. */
static Record records[PC_TEXT_CAPACITY];
static pthread_t owner;
static unsigned enabled, used, current, edits, dropped, limited;

static uint64_t now(clockid_t clock)
{
  struct timespec ts;
  if (clock_gettime(clock, &ts) != 0)
    return 0;
  return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

__attribute__((constructor)) static void initialize(void)
{
  int saved = errno;
  const char *value = getenv("PINECONE_TEXT_INSERTION_TRACE");
  owner = pthread_self();
  enabled = value && strcmp(value, "1") == 0;
  errno = saved;
}

PineconeTextScope pinecone_text_begin(const char *name, int edit_root)
{
  int saved = errno;
  PineconeTextScope scope = {0, 0};
  if (!enabled || !pthread_equal(owner, pthread_self()))
    return scope;
  if (!current) {
    if (!edit_root)
      return scope;
    if (edits == 256) {
      limited++;
      return scope;
    }
    edits++;
  }
  if (used == PC_TEXT_CAPACITY) {
    dropped++;
    return scope;
  }
  scope.id = ++used;
  scope.parent = current;
  Record *record = &records[scope.id - 1];
  record->name = name;
  record->parent = current;
  record->edit = edits;
  current = scope.id;
  record->start = now(CLOCK_MONOTONIC);
  record->cpu_start = now(CLOCK_THREAD_CPUTIME_ID);
  errno = saved;
  return scope;
}

void pinecone_text_end(PineconeTextScope *scope)
{
  int saved = errno;
  if (scope->id) {
    Record *record = &records[scope->id - 1];
    record->cpu_end = now(CLOCK_THREAD_CPUTIME_ID);
    record->end = now(CLOCK_MONOTONIC);
    record->complete = 1;
    current = scope->parent;
  }
  errno = saved;
}

/* Graceful process exit only. A crash/kill is explicitly an incomplete capture. */
__attribute__((destructor)) static void finish(void)
{
  if (!enabled)
    return;
  fprintf(stderr, "PCEDIT1 summary pid=%ld records=%u edits=%u dropped=%u limited=%u\n",
          (long)getpid(), used, edits, dropped, limited);
  for (unsigned i = 0; i < used; i++) {
    const Record *r = &records[i];
    fprintf(stderr, "PCEDIT1 span pid=%ld id=%u parent=%u edit=%u name=%s "
            "start=%" PRIu64 " end=%" PRIu64 " cpu_start=%" PRIu64
            " cpu_end=%" PRIu64 " complete=%u\n",
            (long)getpid(), i + 1, r->parent, r->edit, r->name,
            r->start, r->end, r->cpu_start, r->cpu_end, r->complete);
  }
  fprintf(stderr, "PCEDIT1 done pid=%ld\n", (long)getpid());
}
