#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wordexp.h>
#include "trace.h"

/* No GTK/GObject/GIO/trace-runtime dependency. Inherited shell preloads remain
 * libc-only. Optional PCEDIT1 integration is discovered, never loaded. */
typedef struct {
  uint64_t start, end, cpu_start, cpu_end;
  uintptr_t caller;
  size_t bytes, words;
  unsigned span;
  int flags, result;
} Record;
static Record records[256];
static unsigned used, dropped;
static int enabled;
static pid_t owner_pid;
static pthread_t owner_thread;
static int (*original)(const char *, wordexp_t *, int);
static PineconeTextScope (*begin_scope)(const char *, int);
static void (*end_scope)(PineconeTextScope *);

static uint64_t now(clockid_t clock)
{
  struct timespec ts;
  if (clock_gettime(clock, &ts)) return 0;
  return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void resolve(void)
{
  if (original) return;
  original = dlsym(RTLD_NEXT, "wordexp");
  if (!original) {
    const char message[] = "PCWORD1 missing wordexp\n";
    (void)write(2, message, sizeof message - 1);
    _exit(127);
  }
}

__attribute__((constructor)) static void initialize(void)
{
  int saved = errno;
  resolve();
  owner_pid = getpid();
  owner_thread = pthread_self();
  char exe[4096];
  ssize_t length = readlink("/proc/self/exe", exe, sizeof exe - 1);
  const char *opt = getenv("PINECONE_WORDEXP_TRACE");
  const char *target = getenv("PINECONE_WORDEXP_TRACE_EXE");
  if (!target) target = "gnome-text-editor";
  if (length >= 0 && (size_t)length < sizeof exe - 1 && opt && !strcmp(opt, "1")) {
    exe[length] = 0;
    const char *base = strrchr(exe, '/');
    enabled = strcmp(base ? base + 1 : exe, target) == 0;
  }
  if (enabled) {
    begin_scope = dlsym(RTLD_DEFAULT, "pinecone_text_begin");
    end_scope = dlsym(RTLD_DEFAULT, "pinecone_text_end");
  }
  errno = saved;
}

int wordexp(const char *words, wordexp_t *state, int flags)
{
  int saved = errno;
  resolve();
  Record *record = NULL;
  PineconeTextScope scope = {0, 0};
  if (enabled && getpid() == owner_pid && pthread_equal(owner_thread, pthread_self())) {
    if (used == sizeof records / sizeof records[0]) {
      dropped++;
    } else {
      record = &records[used++];
      record->caller = (uintptr_t)__builtin_return_address(0);
      record->bytes = words ? strlen(words) : 0;
      record->flags = flags;
      if (begin_scope && end_scope) scope = begin_scope("wordexp", 0);
      record->span = scope.id;
      record->start = now(CLOCK_MONOTONIC);
      record->cpu_start = now(CLOCK_THREAD_CPUTIME_ID);
    }
  }
  errno = saved;
  int result = original(words, state, flags);
  saved = errno;
  if (record) {
    record->cpu_end = now(CLOCK_THREAD_CPUTIME_ID);
    record->end = now(CLOCK_MONOTONIC);
    record->result = result;
    record->words = result == 0 ? state->we_wordc : 0;
    if (begin_scope && end_scope) end_scope(&scope);
  }
  errno = saved;
  return result;
}

__attribute__((destructor)) static void finish(void)
{
  if (!enabled || getpid() != owner_pid) return;
  fprintf(stderr, "PCWORD1 summary pid=%ld records=%u dropped=%u\n", (long)getpid(), used, dropped);
  for (unsigned i = 0; i < used; i++) {
    Record *r = &records[i];
    Dl_info info = {0};
    dladdr((void *)r->caller, &info);
    const char *module = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    module = module ? module + 1 : info.dli_fname;
    fprintf(stderr, "PCWORD1 call pid=%ld id=%u span=%u bytes=%zu flags=%d result=%d words=%zu "
        "start=%" PRIu64 " end=%" PRIu64 " cpu_start=%" PRIu64 " cpu_end=%" PRIu64
        " module=%s offset=0x%" PRIxPTR "\n", (long)getpid(), i + 1, r->span,
        r->bytes, r->flags, r->result, r->words, r->start, r->end, r->cpu_start, r->cpu_end,
        module ? module : "unknown", r->caller - (uintptr_t)info.dli_fbase);
  }
  fprintf(stderr, "PCWORD1 done pid=%ld\n", (long)getpid());
}
