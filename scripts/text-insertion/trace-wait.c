#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "trace.h"

/* Records share PCEDIT1 identities, and only exist inside an active edit on
 * the tracing thread. No allocation, stack walking or output on the hot path. */
#define CAPACITY 2048
typedef struct {
  unsigned id;
  uintptr_t caller;
  int64_t timeout, result;
  unsigned error_domain;
  int error_code;
  char object[64], detail[96], service[96], interface[96];
} Metadata;
static Metadata records[CAPACITY];
static unsigned used, dropped;
static int enabled;

#define DECLARE(name) static __typeof__(name) *next_##name
DECLARE(g_signal_emit_valist);
DECLARE(g_object_notify_by_pspec);
DECLARE(gtk_application_inhibit);
DECLARE(gtk_application_uninhibit);
DECLARE(g_dbus_proxy_call_sync);
DECLARE(g_dbus_connection_call_sync);
DECLARE(g_dbus_connection_send_message_with_reply_sync);
DECLARE(g_poll);
DECLARE(g_cond_wait);
DECLARE(g_cond_wait_until);

#define RESOLVE(name) do { \
  if (!next_##name) { \
    next_##name = dlsym(RTLD_NEXT, #name); \
    if (!next_##name) { \
      const char failure[] = "PCWAIT1 missing symbol " #name "\n"; \
      (void)write(2, failure, sizeof failure - 1); \
      _exit(127); \
    } \
  } \
} while (0)

__attribute__((constructor)) static void initialize(void)
{
  int saved = errno;
  const char *value = getenv("PINECONE_TEXT_INSERTION_TRACE");
  enabled = value && strcmp(value, "1") == 0;
  RESOLVE(g_signal_emit_valist);
  RESOLVE(g_object_notify_by_pspec);
  RESOLVE(gtk_application_inhibit);
  RESOLVE(gtk_application_uninhibit);
  RESOLVE(g_dbus_proxy_call_sync);
  RESOLVE(g_dbus_connection_call_sync);
  RESOLVE(g_dbus_connection_send_message_with_reply_sync);
  RESOLVE(g_poll);
  RESOLVE(g_cond_wait);
  RESOLVE(g_cond_wait_until);
  errno = saved;
}

static void copy_token(char *out, size_t size, const char *value)
{
  size_t i = 0;
  if (!value) value = "-";
  for (; i + 1 < size && value[i]; i++) {
    unsigned char c = (unsigned char)value[i];
    out[i] = c > 32 && c < 127 && c != '=' ? (char)c : '_';
  }
  out[i] = 0;
}

static Metadata *metadata(PineconeTextScope scope, void *caller)
{
  if (!scope.id) return NULL;
  if (used == CAPACITY) { dropped++; return NULL; }
  Metadata *record = &records[used++];
  record->id = scope.id;
  record->caller = (uintptr_t)caller;
  record->timeout = INT64_MIN;
  return record;
}

#define START(name, original) \
  int saved_errno = errno; \
  RESOLVE(original); \
  PineconeTextScope scope = pinecone_text_begin(name, 0); \
  Metadata *record = metadata(scope, __builtin_return_address(0))
#define CALL_READY() (errno = saved_errno)
#define END() pinecone_text_end(&scope)
#define TOKEN(field, value) do { if (record) copy_token(record->field, sizeof record->field, value); } while (0)

static void outcome(Metadata *record, int64_t result, GError **error)
{
  if (!record) return;
  record->result = result;
  if (error && *error) {
    record->error_domain = (*error)->domain;
    record->error_code = (*error)->code;
  }
}

/* g_signal_emit is a va_list forwarding entry point. All arguments, including
 * return-value storage and detailed signal quarks, go to the original valist. */
void g_signal_emit(gpointer instance, guint signal_id, GQuark detail, ...)
{
  START("g_signal_emit", g_signal_emit_valist);
  if (record && instance) TOKEN(object, G_OBJECT_TYPE_NAME(instance));
  TOKEN(detail, g_signal_name(signal_id));
  va_list args;
  va_start(args, detail);
  CALL_READY();
  next_g_signal_emit_valist(instance, signal_id, detail, args);
  va_end(args);
  END();
}

void g_object_notify_by_pspec(GObject *object, GParamSpec *pspec)
{
  START("g_object_notify_by_pspec", g_object_notify_by_pspec);
  if (record && object) TOKEN(object, G_OBJECT_TYPE_NAME(object));
  TOKEN(detail, pspec ? pspec->name : NULL);
  CALL_READY();
  next_g_object_notify_by_pspec(object, pspec);
  END();
}

guint gtk_application_inhibit(GtkApplication *application, GtkWindow *window,
                              GtkApplicationInhibitFlags flags, const char *reason)
{
  START("gtk_application_inhibit", gtk_application_inhibit);
  if (record) record->timeout = flags; /* Flags, not a timeout, for this API. */
  CALL_READY();
  guint result = next_gtk_application_inhibit(application, window, flags, reason);
  outcome(record, result, NULL);
  END();
  return result;
}

void gtk_application_uninhibit(GtkApplication *application, guint cookie)
{
  START("gtk_application_uninhibit", gtk_application_uninhibit);
  if (record) record->result = cookie;
  CALL_READY();
  next_gtk_application_uninhibit(application, cookie);
  END();
}

GVariant *g_dbus_proxy_call_sync(GDBusProxy *proxy, const gchar *method,
                                GVariant *parameters, GDBusCallFlags flags,
                                gint timeout, GCancellable *cancellable, GError **error)
{
  START("g_dbus_proxy_call_sync", g_dbus_proxy_call_sync);
  TOKEN(detail, method);
  if (record && proxy) {
    TOKEN(service, g_dbus_proxy_get_name(proxy));
    TOKEN(interface, g_dbus_proxy_get_interface_name(proxy));
    record->timeout = timeout;
  }
  CALL_READY();
  GVariant *result = next_g_dbus_proxy_call_sync(proxy, method, parameters, flags,
                                               timeout, cancellable, error);
  outcome(record, result != NULL, error);
  END();
  return result;
}

GVariant *g_dbus_connection_call_sync(GDBusConnection *connection, const gchar *bus_name,
                                     const gchar *object_path, const gchar *interface,
                                     const gchar *method, GVariant *parameters,
                                     const GVariantType *reply_type, GDBusCallFlags flags,
                                     gint timeout, GCancellable *cancellable, GError **error)
{
  START("g_dbus_connection_call_sync", g_dbus_connection_call_sync);
  TOKEN(service, bus_name);
  TOKEN(interface, interface);
  TOKEN(detail, method);
  if (record) record->timeout = timeout;
  CALL_READY();
  GVariant *result = next_g_dbus_connection_call_sync(connection, bus_name, object_path,
      interface, method, parameters, reply_type, flags, timeout, cancellable, error);
  outcome(record, result != NULL, error);
  END();
  return result;
}

GDBusMessage *g_dbus_connection_send_message_with_reply_sync(GDBusConnection *connection,
    GDBusMessage *message, GDBusSendMessageFlags flags, gint timeout,
    volatile guint32 *serial, GCancellable *cancellable, GError **error)
{
  START("g_dbus_connection_send_message_with_reply_sync", g_dbus_connection_send_message_with_reply_sync);
  if (record && message) {
    TOKEN(service, g_dbus_message_get_destination(message));
    TOKEN(interface, g_dbus_message_get_interface(message));
    TOKEN(detail, g_dbus_message_get_member(message));
    record->timeout = timeout;
  }
  CALL_READY();
  GDBusMessage *result = next_g_dbus_connection_send_message_with_reply_sync(
      connection, message, flags, timeout, serial, cancellable, error);
  outcome(record, result != NULL, error);
  END();
  return result;
}

gint g_poll(GPollFD *fds, guint count, gint timeout)
{
  START("g_poll", g_poll);
  if (record) record->timeout = timeout;
  CALL_READY();
  gint result = next_g_poll(fds, count, timeout);
  outcome(record, result, NULL);
  END();
  return result;
}

void g_cond_wait(GCond *cond, GMutex *mutex)
{
  START("g_cond_wait", g_cond_wait);
  if (record) record->timeout = -1;
  CALL_READY();
  next_g_cond_wait(cond, mutex);
  END();
}

gboolean g_cond_wait_until(GCond *cond, GMutex *mutex, gint64 end_time)
{
  START("g_cond_wait_until", g_cond_wait_until);
  if (record) record->timeout = end_time; /* Absolute monotonic microseconds. */
  CALL_READY();
  gboolean result = next_g_cond_wait_until(cond, mutex, end_time);
  outcome(record, result, NULL);
  END();
  return result;
}

__attribute__((destructor)) static void finish(void)
{
  if (!enabled) return;
  fprintf(stderr, "PCWAIT1 summary pid=%ld records=%u dropped=%u\n", (long)getpid(), used, dropped);
  for (unsigned i = 0; i < used; i++) {
    Metadata *r = &records[i];
    Dl_info info = {0};
    dladdr((void *)r->caller, &info);
    const char *module = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    module = module ? module + 1 : info.dli_fname;
    fprintf(stderr, "PCWAIT1 call pid=%ld id=%u object=%s detail=%s service=%s interface=%s "
        "arg=%" PRId64 " result=%" PRId64 " error_domain=%s error_code=%d module=%s offset=0x%" PRIxPTR "\n",
        (long)getpid(), r->id, r->object[0] ? r->object : "-",
        r->detail[0] ? r->detail : "-", r->service[0] ? r->service : "-",
        r->interface[0] ? r->interface : "-", r->timeout, r->result,
        r->error_domain ? g_quark_to_string(r->error_domain) : "-", r->error_code,
        module ? module : "unknown", r->caller - (uintptr_t)info.dli_fbase);
  }
  fprintf(stderr, "PCWAIT1 done pid=%ld\n", (long)getpid());
}
