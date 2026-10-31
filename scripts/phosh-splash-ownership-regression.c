#include <gio/gio.h>
#include <gio/gdesktopappinfo.h>
#include "app-tracker.h"

/* Real signal ownership and manager callbacks; no GTK display or settings. */
struct _PhoshAppTracker { GObject parent; };
G_DEFINE_TYPE(PhoshAppTracker, phosh_app_tracker, G_TYPE_OBJECT)
static void phosh_app_tracker_init(PhoshAppTracker *self) {}
static void phosh_app_tracker_class_init(PhoshAppTrackerClass *klass)
{
    const char *names[] = {"app-launch-started", "app-ready", "app-failed"};
    for (guint i = 0; i < G_N_ELEMENTS(names); ++i)
        g_signal_new(names[i], G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0,
                     NULL, NULL, NULL, G_TYPE_NONE, 2, G_TYPE_DESKTOP_APP_INFO, G_TYPE_STRING);
}

typedef GObject GtkWidget;
typedef GObject PhoshSplash;
typedef GObject PhoshShell;
#define GTK_WINDOW(x) (x)
#define PHOSH_SPLASH(x) ((PhoshSplash *)(x))
#define PHOSH_IS_SPLASH(x) G_IS_OBJECT(x)
#define G_DESKTOP_COLOR_SCHEME_PREFER_DARK 1
#define PHOSH_TYPE_SPLASH_MANAGER (phosh_splash_manager_get_type())
G_DECLARE_FINAL_TYPE(PhoshSplashManager, phosh_splash_manager, PHOSH, SPLASH_MANAGER, GObject)
static GObject *last_splash;
static guint hidden;
static PhoshShell *phosh_shell_get_default(void) { return NULL; }
static gboolean phosh_shell_get_show_splash(PhoshShell *shell) { return TRUE; }
static GtkWidget *phosh_splash_new(GDesktopAppInfo *info, gboolean dark)
{
    last_splash = g_object_new(G_TYPE_OBJECT, NULL);
    return last_splash;
}
/* Like the real fadeout, hide does not synchronously destroy the widget. */
static void phosh_splash_hide(PhoshSplash *splash) { ++hidden; }
static void phosh_splash_lower(PhoshSplash *splash) {}
static void phosh_splash_raise(PhoshSplash *splash) {}
static void gtk_window_present(GtkWidget *splash) {}
#include "splash.inc"

static GDesktopAppInfo *info_new(void)
{
    GDesktopAppInfo *info = g_desktop_app_info_new_from_filename(g_getenv("TRACKER_DESKTOP"));
    g_assert_nonnull(info);
    return info;
}
static void start(PhoshAppTracker *tracker)
{
    g_autoptr(GDesktopAppInfo) info = info_new();
    g_signal_emit_by_name(tracker, "app-launch-started", info, "launch");
}
static void terminal(PhoshAppTracker *tracker, const char *signal)
{
    g_autoptr(GDesktopAppInfo) info = info_new();
    g_signal_emit_by_name(tracker, signal, info, "launch");
}
static void detached(gboolean explicit_dispose)
{
    g_autoptr(PhoshAppTracker) tracker = g_object_new(PHOSH_TYPE_APP_TRACKER, NULL);
    PhoshSplashManager *manager = phosh_splash_manager_new(tracker);
    gpointer identity = manager;
    if (explicit_dispose) {
        g_object_run_dispose(G_OBJECT(manager));
        g_object_run_dispose(G_OBJECT(manager));
    } else {
        g_object_unref(manager);
    }
    /* Check before emitting: baseline must not invoke a known dangling pointer. */
    g_assert_cmpuint(g_signal_handler_find(tracker, G_SIGNAL_MATCH_DATA,
                                          0, 0, NULL, NULL, identity), ==, 0);
    last_splash = NULL;
    start(tracker);
    terminal(tracker, "app-failed");
    terminal(tracker, "app-ready");
    g_assert_null(last_splash);
    if (explicit_dispose) {
        g_assert_cmpuint(g_hash_table_size(manager->splashes), ==, 0);
        g_object_unref(manager);
    }
}
static void finalized(void) { detached(FALSE); }
static void disposed(void) { detached(TRUE); }
static void close_removes(void)
{
    g_autoptr(PhoshAppTracker) tracker = g_object_new(PHOSH_TYPE_APP_TRACKER, NULL);
    g_autoptr(PhoshSplashManager) manager = phosh_splash_manager_new(tracker);
    start(tracker);
    GObject *splash = last_splash;
    hidden = 0;
    g_signal_emit_by_name(splash, "closed");
    g_assert_cmpuint(g_hash_table_size(manager->splashes), ==, 0);
    g_assert_cmpuint(hidden, ==, 1);
    g_signal_emit_by_name(splash, "closed");
    g_assert_cmpuint(hidden, ==, 1);
    g_object_unref(splash);
}
static void close_retired(void)
{
    g_autoptr(PhoshAppTracker) tracker = g_object_new(PHOSH_TYPE_APP_TRACKER, NULL);
    g_autoptr(PhoshSplashManager) manager = phosh_splash_manager_new(tracker);
    start(tracker);
    GObject *old = last_splash;
    /* Splash metadata must not borrow the hash key, freed on retirement. */
    gpointer key;
    g_assert_true(g_hash_table_lookup_extended(manager->splashes, "launch", &key, NULL));
    g_assert_true(key != g_object_get_data(old, "startup-id"));
    terminal(tracker, "app-failed");
    start(tracker);
    GObject *replacement = last_splash;
    g_signal_emit_by_name(old, "closed");
    g_assert_true(g_hash_table_lookup(manager->splashes, "launch") == replacement);
    terminal(tracker, "app-ready");
    g_signal_emit_by_name(replacement, "closed");
    g_object_unref(old);
    g_object_unref(replacement);
}
static void close_after_manager(void)
{
    g_autoptr(PhoshAppTracker) tracker = g_object_new(PHOSH_TYPE_APP_TRACKER, NULL);
    PhoshSplashManager *manager = phosh_splash_manager_new(tracker);
    start(tracker);
    GObject *splash = last_splash;
    g_object_unref(manager);
    g_signal_emit_by_name(splash, "closed");
    g_object_unref(splash);
}
int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_signal_new("closed", G_TYPE_OBJECT, G_SIGNAL_RUN_LAST, 0,
                 NULL, NULL, NULL, G_TYPE_NONE, 0);
    g_test_add_func("/splash/finalized", finalized);
    g_test_add_func("/splash/disposed", disposed);
    g_test_add_func("/splash/close-removes", close_removes);
    g_test_add_func("/splash/close-retired", close_retired);
    g_test_add_func("/splash/close-after-manager", close_after_manager);
    return g_test_run();
}
