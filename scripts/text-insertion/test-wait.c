#include <gtk/gtk.h>
#include <errno.h>
#include <string.h>
#include "trace.h"

#ifdef PC_WAIT_BACKEND
/* Deliberately synthetic backend: validates forwarding without a session bus,
 * a portal service, an editor instance, or changing inhibition semantics. */
GVariant *g_dbus_proxy_call_sync(GDBusProxy *proxy, const gchar *method,
    GVariant *parameters, GDBusCallFlags flags, gint timeout,
    GCancellable *cancellable, GError **error)
{
  (void)error;
  g_assert_true(G_IS_DBUS_PROXY(proxy));
  g_assert_cmpstr(method, ==, "Inhibit");
  g_assert_cmpstr(g_variant_get_string(parameters, NULL), ==, "private-payload-\xc3\xa9");
  g_assert_cmpint(flags, ==, G_DBUS_CALL_FLAGS_NO_AUTO_START);
  g_assert_cmpint(timeout, ==, 123);
  g_assert_null(cancellable);
  GMutex mutex = {0};
  GCond cond = {0};
  g_mutex_lock(&mutex);
  g_assert_false(g_cond_wait_until(&cond, &mutex, g_get_monotonic_time() + 2000));
  g_mutex_unlock(&mutex);
  g_mutex_clear(&mutex);
  g_cond_clear(&cond);
  errno = ERANGE;
  return g_variant_ref_sink(g_variant_new_uint32(77));
}

guint gtk_application_inhibit(GtkApplication *application, GtkWindow *window,
                              GtkApplicationInhibitFlags flags, const char *reason)
{
  g_assert_null(application);
  g_assert_null(window);
  g_assert_cmpint(flags, ==, GTK_APPLICATION_INHIBIT_LOGOUT);
  g_assert_cmpstr(reason, ==, "private-reason");
  GDBusProxy *proxy = g_object_new(G_TYPE_DBUS_PROXY, "g-name", "org.example.Test",
      "g-interface-name", "org.example.Inhibit", NULL);
  GVariant *parameters = g_variant_ref_sink(g_variant_new_string("private-payload-\xc3\xa9"));
  GVariant *result = g_dbus_proxy_call_sync(proxy, "Inhibit", parameters,
      G_DBUS_CALL_FLAGS_NO_AUTO_START, 123, NULL, NULL);
  g_assert_cmpuint(g_variant_get_uint32(result), ==, 77);
  g_variant_unref(result);
  g_variant_unref(parameters);
  g_object_unref(proxy);
  errno = EDOM;
  return 77;
}

void gtk_application_uninhibit(GtkApplication *application, guint cookie)
{
  g_assert_null(application);
  g_assert_cmpuint(cookie, ==, 77);
  errno = EDOM;
}

GVariant *g_dbus_connection_call_sync(GDBusConnection *connection, const gchar *bus_name,
    const gchar *object_path, const gchar *interface, const gchar *method,
    GVariant *parameters, const GVariantType *reply_type, GDBusCallFlags flags,
    gint timeout, GCancellable *cancellable, GError **error)
{
  g_assert_null(connection);
  g_assert_cmpstr(bus_name, ==, "org.example.Test");
  g_assert_cmpstr(object_path, ==, "/private_path");
  g_assert_cmpstr(interface, ==, "org.example.Test");
  g_assert_cmpstr(method, ==, "Cancelled");
  g_assert_null(parameters);
  g_assert_true(g_variant_type_equal(reply_type, G_VARIANT_TYPE_UNIT));
  g_assert_cmpint(flags, ==, G_DBUS_CALL_FLAGS_NONE);
  g_assert_cmpint(timeout, ==, 456);
  g_assert_true(g_cancellable_is_cancelled(cancellable));
  g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CANCELLED, "private-error-message");
  errno = EAGAIN;
  return NULL;
}

GDBusMessage *g_dbus_connection_send_message_with_reply_sync(GDBusConnection *connection,
    GDBusMessage *message, GDBusSendMessageFlags flags, gint timeout,
    volatile guint32 *serial, GCancellable *cancellable, GError **error)
{
  (void)error;
  g_assert_null(connection);
  g_assert_true(G_IS_DBUS_MESSAGE(message));
  g_assert_cmpint(flags, ==, G_DBUS_SEND_MESSAGE_FLAGS_NONE);
  g_assert_cmpint(timeout, ==, 789);
  g_assert_null(cancellable);
  *serial = 1234;
  return g_object_ref(message);
}
#else
static guint signal_cb(GObject *object, const char *text, gint value, gpointer data)
{
  g_assert_true(G_IS_OBJECT(object));
  g_assert_cmpstr(text, ==, "private-signal-\xe6\x97\xa5");
  g_assert_cmpint(value, ==, -17);
  g_assert_cmpuint(*(unsigned *)data, ==, 0);
  ++*(unsigned *)data;
  return 42;
}

typedef struct { GMutex mutex; GCond cond; gboolean ready; } Wait;
static gpointer wake(gpointer data)
{
  Wait *wait = data;
  g_mutex_lock(&wait->mutex);
  wait->ready = TRUE;
  g_cond_signal(&wait->cond);
  g_mutex_unlock(&wait->mutex);
  /* A foreign thread must not produce edit-associated records. */
  g_poll(NULL, 0, 0);
  return NULL;
}

int main(void)
{
  GObject *object = g_object_new(G_TYPE_OBJECT, NULL);
  guint signal_id = g_signal_new("pc-test-signal", G_TYPE_OBJECT, G_SIGNAL_RUN_LAST,
      0, NULL, NULL, NULL, G_TYPE_UINT, 2, G_TYPE_STRING, G_TYPE_INT);
  unsigned calls = 0, result = 0;
  g_signal_connect(object, "pc-test-signal", G_CALLBACK(signal_cb), &calls);
  PC_TEXT_SCOPE("wait.test", 1);
  g_signal_emit(object, signal_id, 0, "private-signal-\xe6\x97\xa5", -17, &result);
  g_assert_cmpuint(result, ==, 42);
  g_assert_cmpuint(calls, ==, 1);
  g_object_unref(object);

  GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
  GParamSpec *pspec = g_object_class_find_property(G_OBJECT_GET_CLASS(buffer), "cursor-position");
  g_object_notify_by_pspec(G_OBJECT(buffer), pspec);
  g_object_unref(buffer);
  g_assert_cmpuint(gtk_application_inhibit(NULL, NULL, GTK_APPLICATION_INHIBIT_LOGOUT,
                                         "private-reason"), ==, 77);
  g_assert_cmpint(errno, ==, EDOM);
  gtk_application_uninhibit(NULL, 77);
  g_assert_cmpint(errno, ==, EDOM);

  GCancellable *cancel = g_cancellable_new();
  g_cancellable_cancel(cancel);
  GError *error = NULL;
  g_assert_null(g_dbus_connection_call_sync(NULL, "org.example.Test", "/private_path",
      "org.example.Test", "Cancelled", NULL, G_VARIANT_TYPE_UNIT,
      G_DBUS_CALL_FLAGS_NONE, 456, cancel, &error));
  g_assert_cmpint(errno, ==, EAGAIN);
  g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_clear_error(&error);
  g_object_unref(cancel);
  GDBusMessage *message = g_dbus_message_new_method_call("org.example.Test", "/private_path",
      "org.example.Test", "Echo");
  guint32 serial = 0;
  GDBusMessage *reply = g_dbus_connection_send_message_with_reply_sync(NULL, message,
      G_DBUS_SEND_MESSAGE_FLAGS_NONE, 789, &serial, NULL, NULL);
  g_assert_true(reply == message);
  g_assert_cmpuint(serial, ==, 1234);
  g_object_unref(reply);
  g_object_unref(message);
  errno = EDOM;
  g_assert_cmpint(g_poll(NULL, 0, 0), ==, 0);
  g_assert_cmpint(errno, ==, EDOM);
  Wait wait = {0};
  g_mutex_lock(&wait.mutex);
  GThread *thread = g_thread_new("wake", wake, &wait);
  while (!wait.ready) g_cond_wait(&wait.cond, &wait.mutex);
  g_mutex_unlock(&wait.mutex);
  g_thread_join(thread);
  g_mutex_clear(&wait.mutex);
  g_cond_clear(&wait.cond);
  return 0;
}
#endif
