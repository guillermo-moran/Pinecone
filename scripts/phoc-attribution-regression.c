/* Compile the actual patched trace implementation with controlled clocks/UART. */
#include <glib.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static gint64 wall_us = 1000000, cpu_us = 1000;
static unsigned cpu_reads, trace_writes, control_writes, short_write;
static gboolean cpu_unavailable;
static GString *captured;
static gint64 test_monotonic(void) { return wall_us; }
static int test_clock_gettime(clockid_t clock, struct timespec *time) {
  g_assert_cmpint(clock, ==, CLOCK_THREAD_CPUTIME_ID);
  ++cpu_reads;
  if (cpu_unavailable) return -1;
  *time = (struct timespec){ cpu_us / G_USEC_PER_SEC, (cpu_us % G_USEC_PER_SEC) * 1000 };
  return 0;
}
static int test_open(const char *path, int flags, ...) {
  g_assert_cmpstr(path, ==, "/dev/ttyAMA0");
  g_assert_true((flags & O_NONBLOCK) != 0);
  return 23;
}
static ssize_t test_write(int fd, const void *data, size_t size) {
  g_assert_cmpint(fd, ==, 23);
  g_assert_cmpuint(size, <, 2048);
  g_assert_cmpint(((const char *)data)[0], ==, 0x1e);
  if (g_str_has_prefix(data, "\036PINECONE_TRACE ")) ++trace_writes;
  else ++control_writes;
  size_t count = short_write ? MIN(size, 17) : size;
  g_string_append_len(captured, data, count);
  return count;
}
#define open test_open
#define write test_write
#define g_get_monotonic_time test_monotonic
#define clock_gettime test_clock_gettime
#include "pinecone-trace.c"
#undef open
#undef write
#undef g_get_monotonic_time
#undef clock_gettime

static void input(void) {
  g_auto(PineconeTraceTouch) sample = pinecone_trace_touch(UINT32_MAX, 0, "up");
  wall_us += 1000;
  cpu_us += 100;
}
static void commit(void *output, uint32_t seq) {
  pinecone_trace_begin(output, seq);
  wall_us += 2000; cpu_us += 200;
  pinecone_trace_submit(output);
  wall_us += 4000; cpu_us += 300;
  pinecone_trace_commit(output);
}
static void clear(void) {
  memset(frames, 0, sizeof frames);
  active = NULL;
  last_input = (PineconeTraceTouch){0};
  last_control_output = NULL;
  g_string_truncate(captured, 0);
}
static unsigned occupied(void) {
  unsigned count = 0;
  for (unsigned i = 0; i < G_N_ELEMENTS(frames); ++i) count += frames[i].output != NULL;
  return count;
}

int main(int argc, char **argv) {
  g_assert_cmpint(argc, ==, 2);
  captured = g_string_new(NULL);
  void *a = (void *)(uintptr_t)1, *b = (void *)(uintptr_t)2;
  if (strcmp(argv[1], "disabled") == 0) {
    g_unsetenv("PINECONE_INTERACTION_TRACE");
    input(); commit(a, 1); pinecone_trace_app(a, "org.example.Editor");
    pinecone_trace_present(a, 1, 1);
    g_assert_cmpuint(trace_writes, ==, 0);
    g_assert_cmpuint(control_writes, ==, 1);
    g_assert_cmpuint(cpu_reads, ==, 0);
    puts("PASS: disabled trace has zero CPU-clock reads; app control intact");
    return 0;
  }
  g_setenv("PINECONE_INTERACTION_TRACE", "1", TRUE);
  input(); commit(a, 1); pinecone_trace_present(a, 1, 1);
  g_assert_nonnull(strstr(captured->str, "\"handlerCPUUs\":100"));
  g_assert_nonnull(strstr(captured->str, "\"renderCPUUs\":1100,\"submitCPUUs\":1300,\"commitCPUUs\":1600"));
  g_assert_nonnull(strstr(captured->str, "\"association\":\"temporalOnly\""));
  g_assert_null(strstr(captured->str, "\"association\":\"causal\""));
  unsigned before = trace_writes;
  pinecone_trace_present(a, 1, 1);
  g_assert_cmpuint(trace_writes, ==, before);
  fputs(captured->str, stdout);

  clear(); input(); wall_us += 52000000;
  commit(a, 2); pinecone_trace_present(a, 2, 1);
  const char *present = strstr(captured->str, "\"event\":\"present\"");
  g_assert_nonnull(present);
  g_assert_null(strstr(present, "inputSequence"));

  clear(); commit(a, 3); commit(b, 3);
  pinecone_trace_present(b, 3, 1); pinecone_trace_present(a, 3, 1);
  g_assert_nonnull(strstr(captured->str, "\"outputID\":1"));
  g_assert_nonnull(strstr(captured->str, "\"outputID\":2"));
  g_assert_cmpuint(occupied(), ==, 0);

  clear(); commit(a, 4); pinecone_trace_present(a, 4, 0);
  g_assert_nonnull(strstr(captured->str, "notPresented"));
  g_assert_null(strstr(captured->str, "\"event\":\"present\""));
  commit(a, 5); pinecone_trace_abort(a);
  g_assert_nonnull(strstr(captured->str, "aborted"));
  commit(a, 6); pinecone_trace_destroy(a);
  g_assert_nonnull(strstr(captured->str, "outputDestroyed"));
  before = trace_writes; pinecone_trace_present(a, 6, 1);
  g_assert_cmpuint(trace_writes, ==, before);

  clear(); commit(a, 7); pinecone_trace_app(a, "org.example.Editor");
  before = control_writes;
  wall_us += 11000000; pinecone_trace_present(a, 7, 1);
  g_assert_nonnull(strstr(captured->str, "expired"));
  g_assert_cmpuint(control_writes, ==, before + 1);

  clear();
  for (uint32_t i = 1; i <= 40; ++i) commit(a, i);
  g_assert_cmpuint(occupied(), ==, 32);
  g_assert_nonnull(strstr(captured->str, "capacityEvicted"));
  before = trace_writes; pinecone_trace_present(a, 1, 1);
  g_assert_cmpuint(trace_writes, ==, before);
  commit(a, 40);
  g_assert_nonnull(strstr(captured->str, "sequenceReused"));

  clear(); commit(a, UINT32_MAX); uint64_t old_id = active->id;
  commit(a, 0); g_assert_cmpuint(active->id, >, old_id);
  pinecone_trace_present(a, 0, 1); pinecone_trace_present(a, UINT32_MAX, 1);
  g_assert_cmpuint(occupied(), ==, 0);
  uint64_t old_epoch = epoch;
  input_sequence = UINT64_MAX; input();
  g_assert_cmpuint(epoch, >, old_epoch); g_assert_cmpuint(input_sequence, ==, 1);
  old_epoch = epoch; frame_id = UINT64_MAX; commit(a, 1);
  g_assert_cmpuint(epoch, >, old_epoch); g_assert_cmpuint(active->id, ==, 1);
  g_assert_cmpuint(active->input.sequence, ==, 0);

  clear(); cpu_unavailable = TRUE;
  input(); commit(a, 2); pinecone_trace_present(a, 2, 1);
  g_assert_null(strstr(captured->str, "CPUUs"));
  cpu_unavailable = FALSE;
  clear(); short_write = 1; before = trace_writes; input();
  g_assert_cmpuint(trace_writes, ==, before + 1);
  short_write = 0; input();
  g_assert_nonnull(strstr(captured->str, "\036PINECONE_TRACE {\"version\":2"));

  clear(); records = 8192; before = cpu_reads;
  input(); commit(a, 3); pinecone_trace_app(a, "org.example.Editor");
  unsigned controls = control_writes; pinecone_trace_present(a, 3, 1);
  g_assert_cmpuint(cpu_reads, ==, before);
  g_assert_cmpuint(control_writes, ==, controls + 1);
  puts("PASS: wall/CPU stages, 52s expiry, reordered outputs, drops, abort/reset, bounded ring, sequence wrap, partial write, budget");
  g_string_free(captured, TRUE);
  return 0;
}
