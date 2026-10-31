#define _GNU_SOURCE
#define G_LOG_DOMAIN "phosh-app-tracker"
#include <gio/gio.h>
#include <gio/gdesktopappinfo.h>
#include <signal.h>
#include <unistd.h>
#include "app-tracker.h"

/* Real GObjects, signals, hash tables, sources and cancellables. Only service
 * transports and shell initialization are mocked; tracker.inc is production. */
struct phosh_private_startup_tracker;
struct phosh_private_startup_tracker_listener {
    void (*startup_id)(void *, struct phosh_private_startup_tracker *, const char *, unsigned, unsigned);
    void (*launched)(void *, struct phosh_private_startup_tracker *, const char *, unsigned, unsigned);
};
#define PHOSH_PRIVATE_STARTUP_TRACKER_PROTOCOL_X11 1
#define PHOSH_SHELL_DEBUG_APP_ACTIVATION 1
#define _phosh_marshal_VOID__OBJECT_STRING g_cclosure_marshal_generic
#define _phosh_marshal_VOID__OBJECT_STRINGv g_cclosure_marshal_generic_va
static int phosh_shell_get_debug_flags(void) { return 0; }
static void phosh_private_startup_tracker_destroy(void *p) { (void)p; }
static gboolean gm_str_is_null_or_empty(const char *s) { return !s || !*s; }
static char *phosh_strip_suffix_from_app_id(const char *id)
{
    char *copy = g_strdup(id);
    if (copy && g_str_has_suffix(copy, ".desktop")) copy[strlen(copy) - 8] = 0;
    return copy;
}
static void phosh_async_error_warn(GError *error, const char *message)
{
    g_assert_nonnull(error);
    (void)message;
}
static gboolean gnome_start_systemd_scope_finish(GAsyncResult *res, GError **error) { return TRUE; }
static guint scope_calls;
static void gnome_start_systemd_scope(const char *app, gint32 pid, const char *description,
                                      GDBusConnection *bus, GCancellable *cancel,
                                      GAsyncReadyCallback callback, gpointer data)
{
    g_assert_true(G_IS_DBUS_CONNECTION(bus));
    g_assert_true(G_IS_CANCELLABLE(cancel));
    ++scope_calls;
    g_free(data);
}

typedef struct {
    GAsyncReadyCallback callback;
    gpointer data;
    GObject *source;
    GCancellable *cancel;
} Pending;
static Pending bus_pending, unit_pending, proxy_pending;
static guint subscription;
static void capture(Pending *p, GObject *source, GCancellable *cancel,
                    GAsyncReadyCallback callback, gpointer data)
{
    g_assert_null(p->callback);
    *p = (Pending){callback, data, source ? g_object_ref(source) : NULL,
                   cancel ? g_object_ref(cancel) : NULL};
}
static void deliver(Pending *pending, gpointer result, GDestroyNotify destroy, gboolean error)
{
    Pending p = *pending;
    *pending = (Pending){0};
    g_assert_nonnull(p.callback);
    /* Deliberately allow a success already queued before cancellation. */
    GTask *task = g_task_new(p.source, NULL, NULL, NULL);
    if (error) g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_CANCELLED, "cancelled");
    else g_task_return_pointer(task, result, destroy);
    p.callback(p.source, G_ASYNC_RESULT(task), p.data);
    g_object_unref(task);
    g_clear_object(&p.source);
    g_clear_object(&p.cancel);
}
static void mock_bus_get(GBusType type, GCancellable *cancel, GAsyncReadyCallback cb, gpointer data)
{ capture(&bus_pending, NULL, cancel, cb, data); }
static GDBusConnection *mock_bus_finish(GAsyncResult *res, GError **error)
{ return g_task_propagate_pointer(G_TASK(res), error); }
static guint mock_subscribe(GDBusConnection *bus, const char *sender, const char *interface,
                            const char *member, const char *path, const char *arg,
                            GDBusSignalFlags flags, GDBusSignalCallback cb, gpointer data,
                            GDestroyNotify destroy)
{ return ++subscription; }
static void mock_clear_subscription(guint *id, GDBusConnection *bus) { *id = 0; }
static void mock_call(GDBusConnection *bus, const char *name, const char *path,
                     const char *interface, const char *method, GVariant *parameters,
                     const GVariantType *reply, GDBusCallFlags flags, gint timeout,
                     GCancellable *cancel, GAsyncReadyCallback cb, gpointer data)
{
    g_assert_cmpstr(method, ==, "GetUnit");
    g_variant_unref(g_variant_ref_sink(parameters));
    capture(&unit_pending, G_OBJECT(bus), cancel, cb, data);
}
static GVariant *mock_call_finish(GDBusConnection *bus, GAsyncResult *res, GError **error)
{ return g_task_propagate_pointer(G_TASK(res), error); }
static void mock_proxy_new(GDBusConnection *bus, GDBusProxyFlags flags,
                          GDBusInterfaceInfo *interface, const char *name, const char *path,
                          const char *iface, GCancellable *cancel, GAsyncReadyCallback cb, gpointer data)
{ capture(&proxy_pending, G_OBJECT(bus), cancel, cb, data); }
static GDBusProxy *mock_proxy_finish(GAsyncResult *res, GError **error)
{ return g_task_propagate_pointer(G_TASK(res), error); }
#define g_bus_get mock_bus_get
#define g_bus_get_finish mock_bus_finish
#define g_dbus_connection_signal_subscribe mock_subscribe
#define g_clear_dbus_signal_subscription mock_clear_subscription
#define g_dbus_connection_call mock_call
#define g_dbus_connection_call_finish mock_call_finish
#define g_dbus_proxy_new mock_proxy_new
#define g_dbus_proxy_new_finish mock_proxy_finish
#include "tracker.inc"

static GDesktopAppInfo *info_new(void)
{
    GDesktopAppInfo *info = g_desktop_app_info_new_from_filename(g_getenv("TRACKER_DESKTOP"));
    g_assert_nonnull(info);
    return info;
}
static PhoshAppState *add_state(PhoshAppTracker *tracker, const char *id)
{
    g_autoptr(GDesktopAppInfo) info = info_new();
    PhoshAppState *state = phosh_app_state_new(info, id, 0,
        PHOSH_APP_TRACKER_STATE_FLAG_LAUNCHED, tracker);
    g_hash_table_replace(tracker->apps, g_strdup(id), state);
    return state;
}
static void weak_notify(gpointer data, GObject *object) { ++*(guint *)data; }
static void expire(PhoshAppState *state)
{
    g_clear_handle_id(&state->timeout.id, g_source_remove);
    state->timeout.waited = APP_TRACKER_MAX_INITIAL_TOPLEVEL_TIMEOUT;
    state->timeout.id = g_idle_add(on_startup_timeout, state);
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*timed out*");
    g_main_context_iteration(NULL, FALSE);
    g_test_assert_expected_messages();
}
static guint terminal_calls;
static void remove_on_terminal(PhoshAppTracker *self, GAppInfo *info, const char *id, gpointer data)
{
    ++terminal_calls;
    g_hash_table_remove(self->apps, id);
    g_assert_cmpstr(g_app_info_get_name(info), ==, "Tracker Fixture");
    g_assert_cmpstr(id, ==, "launch");
}
static void replace_on_terminal(PhoshAppTracker *self, GAppInfo *info, const char *id, gpointer data)
{ ++terminal_calls; add_state(self, id); }
static void release_on_signal(PhoshAppTracker *self, GAppInfo *info, const char *id, gpointer data)
{ g_clear_object((PhoshAppTracker **)data); }
static void timeout_remove(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    terminal_calls = 0;
    g_signal_connect(tracker, "app-failed", G_CALLBACK(remove_on_terminal), NULL);
    expire(add_state(tracker, "launch"));
    g_assert_cmpuint(terminal_calls, ==, 1);
    g_assert_cmpuint(g_hash_table_size(tracker->apps), ==, 0);
}
static void timeout_replace(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    g_signal_connect(tracker, "app-failed", G_CALLBACK(replace_on_terminal), NULL);
    expire(add_state(tracker, "launch"));
    g_assert_nonnull(g_hash_table_lookup(tracker->apps, "launch"));
}
static void timeout_release(void)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    guint gone = 0;
    g_object_weak_ref(G_OBJECT(tracker), weak_notify, &gone);
    g_signal_connect(tracker, "app-failed", G_CALLBACK(release_on_signal), &tracker);
    expire(add_state(tracker, "launch"));
    g_assert_null(tracker);
    g_assert_cmpuint(gone, ==, 1);
}
static void dispose_on_terminal(PhoshAppTracker *self, GAppInfo *info, const char *id, gpointer data)
{
    g_object_run_dispose(G_OBJECT(self));
    g_assert_nonnull(self->apps);
    g_assert_cmpstr(g_app_info_get_name(info), ==, "Tracker Fixture");
}
static void timeout_dispose(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    g_signal_connect(tracker, "app-failed", G_CALLBACK(dispose_on_terminal), NULL);
    expire(add_state(tracker, "launch"));
    g_assert_cmpuint(g_hash_table_size(tracker->apps), ==, 0);
    g_object_run_dispose(G_OBJECT(tracker));
}
static void ready_recursive(PhoshAppTracker *self, GAppInfo *info, const char *id, gpointer data)
{
    if (++terminal_calls == 1) startup_tracker_handle_startup_id(self, NULL, id, 0, 0);
}
static void ready_reentrant(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    add_state(tracker, "launch");
    terminal_calls = 0;
    g_signal_connect(tracker, "app-ready", G_CALLBACK(ready_recursive), NULL);
    startup_tracker_handle_startup_id(tracker, NULL, "launch", 0, 0);
    g_assert_cmpuint(terminal_calls, ==, 1);
}
static void failure_replace(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    add_state(tracker, "launch");
    g_signal_connect(tracker, "app-failed", G_CALLBACK(replace_on_terminal), NULL);
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Failed to launch*");
    on_app_launch_failed(tracker, "launch", NULL);
    g_test_assert_expected_messages();
    g_assert_nonnull(g_hash_table_lookup(tracker->apps, "launch"));
}
static void dbus_reentrant(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    g_signal_connect(tracker, "app-launch-started", G_CALLBACK(remove_on_terminal), NULL);
    g_signal_connect(tracker, "app-launched", G_CALLBACK(remove_on_terminal), NULL);
    g_autoptr(GVariant) parameters = g_variant_ref_sink(g_variant_new("(@aysx@as@a{sv})",
        g_variant_new_bytestring("/test/org.pinecone.TrackerFixture.desktop"), "", (gint64)0,
        g_variant_new_strv(NULL, 0), g_variant_new_parsed("{'startup-id': <'launch'>}")));
    terminal_calls = 0;
    on_dbus_app_launched(NULL, NULL, NULL, NULL, NULL, parameters, tracker);
    g_assert_cmpuint(terminal_calls, ==, 2);
}
static GVariant *platform(const char *id, gint32 pid)
{
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&builder, "{sv}", "startup-notification-id", g_variant_new_string(id));
    g_variant_builder_add(&builder, "{sv}", "pid", g_variant_new_int32(pid));
    return g_variant_ref_sink(g_variant_builder_end(&builder));
}
static void context_late(void)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    g_autoptr(GAppLaunchContext) context = g_app_launch_context_new();
    g_autoptr(GDesktopAppInfo) info = info_new();
    g_autoptr(GVariant) data = platform("launch", 0);
    bind_context(tracker, context);
    g_object_unref(tracker);
    g_signal_emit_by_name(context, "launch-started", info, data);
    g_signal_emit_by_name(context, "launched", info, data);
    g_signal_emit_by_name(context, "launch-failed", "launch");
}
static void context_multiple(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    GAppLaunchContext *context = g_app_launch_context_new();
    g_autoptr(GDesktopAppInfo) info = info_new();
    guint gone = 0;
    g_object_weak_ref(G_OBJECT(context), weak_notify, &gone);
    bind_context(tracker, context);
    for (guint i = 0; i < 2; ++i) {
        g_autofree char *id = g_strdup_printf("launch-%u", i);
        g_autoptr(GVariant) data = platform(id, 0);
        g_signal_emit_by_name(context, "launch-started", info, data);
        g_signal_emit_by_name(context, "launched", info, data);
        g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Failed to launch*");
        g_signal_emit_by_name(context, "launch-failed", id);
        g_test_assert_expected_messages();
        g_assert_cmpuint(gone, ==, 0);
    }
    g_object_unref(context);
    g_assert_cmpuint(gone, ==, 1);
}
static void context_release(void)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    g_autoptr(GAppLaunchContext) context = g_app_launch_context_new();
    g_autoptr(GDesktopAppInfo) info = info_new();
    g_autoptr(GVariant) data = platform("launch", getpid());
    guint gone = 0;
    g_object_weak_ref(G_OBJECT(tracker), weak_notify, &gone);
    bind_context(tracker, context);
    g_signal_emit_by_name(context, "launch-started", info, data);
    g_signal_connect(tracker, "app-launched", G_CALLBACK(release_on_signal), &tracker);
    scope_calls = 0;
    g_signal_emit_by_name(context, "launched", info, data);
    g_assert_cmpuint(scope_calls, ==, 1);
    g_assert_cmpuint(gone, ==, 1);
    g_assert_null(tracker);
}
static void bus_test(gconstpointer error)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    guint gone = 0;
    g_object_weak_ref(G_OBJECT(tracker), weak_notify, &gone);
    on_idle(tracker);
    g_object_unref(tracker);
    g_assert_cmpuint(gone, ==, 0);
    if (error) g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Failed to attach*");
    deliver(&bus_pending, error ? NULL : g_object_new(G_TYPE_DBUS_CONNECTION, NULL),
            g_object_unref, error != NULL);
    if (error) g_test_assert_expected_messages();
    g_assert_cmpuint(gone, ==, 1);
}
static PhoshAppState *flatpak_start(PhoshAppTracker *tracker)
{
    PhoshAppState *state = add_state(tracker, "launch");
    state->flatpak.scope_regex = g_regex_new("app-flatpak-test-[0-9]+\\.scope", 0, 0, NULL);
    state->flatpak.dbus_id = ++subscription;
    g_autoptr(GVariant) job = g_variant_ref_sink(g_variant_new("(uoss)", 1u,
        "/job/1", "app-flatpak-test-42.scope", "done"));
    on_systemd_job_removed(tracker->session_bus, NULL, NULL, NULL, NULL, job, state);
    return state;
}
static void unit_success(void)
{
    deliver(&unit_pending, g_variant_ref_sink(g_variant_new("(o)", "/unit/test")),
            (GDestroyNotify)g_variant_unref, FALSE);
}
static GDBusProxy *proxy_new(guint *gone)
{
    GDBusProxy *proxy = g_object_new(G_TYPE_DBUS_PROXY, NULL);
    g_dbus_proxy_set_cached_property(proxy, "ActiveState", g_variant_new_string("active"));
    g_object_weak_ref(G_OBJECT(proxy), weak_notify, gone);
    return proxy;
}
static void flatpak_unit_retired(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    flatpak_start(tracker);
    g_hash_table_remove(tracker->apps, "launch");
    add_state(tracker, "launch");
    unit_success();
    g_assert_null(proxy_pending.callback);
}
static void flatpak_proxy_retired(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    flatpak_start(tracker);
    unit_success();
    g_hash_table_remove(tracker->apps, "launch");
    PhoshAppState *new_state = add_state(tracker, "launch");
    guint gone = 0;
    deliver(&proxy_pending, proxy_new(&gone), g_object_unref, FALSE);
    g_assert_null(new_state->flatpak.unit_proxy);
    g_assert_cmpuint(gone, ==, 1);
}
static void flatpak_shutdown(void)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    flatpak_start(tracker);
    guint gone = 0;
    g_object_weak_ref(G_OBJECT(tracker), weak_notify, &gone);
    g_object_unref(tracker);
    g_assert_cmpuint(gone, ==, 1);
    unit_success();
    g_assert_null(proxy_pending.callback);
}
static void flatpak_normal(void)
{
    PhoshAppTracker *tracker = phosh_app_tracker_new();
    PhoshAppState *state = flatpak_start(tracker);
    unit_success();
    guint gone = 0;
    deliver(&proxy_pending, proxy_new(&gone), g_object_unref, FALSE);
    g_assert_nonnull(state->flatpak.unit_proxy);
    g_assert_true(state->flatpak.started);
    g_assert_cmpuint(gone, ==, 0);
    g_object_unref(tracker);
    g_assert_cmpuint(gone, ==, 1);
}
static void flatpak_errors(void)
{
    g_autoptr(PhoshAppTracker) tracker = phosh_app_tracker_new();
    flatpak_start(tracker);
    g_hash_table_remove(tracker->apps, "launch");
    deliver(&unit_pending, NULL, NULL, TRUE);
    flatpak_start(tracker);
    unit_success();
    g_hash_table_remove(tracker->apps, "launch");
    deliver(&proxy_pending, NULL, NULL, TRUE);
}
int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/tracker/timeout-remove", timeout_remove);
    g_test_add_func("/tracker/timeout-replace", timeout_replace);
    g_test_add_func("/tracker/timeout-release", timeout_release);
    g_test_add_func("/tracker/timeout-dispose", timeout_dispose);
    g_test_add_func("/tracker/ready-reentrant", ready_reentrant);
    g_test_add_func("/tracker/failure-replace", failure_replace);
    g_test_add_func("/tracker/dbus-reentrant", dbus_reentrant);
    g_test_add_func("/tracker/context-late", context_late);
    g_test_add_func("/tracker/context-multiple", context_multiple);
    g_test_add_func("/tracker/context-release", context_release);
    g_test_add_data_func("/tracker/bus-success", NULL, bus_test);
    g_test_add_data_func("/tracker/bus-error", GINT_TO_POINTER(1), bus_test);
    g_test_add_func("/tracker/flatpak-unit-retired", flatpak_unit_retired);
    g_test_add_func("/tracker/flatpak-proxy-retired", flatpak_proxy_retired);
    g_test_add_func("/tracker/flatpak-shutdown", flatpak_shutdown);
    g_test_add_func("/tracker/flatpak-normal", flatpak_normal);
    g_test_add_func("/tracker/flatpak-errors", flatpak_errors);
    return g_test_run();
}
