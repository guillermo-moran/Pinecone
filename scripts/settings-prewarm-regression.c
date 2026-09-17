/* Production lifecycle functions, real GLib sources/references, fake GTK window. */
#include <gio/gio.h>
#include <glib/gstdio.h>

typedef GApplication AdwApplication;
typedef GObject CcShellModel;
typedef GObject CcWindow;
typedef struct _CcApplication CcApplication;
typedef GApplicationClass CcApplicationClass;

#define CC_APPLICATION(value) ((CcApplication *) (value))
#define GTK_APPLICATION(value) G_APPLICATION (value)
#define GTK_WIDGET(value) (value)
#define GTK_WINDOW(value) (value)
#define CC_SHELL(value) (value)

#include "settings-types.inc"

static void cc_application_activate (GApplication *application);
static void cc_application_shutdown (GApplication *application);
static void cc_application_finalize (GObject *object);
static void cc_application_quit (GSimpleAction *, GVariant *, gpointer);

G_DEFINE_TYPE (CcApplication, cc_application, G_TYPE_APPLICATION)

static gboolean visible;
static double opacity;
static guint hide_count;
static guint window_count;
static guint panel_count;
static guint search_count;
static guint single_panel_count;
static void (*present_hook) (CcApplication *);
static GVariantDict *command_options;

static CcWindow *
cc_window_new (GApplication *application, CcShellModel *model)
{
  CcWindow *window = g_object_new (G_TYPE_OBJECT, NULL);
  g_object_set_data (window, "application", application);
  window_count++;
  return window;
}

static void
gtk_widget_set_visible (CcWindow *window, gboolean value)
{
  g_assert_true (G_IS_OBJECT (window));
  visible = value;
  if (!value)
    hide_count++;
}

static void
gtk_widget_set_opacity (CcWindow *window, double value)
{
  g_assert_true (G_IS_OBJECT (window));
  opacity = value;
}

static void
gtk_window_present (CcWindow *window)
{
  g_assert_true (G_IS_OBJECT (window));
  visible = TRUE;
  if (present_hook)
    {
      void (*hook) (CcApplication *) = present_hook;
      present_hook = NULL;
      hook (g_object_get_data (window, "application"));
    }
}

static void
gtk_window_destroy (CcWindow *window)
{
  visible = FALSE;
  g_object_unref (window);
}

static void cc_log_init (void) {}
static void cc_object_storage_destroy (void) {}

static void
cc_window_set_search_item (CcWindow *window, const char *search)
{
  g_assert_true (visible);
  g_assert_cmpfloat (opacity, ==, 1.0);
  search_count++;
}

static gboolean
cc_shell_set_active_panel_from_id (CcWindow *window, const char *id,
                                   GVariant *parameters, GError **error)
{
  g_assert_true (visible);
  g_assert_cmpfloat (opacity, ==, 1.0);
  panel_count++;
  return TRUE;
}

static void
cc_window_enable_single_panel_mode (CcWindow *window)
{
  single_panel_count++;
}

#define g_application_command_line_get_options_dict(unused) command_options
#include "settings-lifecycle.inc"

static void
cc_application_class_init (CcApplicationClass *klass)
{
  G_APPLICATION_CLASS (klass)->activate = cc_application_activate;
  G_APPLICATION_CLASS (klass)->shutdown = cc_application_shutdown;
  G_OBJECT_CLASS (klass)->finalize = cc_application_finalize;
}

static void cc_application_init (CcApplication *self) {}

static CcApplication *
new_application (void)
{
  CcApplication *self = g_object_new (cc_application_get_type (),
                                    "flags", G_APPLICATION_NON_UNIQUE, NULL);
  g_assert_true (g_application_register (G_APPLICATION (self), NULL, NULL));
  visible = FALSE;
  opacity = 1.0;
  hide_count = window_count = panel_count = search_count = single_panel_count = 0;
  present_hook = NULL;
  g_unlink (g_getenv ("PINECONE_SETTINGS_PREWARM_READY_FILE"));
  return self;
}

static void
free_application (CcApplication *self)
{
  cc_application_quit (NULL, NULL, self);
  cc_application_quit (NULL, NULL, self);
  g_assert_null (self->window);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (self->pinecone_prewarm_held);
  gpointer weak = self;
  g_object_add_weak_pointer (G_OBJECT (self), &weak);
  g_object_unref (self);
  g_assert_null (weak);
}

static void
run_command (CcApplication *self, gboolean prewarm, gboolean search)
{
  command_options = g_variant_dict_new (NULL);
  if (prewarm)
    g_variant_dict_insert (command_options, "pinecone-prewarm", "b", TRUE);
  if (search)
    g_variant_dict_insert (command_options, "search", "s", "display");
  g_assert_cmpint (cc_application_command_line (G_APPLICATION (self), NULL), ==, 0);
  g_variant_dict_unref (command_options);
  command_options = NULL;
}

static void
drain_timers (void)
{
  g_usleep (60000);
  while (g_main_context_iteration (NULL, FALSE)) {}
}

static void
assert_interactive (CcApplication *self)
{
  g_assert_cmpint (self->pinecone_prewarm_state, ==, PINECONE_PREWARM_INTERACTIVE);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (self->pinecone_prewarm_held);
  g_assert_true (visible);
  g_assert_cmpfloat (opacity, ==, 1.0);
}

static gboolean
ready_file_exists (void)
{
  return g_file_test (g_getenv ("PINECONE_SETTINGS_PREWARM_READY_FILE"), G_FILE_TEST_EXISTS);
}

static void
test_default_off (void)
{
  CcApplication *self = new_application ();
  g_assert_cmpint (self->pinecone_prewarm_state, ==, PINECONE_PREWARM_OFF);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  run_command (self, FALSE, FALSE);
  assert_interactive (self);
  run_command (self, TRUE, FALSE);
  drain_timers ();
  assert_interactive (self);
  g_assert_cmpuint (hide_count, ==, 0);
  g_assert_false (ready_file_exists ());
  free_application (self);
}

static void
test_finish_then_activate (void)
{
  CcApplication *self = new_application ();
  run_command (self, TRUE, FALSE);
  guint id = self->pinecone_prewarm_source_id;
  g_assert_cmpuint (id, !=, 0);
  g_assert_true (self->pinecone_prewarm_held);
  g_assert_cmpfloat (opacity, ==, 0.0);
  g_assert_cmpint (g_source_get_priority (g_main_context_find_source_by_id (NULL, id)),
                   ==, G_PRIORITY_LOW);
  run_command (self, TRUE, FALSE);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, id);
  drain_timers ();
  g_assert_cmpint (self->pinecone_prewarm_state, ==, PINECONE_PREWARM_READY);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (visible);
  g_assert_cmpfloat (opacity, ==, 1.0);
  g_assert_true (ready_file_exists ());
  run_command (self, TRUE, FALSE);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (visible);
  g_application_activate (G_APPLICATION (self));
  drain_timers ();
  assert_interactive (self);
  g_assert_cmpuint (hide_count, ==, 1);
  g_assert_cmpuint (window_count, ==, 1);
  free_application (self);
}

static gboolean
activate_from_source (gpointer data)
{
  g_application_activate (G_APPLICATION (data));
  return G_SOURCE_REMOVE;
}

static void
test_activation_race (gconstpointer data)
{
  CcApplication *self = new_application ();
  run_command (self, TRUE, FALSE);
  guint id = self->pinecone_prewarm_source_id;
  switch (GPOINTER_TO_INT (data))
    {
    case 0: g_application_activate (G_APPLICATION (self)); break;
    case 1: run_command (self, FALSE, TRUE); g_assert_cmpuint (search_count, ==, 1); break;
    case 2:
    case 3:
      {
        GVariant *args = g_variant_ref_sink (g_variant_new ("(s@av)", "display",
            g_variant_new_array (G_VARIANT_TYPE_VARIANT, NULL, 0)));
        if (GPOINTER_TO_INT (data) == 2)
          launch_panel_activated (NULL, args, self);
        else
          {
            launch_single_panel_mode_activated (NULL, args, self);
            g_assert_cmpuint (single_panel_count, ==, 1);
          }
        g_variant_unref (args);
        g_assert_cmpuint (panel_count, ==, 1);
        break;
      }
    case 4:
      /* Both sources are ready; interactive priority must cancel the hide. */
      g_usleep (60000);
      g_idle_add_full (G_PRIORITY_DEFAULT, activate_from_source, self, NULL);
      while (g_main_context_iteration (NULL, FALSE)) {}
      break;
    default: g_assert_not_reached ();
    }
  g_assert_null (g_main_context_find_source_by_id (NULL, id));
  assert_interactive (self);
  run_command (self, TRUE, FALSE);
  drain_timers ();
  assert_interactive (self);
  g_assert_cmpuint (hide_count, ==, 0);
  g_assert_false (ready_file_exists ());
  free_application (self);
}

static void activate_hook (CcApplication *self) { g_application_activate (G_APPLICATION (self)); }
static void quit_hook (CcApplication *self) { cc_application_quit (NULL, NULL, self); }

static void
test_reentrant_presentation (gconstpointer data)
{
  CcApplication *self = new_application ();
  present_hook = GPOINTER_TO_INT (data) ? quit_hook : activate_hook;
  run_command (self, TRUE, FALSE);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (self->pinecone_prewarm_held);
  drain_timers ();
  if (!GPOINTER_TO_INT (data))
    assert_interactive (self);
  else
    g_assert_null (self->window);
  g_assert_cmpuint (hide_count, ==, 0);
  g_assert_false (ready_file_exists ());
  free_application (self);
}

static void
test_cleanup (gconstpointer data)
{
  CcApplication *self = new_application ();
  run_command (self, TRUE, FALSE);
  guint id = self->pinecone_prewarm_source_id;
  if (GPOINTER_TO_INT (data) != 0)
    {
      gtk_window_destroy (self->window);
      g_assert_null (self->window);
    }
  if (GPOINTER_TO_INT (data) == 2)
    drain_timers ();
  else if (GPOINTER_TO_INT (data) == 3)
    g_signal_emit_by_name (self, "shutdown");
  else
    cc_application_quit (NULL, NULL, self);
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_null (g_main_context_find_source_by_id (NULL, id));
  g_assert_false (self->pinecone_prewarm_held);
  drain_timers ();
  g_assert_cmpuint (hide_count, ==, 0);
  g_assert_false (ready_file_exists ());
  free_application (self);
}

static void
test_weak_pointer_cleanup (void)
{
  CcApplication *self = new_application ();
  run_command (self, TRUE, FALSE);
  CcWindow *window = self->window;
  g_signal_emit_by_name (self, "shutdown");
  g_assert_cmpuint (self->pinecone_prewarm_source_id, ==, 0);
  g_assert_false (self->pinecone_prewarm_held);
  g_assert_cmpfloat (opacity, ==, 1.0);
  gpointer weak = self;
  g_object_add_weak_pointer (G_OBJECT (self), &weak);
  g_object_unref (self);
  g_assert_null (weak);
  /* A surviving window must not write through a weak pointer into freed self. */
  g_object_unref (window);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/settings/default-off-and-late-prewarm", test_default_off);
  g_test_add_func ("/settings/finish-duplicate-and-activate", test_finish_then_activate);
  const char *races[] = { "activate", "search", "panel", "single-panel", "both-ready" };
  for (guint i = 0; i < G_N_ELEMENTS (races); i++)
    {
      g_autofree char *name = g_strconcat ("/settings/race/", races[i], NULL);
      g_test_add_data_func (name, GINT_TO_POINTER (i), test_activation_race);
    }
  g_test_add_data_func ("/settings/reentrant/activate", GINT_TO_POINTER (0), test_reentrant_presentation);
  g_test_add_data_func ("/settings/reentrant/quit", GINT_TO_POINTER (1), test_reentrant_presentation);
  const char *cleanup[] = { "quit", "quit-without-window", "destroy-before-timeout", "shutdown-without-window" };
  for (guint i = 0; i < G_N_ELEMENTS (cleanup); i++)
    {
      g_autofree char *name = g_strconcat ("/settings/cleanup/", cleanup[i], NULL);
      g_test_add_data_func (name, GINT_TO_POINTER (i), test_cleanup);
    }
  g_test_add_func ("/settings/cleanup/window-outlives-application", test_weak_pointer_cleanup);
  return g_test_run ();
}
