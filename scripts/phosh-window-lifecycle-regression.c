#include <gio/gio.h>

/* Only the desktop resolver is shimmed; GAppInfo/refcount dispatch remains real. */
typedef GAppInfo GDesktopAppInfo;
G_DEFINE_AUTOPTR_CLEANUP_FUNC (GDesktopAppInfo, g_object_unref)

/* Real GAppInfo interface dispatch with deterministic desktop IDs on macOS too. */
typedef struct { GObject parent; char *id; } FixtureApp;
typedef struct { GObjectClass parent; } FixtureAppClass;
static void fixture_app_iface_init (GAppInfoIface *iface);
G_DEFINE_TYPE_WITH_CODE (FixtureApp, fixture_app, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE (G_TYPE_APP_INFO, fixture_app_iface_init))
static const char *fixture_app_id (GAppInfo *app) { return ((FixtureApp *) app)->id; }
static gboolean fixture_app_equal (GAppInfo *a, GAppInfo *b)
{
  return g_strcmp0 (g_app_info_get_id (a), g_app_info_get_id (b)) == 0;
}
static void fixture_app_iface_init (GAppInfoIface *iface)
{
  iface->get_id = fixture_app_id;
  iface->equal = fixture_app_equal;
}
static void fixture_app_finalize (GObject *object)
{
  g_free (((FixtureApp *) object)->id);
  G_OBJECT_CLASS (fixture_app_parent_class)->finalize (object);
}
static void fixture_app_class_init (FixtureAppClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = fixture_app_finalize;
}
static void fixture_app_init (FixtureApp *self) {}
static GAppInfo *new_app (const char *id)
{
  FixtureApp *app = g_object_new (fixture_app_get_type (), NULL);
  app->id = g_strdup (id);
  return G_APP_INFO (app);
}

typedef GObject PhoshToplevel;
typedef GObject PhoshActivity;
typedef GObject PhoshOverview;
typedef GObject GtkWidget;
typedef GObject PhoshAppTracker;
typedef struct { int unused; } PhoshShell;
#define _(text) (text)
static guint notification_count;
static PhoshShell *phosh_shell_get_default (void)
{
  static PhoshShell shell;
  return &shell;
}
static void phosh_shell_show_notification_for_app (PhoshShell *shell, GAppInfo *info,
                                                  const char *message)
{
  g_assert_true (G_IS_APP_INFO (info));
  g_assert_nonnull (message);
  notification_count++;
}
typedef struct {
  GPtrArray *carousel_running_activities;
  PhoshActivity *activity;
} PhoshOverviewPrivate;
#define PHOSH_IS_OVERVIEW G_IS_OBJECT
#define PHOSH_IS_ACTIVITY G_IS_OBJECT
#define PHOSH_IS_TOPLEVEL G_IS_OBJECT
#define PHOSH_IS_TOPLEVEL_MANAGER(obj) G_IS_OBJECT (obj)
#define PHOSH_ACTIVITY(obj) ((PhoshActivity *) (obj))
#define GTK_WIDGET(obj) ((GtkWidget *) (obj))
#define GTK_CONTAINER(obj) (obj)

static const char *phosh_toplevel_get_app_id (PhoshToplevel *self)
{
  return g_object_get_data (self, "app-id");
}
static gboolean phosh_toplevel_is_configured (PhoshToplevel *self)
{
  return GPOINTER_TO_INT (g_object_get_data (self, "configured"));
}
static guint resolver_calls;
static GAppInfo *phosh_get_desktop_app_info_for_app_id (const char *id)
{
  resolver_calls++;
  if (g_strcmp0 (id, "org.gnome.TextEditor") == 0 ||
      g_strcmp0 (id, "gnome-text-editor") == 0)
    return new_app ("org.gnome.TextEditor.desktop");
  if (g_strcmp0 (id, "org.gnome.Settings") == 0)
    return new_app ("org.gnome.Settings.desktop");
  return NULL;
}
static PhoshOverviewPrivate *phosh_overview_get_instance_private (PhoshOverview *self)
{
  return g_object_get_data (self, "private");
}
static GList *gtk_container_get_children (GPtrArray *container)
{
  GList *children = NULL;
  for (guint i = 0; i < container->len; i++)
    children = g_list_prepend (children, g_ptr_array_index (container, i));
  return g_list_reverse (children);
}
static GAppInfo *phosh_activity_get_app_info (PhoshActivity *self)
{
  return g_object_get_data (self, "app-info");
}
static gboolean phosh_activity_get_has_thumbnail (PhoshActivity *self)
{
  return GPOINTER_TO_INT (g_object_get_data (self, "has-thumbnail"));
}
typedef struct { GObject parent; } FixtureWidget;
typedef struct { GObjectClass parent; } FixtureWidgetClass;
G_DEFINE_TYPE (FixtureWidget, fixture_widget, G_TYPE_OBJECT)
static void fixture_widget_init (FixtureWidget *self) {}
static void fixture_widget_class_init (FixtureWidgetClass *klass)
{
  g_signal_new ("destroy", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST,
                0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}
static void gtk_widget_destroy (GtkWidget *self)
{
  /* Deliberately do not clear overview selection: production code must do so. */
  PhoshOverviewPrivate *priv = g_object_get_data (self, "before-destroy-private");
  if (priv) {
    g_assert_null (priv->activity);
    g_object_set_data (self, "pre-destroy-checked", GINT_TO_POINTER (1));
  }
  g_assert_null (g_object_get_data (self, "destroyed"));
  g_object_set_data (self, "destroyed", GINT_TO_POINTER (1));
  g_signal_emit_by_name (self, "destroy");
  g_object_run_dispose (self);
}

typedef struct _PhoshToplevelManager {
  GObject parent;
  GPtrArray *toplevels;
  GPtrArray *toplevels_pending;
  GPtrArray *launching_apps;
} PhoshToplevelManager;
G_DEFINE_AUTOPTR_CLEANUP_FUNC (PhoshToplevelManager, g_object_unref)
typedef struct { GObjectClass parent; } PhoshToplevelManagerClass;
typedef struct {
  GAppInfo *app_info;
  guint timeout_id;
  PhoshToplevelManager *manager;
} LaunchingAppInfo;
enum { TOPLEVEL_MISSING, TOPLEVEL_ADDED, TOPLEVEL_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];
enum { PROP_0, PROP_NUM_TOPLEVELS, N_PROPS };
static GParamSpec *props[N_PROPS];
/* No waiting in tests: make the real source ready via g_source_set_ready_time. */
#define APP_TRACKER_MAX_INITIAL_TOPLEVEL_TIMEOUT 3600
static void launching_app_info_free (LaunchingAppInfo *info);
G_DEFINE_TYPE (PhoshToplevelManager, phosh_toplevel_manager, G_TYPE_OBJECT)
static void manager_finalize (GObject *object)
{
  PhoshToplevelManager *self = (PhoshToplevelManager *) object;
  g_ptr_array_unref (self->launching_apps);
  g_ptr_array_unref (self->toplevels);
  g_ptr_array_unref (self->toplevels_pending);
  G_OBJECT_CLASS (phosh_toplevel_manager_parent_class)->finalize (object);
}
static void manager_get_property (GObject *object, guint id, GValue *value, GParamSpec *spec)
{
  g_assert_cmpuint (id, ==, PROP_NUM_TOPLEVELS);
  g_value_set_uint (value, ((PhoshToplevelManager *) object)->toplevels->len);
}
static void phosh_toplevel_manager_class_init (PhoshToplevelManagerClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = manager_finalize;
  G_OBJECT_CLASS (klass)->get_property = manager_get_property;
  props[PROP_NUM_TOPLEVELS] = g_param_spec_uint ("num-toplevels", NULL, NULL, 0, G_MAXUINT, 0,
                                                G_PARAM_READABLE);
  g_object_class_install_properties (G_OBJECT_CLASS (klass), N_PROPS, props);
  signals[TOPLEVEL_MISSING] = g_signal_new ("toplevel-missing", G_TYPE_FROM_CLASS (klass),
      G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_APP_INFO);
  signals[TOPLEVEL_ADDED] = g_signal_new ("toplevel-added", G_TYPE_FROM_CLASS (klass),
      G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_OBJECT);
  signals[TOPLEVEL_CHANGED] = g_signal_new ("toplevel-changed", G_TYPE_FROM_CLASS (klass),
      G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_OBJECT);
}
static void phosh_toplevel_manager_init (PhoshToplevelManager *self)
{
  self->toplevels = g_ptr_array_new_with_free_func (g_object_unref);
  self->toplevels_pending = g_ptr_array_new ();
  self->launching_apps = g_ptr_array_new_with_free_func ((GDestroyNotify) launching_app_info_free);
}

/* Function bodies are extracted verbatim, never maintained as copies here. */
#include "extracted-lifecycle.h"

static PhoshToplevelManager *new_manager (void)
{
  return g_object_new (phosh_toplevel_manager_get_type (), NULL);
}
static PhoshToplevel *new_toplevel (const char *id)
{
  GObject *toplevel = g_object_new (G_TYPE_OBJECT, NULL);
  g_object_set_data_full (toplevel, "app-id", g_strdup (id), g_free);
  return toplevel;
}
static LaunchingAppInfo *add_launch (PhoshToplevelManager *manager, GAppInfo *app)
{
  LaunchingAppInfo *info = launching_app_info_new (manager, app);
  g_ptr_array_add (manager->launching_apps, info);
  g_assert_nonnull (g_main_context_find_source_by_id (NULL, info->timeout_id));
  return info;
}
static void fire_timeout (guint id)
{
  GSource *source = g_main_context_find_source_by_id (NULL, id);
  g_assert_nonnull (source);
  g_source_set_ready_time (source, 0);
  for (guint i = 0; i < 100 && g_main_context_find_source_by_id (NULL, id); i++)
    g_main_context_iteration (NULL, FALSE);
  g_assert_null (g_main_context_find_source_by_id (NULL, id));
}
static void test_valid_id_cancels_timeout (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GAppInfo) other = new_app ("org.gnome.Settings.desktop");
  g_autoptr (GObject) top = new_toplevel ("gnome-text-editor");
  guint cancelled = add_launch (manager, app)->timeout_id;
  LaunchingAppInfo *retained = add_launch (manager, other);
  remove_from_launching (manager, top);
  g_assert_cmpuint (manager->launching_apps->len, ==, 1);
  g_assert_true (g_ptr_array_index (manager->launching_apps, 0) == retained);
  g_assert_null (g_main_context_find_source_by_id (NULL, cancelled));
  g_assert_nonnull (g_main_context_find_source_by_id (NULL, retained->timeout_id));
  fire_timeout (retained->timeout_id);
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_object_unref (manager);
}
static void test_null_id_ignored (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GObject) top = new_toplevel (NULL);
  LaunchingAppInfo *info = add_launch (manager, app);
  resolver_calls = 0;
  remove_from_launching (manager, top);
  g_assert_cmpuint (resolver_calls, ==, 0);
  g_assert_cmpuint (manager->launching_apps->len, ==, 1);
  g_assert_nonnull (g_main_context_find_source_by_id (NULL, info->timeout_id));
  g_object_unref (manager);
}
static void test_unknown_id_retained (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GObject) top = new_toplevel ("unknown.app");
  LaunchingAppInfo *info = add_launch (manager, app);
  remove_from_launching (manager, top);
  g_assert_cmpuint (manager->launching_apps->len, ==, 1);
  g_assert_true (g_ptr_array_index (manager->launching_apps, 0) == info);
  g_assert_nonnull (g_main_context_find_source_by_id (NULL, info->timeout_id));
  g_object_unref (manager);
}
static void test_desktop_alias_already_mapped (void)
{
  const char *aliases[] = { "org.gnome.TextEditor", "gnome-text-editor" };
  for (guint i = 0; i < G_N_ELEMENTS (aliases); i++) {
    PhoshToplevelManager *manager = new_manager ();
    g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
    g_autoptr (GAppInfo) other = new_app ("org.gnome.Settings.desktop");
    g_ptr_array_add (manager->toplevels, new_toplevel (NULL));
    g_ptr_array_add (manager->toplevels, new_toplevel ("unknown.app"));
    g_ptr_array_add (manager->toplevels, new_toplevel (aliases[i]));
    g_assert_true (app_info_has_toplevel (manager, app));
    on_app_launched (manager, app, "editor-startup");
    g_assert_cmpuint (manager->launching_apps->len, ==, 0);
    g_assert_false (app_info_has_toplevel (manager, other));
    on_app_launched (manager, other, "settings-startup");
    g_assert_cmpuint (manager->launching_apps->len, ==, 1);
    g_object_unref (manager);
  }
}

static void test_duplicate_launches_cancelled (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GAppInfo) other = new_app ("org.gnome.Settings.desktop");
  g_autoptr (GObject) top = new_toplevel ("org.gnome.TextEditor");
  guint ids[3];
  ids[0] = add_launch (manager, app)->timeout_id;
  LaunchingAppInfo *retained = add_launch (manager, other);
  ids[1] = add_launch (manager, app)->timeout_id;
  ids[2] = add_launch (manager, app)->timeout_id;
  remove_from_launching (manager, top);
  g_assert_cmpuint (manager->launching_apps->len, ==, 1);
  g_assert_true (g_ptr_array_index (manager->launching_apps, 0) == retained);
  for (guint i = 0; i < G_N_ELEMENTS (ids); i++)
    g_assert_null (g_main_context_find_source_by_id (NULL, ids[i]));
  g_assert_nonnull (g_main_context_find_source_by_id (NULL, retained->timeout_id));
  g_object_unref (manager);
}
static void test_empty_launches_skip_resolver (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GObject) top = new_toplevel ("org.gnome.TextEditor");
  resolver_calls = 0;
  remove_from_launching (manager, top);
  g_assert_cmpuint (resolver_calls, ==, 0);
  g_object_unref (manager);
}
static void test_late_app_id_configure (void)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  PhoshToplevel *top = new_toplevel (NULL);
  guint timeout = add_launch (manager, app)->timeout_id;
  g_ptr_array_add (manager->toplevels_pending, top);
  on_toplevel_configured (manager, NULL, top);
  g_assert_cmpuint (manager->toplevels->len, ==, 0);
  g_object_set_data (top, "configured", GINT_TO_POINTER (TRUE));
  on_toplevel_configured (manager, NULL, top);
  g_assert_cmpuint (manager->toplevels->len, ==, 1);
  g_assert_cmpuint (manager->toplevels_pending->len, ==, 0);
  g_assert_cmpuint (manager->launching_apps->len, ==, 1);
  g_object_set_data_full (top, "app-id", g_strdup ("gnome-text-editor"), g_free);
  on_toplevel_configured (manager, NULL, top);
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_assert_null (g_main_context_find_source_by_id (NULL, timeout));
  resolver_calls = 0;
  on_toplevel_configured (manager, NULL, top);
  g_assert_cmpuint (resolver_calls, ==, 0);
  g_object_unref (manager);
}

typedef struct {
  PhoshToplevelManager *owner;
  gpointer weak_manager;
  gpointer weak_app;
  guint calls;
} Reentry;
static void reenter_timeout (PhoshToplevelManager *manager, GAppInfo *app, Reentry *state)
{
  /* This assertion fails before reentry can trigger the old use-after-free. */
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_assert_cmpstr (g_app_info_get_id (app), ==, "org.gnome.TextEditor.desktop");
  g_autoptr (GObject) top = new_toplevel ("gnome-text-editor");
  on_app_launched (manager, app, "reentrant-launch");
  LaunchingAppInfo *replacement = g_ptr_array_index (manager->launching_apps, 0);
  guint id = replacement->timeout_id;
  remove_from_launching (manager, top);
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_assert_null (g_main_context_find_source_by_id (NULL, id));
  g_clear_object (&state->owner);
  g_assert_nonnull (state->weak_manager);
  g_assert_nonnull (state->weak_app);
  state->calls++;
}
static void observe_after_reentry (PhoshToplevelManager *manager, GAppInfo *app, Reentry *state)
{
  g_assert_cmpuint (state->calls, ==, 1);
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_assert_true (G_IS_APP_INFO (app));
  g_assert_nonnull (state->weak_manager);
  g_assert_nonnull (state->weak_app);
  state->calls++;
}
static void test_timeout_reentrancy (void)
{
  PhoshToplevelManager *manager = new_manager ();
  GAppInfo *app = new_app ("org.gnome.TextEditor.desktop");
  Reentry state = { manager, manager, app, 0 };
  g_object_add_weak_pointer (G_OBJECT (manager), &state.weak_manager);
  g_object_add_weak_pointer (G_OBJECT (app), &state.weak_app);
  g_signal_connect (manager, "toplevel-missing", G_CALLBACK (reenter_timeout), &state);
  g_signal_connect (manager, "toplevel-missing", G_CALLBACK (observe_after_reentry), &state);
  guint id = add_launch (manager, app)->timeout_id;
  g_object_unref (app);
  fire_timeout (id);
  g_assert_cmpuint (state.calls, ==, 2);
  g_assert_null (state.owner);
  g_assert_null (state.weak_manager);
  g_assert_null (state.weak_app);
}

static PhoshActivity *new_activity (GAppInfo *app, gboolean thumbnail, PhoshToplevel *top)
{
  GObject *activity = g_object_new (fixture_widget_get_type (), NULL);
  g_object_set_data_full (activity, "app-info", g_object_ref (app), g_object_unref);
  g_object_set_data (activity, "has-thumbnail", GINT_TO_POINTER (thumbnail));
  if (top)
    g_object_set_data_full (activity, "toplevel", g_object_ref (top), g_object_unref);
  return activity;
}
static void overview_timeout_case (gboolean mapped, gboolean thumbnail, gboolean selected)
{
  PhoshToplevelManager *manager = new_manager ();
  g_autoptr (GObject) overview = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GAppInfo) other = new_app ("org.gnome.Settings.desktop");
  g_autoptr (GObject) top = mapped ? new_toplevel ("org.gnome.TextEditor") : NULL;
  g_autoptr (GObject) activity = new_activity (app, thumbnail, top);
  g_assert_cmpint (phosh_activity_get_has_thumbnail (activity), ==, thumbnail);
  g_autoptr (GObject) unrelated = new_activity (other, FALSE, NULL);
  g_autoptr (GPtrArray) children = g_ptr_array_new ();
  PhoshOverviewPrivate priv = { children, selected ? activity : unrelated };
  g_ptr_array_add (children, unrelated);
  g_ptr_array_add (children, activity);
  g_object_set_data (overview, "private", &priv);
  fixture_connect_activity (overview, activity);
  fixture_connect_activity (overview, unrelated);
  g_signal_connect_swapped (manager, "toplevel-missing", G_CALLBACK (on_toplevel_missing), overview);
  guint timeout = add_launch (manager, app)->timeout_id;
  if (!mapped)
    g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, "*didn't present a toplevel*hiding splash*");
  fire_timeout (timeout);
  if (!mapped)
    g_test_assert_expected_messages ();
  g_assert_cmpuint (manager->launching_apps->len, ==, 0);
  g_assert_cmpint (GPOINTER_TO_INT (g_object_get_data (activity, "destroyed")), ==, !mapped);
  g_assert_null (g_object_get_data (unrelated, "destroyed"));
  g_assert_true (priv.activity == (selected ? (mapped ? activity : NULL) : unrelated));
  g_object_unref (manager);
}
static void test_mapped_without_thumbnail (void) { overview_timeout_case (TRUE, FALSE, TRUE); }
static void test_mapped_with_thumbnail (void) { overview_timeout_case (TRUE, TRUE, TRUE); }
static void test_unmapped_selected_cleared (void) { overview_timeout_case (FALSE, FALSE, TRUE); }
static void test_unmapped_unselected (void) { overview_timeout_case (FALSE, FALSE, FALSE); }
static void test_missing_activity_ignored (void)
{
  g_autoptr (GObject) overview = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GPtrArray) children = g_ptr_array_new ();
  PhoshOverviewPrivate priv = { children, NULL };
  g_object_set_data (overview, "private", &priv);
  on_toplevel_missing (overview, app);
  g_assert_null (priv.activity);
}

static void overview_failure_case (gboolean mapped, const char *startup_id, gboolean destroy)
{
  g_autoptr (GObject) overview = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GObject) top = mapped ? new_toplevel ("org.gnome.TextEditor") : NULL;
  g_autoptr (GObject) activity = new_activity (app, FALSE, top);
  g_autoptr (GPtrArray) children = g_ptr_array_new ();
  PhoshOverviewPrivate priv = { children, activity };
  g_ptr_array_add (children, activity);
  g_object_set_data (overview, "private", &priv);
  g_object_set_data (activity, "startup-id", "new-startup");
  fixture_connect_activity (overview, activity);
  notification_count = 0;
  on_app_failed (overview, app, startup_id, NULL);
  g_assert_cmpint (GPOINTER_TO_INT (g_object_get_data (activity, "destroyed")), ==, destroy);
  g_assert_cmpuint (notification_count, ==, destroy ? 1 : 0);
  g_assert_true (priv.activity == (destroy ? NULL : activity));
  g_assert_cmpstr (g_object_get_data (activity, "startup-id"), ==, "new-startup");
  if (mapped)
    g_assert_true (g_object_get_data (activity, "toplevel") == top);
}
static void test_stale_failure_keeps_newer_splash (void)
{
  overview_failure_case (FALSE, "old-startup", FALSE);
}
static void test_matching_failure_destroys_splash (void)
{
  overview_failure_case (FALSE, "new-startup", TRUE);
}
static void test_mapped_survives_matching_failure (void)
{
  overview_failure_case (TRUE, "new-startup", FALSE);
}
static void test_close_clears_selection_before_destroy (void)
{
  g_autoptr (GObject) overview = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GAppInfo) app = new_app ("org.gnome.TextEditor.desktop");
  g_autoptr (GObject) top = new_toplevel ("org.gnome.TextEditor");
  g_autoptr (GObject) activity = new_activity (app, FALSE, top);
  g_autoptr (GPtrArray) children = g_ptr_array_new ();
  PhoshOverviewPrivate priv = { children, activity };
  g_ptr_array_add (children, activity);
  g_object_set_data (overview, "private", &priv);
  g_object_set_data (activity, "before-destroy-private", &priv);
  fixture_connect_activity (overview, activity);
  on_toplevel_closed (top, overview);
  g_assert_nonnull (g_object_get_data (activity, "destroyed"));
  g_assert_nonnull (g_object_get_data (activity, "pre-destroy-checked"));
  g_assert_null (priv.activity);
  g_assert_null (g_object_get_data (activity, "toplevel"));
}
int main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/manager/valid-id-cancels-timeout", test_valid_id_cancels_timeout);
  g_test_add_func ("/manager/null-id-ignored", test_null_id_ignored);
  g_test_add_func ("/manager/unknown-id-retained", test_unknown_id_retained);
  g_test_add_func ("/manager/desktop-alias-already-mapped", test_desktop_alias_already_mapped);
  g_test_add_func ("/manager/duplicate-launches-cancelled", test_duplicate_launches_cancelled);
  g_test_add_func ("/manager/empty-launches-skip-resolver", test_empty_launches_skip_resolver);
  g_test_add_func ("/manager/late-app-id-configure", test_late_app_id_configure);
  g_test_add_func ("/manager/timeout-reentrancy", test_timeout_reentrancy);
  g_test_add_func ("/overview/mapped-without-thumbnail", test_mapped_without_thumbnail);
  g_test_add_func ("/overview/mapped-with-thumbnail", test_mapped_with_thumbnail);
  g_test_add_func ("/overview/unmapped-selected-cleared", test_unmapped_selected_cleared);
  g_test_add_func ("/overview/unmapped-unselected", test_unmapped_unselected);
  g_test_add_func ("/overview/missing-activity-ignored", test_missing_activity_ignored);
  g_test_add_func ("/overview/stale-failure-keeps-newer-splash", test_stale_failure_keeps_newer_splash);
  g_test_add_func ("/overview/matching-failure-destroys-splash", test_matching_failure_destroys_splash);
  g_test_add_func ("/overview/mapped-survives-matching-failure", test_mapped_survives_matching_failure);
  g_test_add_func ("/overview/close-clears-selection-before-destroy", test_close_clears_selection_before_destroy);
  return g_test_run ();
}
