/*
 * Compile the actual patched Phoc transaction and layer callback bodies.
 * Only Wayland/output rendering dependencies are replaced with test doubles.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "layout-transaction.c"

struct wl_list { struct wl_list *prev, *next; };
struct wl_listener { struct wl_list link; };
struct wlr_box { int x, y, width, height; };
struct wlr_output { void *data; };
struct surface_state { int width, height; };
#define WLR_PRIVATE private
struct wlr_surface {
  struct surface_state current;
  struct { struct surface_state previous; bool unmap_commit; } WLR_PRIVATE;
  bool has_buffer;
};
enum zwlr_layer_shell_v1_layer { TEST_LAYER };
#define WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE 1u
struct wlr_layer_surface_v1 {
  struct wlr_output *output;
  struct wlr_surface *surface;
  struct {
    guint32 committed, configure_serial;
    enum zwlr_layer_shell_v1_layer layer;
  } current;
  bool configured;
  bool initialized;
};
typedef struct { int unused; } PhocOutput;
typedef struct { int unused; } PhocInput;
typedef struct _PhocLayerSurface PhocLayerSurface;
typedef GObjectClass PhocLayerSurfaceClass;
#include "layer-struct.inc"
#define PHOC_OUTPUT(value) ((PhocOutput *) (value))
#define PHOC_LAYER_SURFACE(value) ((PhocLayerSurface *) (value))
#define PHOC_IS_LAYER_SURFACE(value) G_TYPE_CHECK_INSTANCE_TYPE (value, phoc_layer_surface_get_type ())
#define wl_container_of(ptr, sample, member) \
  ((__typeof__(sample)) ((char *) (ptr) - offsetof (__typeof__(*sample), member)))

static PhocOutput test_output;
static guint32 next_serial;
static void (*arrange_hook) (void);
G_DEFINE_TYPE (PhocLayerSurface, phoc_layer_surface, G_TYPE_OBJECT)
G_DEFINE_AUTOPTR_CLEANUP_FUNC (PhocLayerSurface, g_object_unref)

static void
test_surface_finalize (GObject *object)
{
  PhocLayerSurface *surface = PHOC_LAYER_SURFACE (object);
  g_free (surface->layer_surface->surface);
  g_free (surface->layer_surface->output);
  g_free (surface->layer_surface);
  G_OBJECT_CLASS (phoc_layer_surface_parent_class)->finalize (object);
}

static void
phoc_layer_surface_class_init (PhocLayerSurfaceClass *klass)
{
  klass->finalize = test_surface_finalize;
}

static void
phoc_layer_surface_init (PhocLayerSurface *surface)
{
  surface->layer_surface = g_new0 (struct wlr_layer_surface_v1, 1);
  surface->layer_surface->surface = g_new0 (struct wlr_surface, 1);
  surface->layer_surface->output = g_new0 (struct wlr_output, 1);
  surface->layer_surface->output->data = &test_output;
  surface->layer_surface->initialized = true;
  surface->mapped = true;
}

static PhocLayerSurface *
new_surface (void)
{
  return g_object_new (phoc_layer_surface_get_type (), NULL);
}

static guint32
wlr_layer_surface_v1_configure (struct wlr_layer_surface_v1 *surface, int width, int height)
{
  return next_serial++;
}

static bool
wlr_surface_has_buffer (struct wlr_surface *surface)
{
  return surface->has_buffer;
}

static PhocOutput *
phoc_layer_surface_get_output (PhocLayerSurface *surface)
{
  return surface->layer_surface->output ? surface->layer_surface->output->data : NULL;
}

static void
phoc_layer_shell_arrange (PhocOutput *output)
{
  if (arrange_hook) {
    void (*hook) (void) = arrange_hook;
    arrange_hook = NULL;
    hook ();
  }
}

static void phoc_output_set_layer_dirty (PhocOutput *output, int layer) {}
static void phoc_layer_shell_update_focus (void) {}
static void phoc_layer_shell_update_cursors (PhocLayerSurface *surface) {}
static void phoc_layer_surface_drop_child_surfaces (PhocLayerSurface *surface) {}
static void phoc_layer_surface_damage_whole (PhocLayerSurface *surface) {}
static void phoc_input_update_cursor_focus (PhocInput *input) {}
static void wl_list_remove (struct wl_list *link) {}
static void *phoc_server_get_default (void) { return NULL; }
static PhocInput *phoc_server_get_input (void *server) { return NULL; }
static void phoc_output_damage_from_surface (PhocOutput *output, struct wlr_surface *surface,
                                             int x, int y, gboolean whole) {}

#include "layer-callbacks.inc"

static void
assert_pending (PhocLayoutTransaction *transaction, guint count)
{
  gboolean active;
  g_assert_cmpuint (g_hash_table_size (transaction->pending_layer_configures), ==, count);
  g_assert_cmpint (phoc_layout_transaction_is_active (transaction), ==, count > 0);
  g_object_get (transaction, "active", &active, NULL);
  g_assert_cmpint (active, ==, count > 0);
  g_assert_cmpint (transaction->layer_timer_id != 0, ==, count > 0);
  if (count)
    g_assert_nonnull (g_main_context_find_source_by_id (NULL, transaction->layer_timer_id));
}

static void
expire_transaction (PhocLayoutTransaction *transaction)
{
  guint timer = transaction->layer_timer_id;
  GSource *source = g_main_context_find_source_by_id (NULL, timer);
  g_assert_nonnull (source);
  g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "Timeout (*configures pending");
  /* Dispatch the actual GLib timeout callback without sleeping/lowering deadlines. */
  g_source_set_ready_time (source, 0);
  g_assert_true (g_main_context_iteration (NULL, FALSE));
  g_test_assert_expected_messages ();
  g_assert_null (g_main_context_find_source_by_id (NULL, timer));
}

static void
commit_surface (PhocLayerSurface *surface, guint32 serial, bool buffer)
{
  surface->layer_surface->current.configure_serial = serial;
  surface->layer_surface->configured = true;
  surface->layer_surface->surface->has_buffer = buffer;
  handle_surface_commit (&surface->surface_commit, NULL);
}

static void
test_cross_surface_timeout (void)
{
  g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
  g_autoptr (GObject) a = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GObject) b = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (GObject) c = g_object_new (G_TYPE_OBJECT, NULL);
  guint64 old = phoc_layout_transaction_add_layer_dirty (tx, a, 10);
  expire_transaction (tx);
  assert_pending (tx, 0);
  guint64 bid = phoc_layout_transaction_add_layer_dirty (tx, b, 20);
  guint64 cid = phoc_layout_transaction_add_layer_dirty (tx, c, 10);
  /* A valid new completion arrives before the stale one, even with reused serials. */
  phoc_layout_transaction_notify_layer_configured (tx, b, bid, 20);
  assert_pending (tx, 1);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, 10);
  phoc_layout_transaction_notify_layer_configured (tx, b, bid, 20);
  phoc_layout_transaction_notify_layer_configured (tx, c, old, 10);
  assert_pending (tx, 1);
  phoc_layout_transaction_notify_layer_configured (tx, c, cid, 10);
  assert_pending (tx, 0);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, 10);
  assert_pending (tx, 0);
}

static void
test_identity_and_replacement (void)
{
  g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
  g_autoptr (GObject) a = g_object_new (G_TYPE_OBJECT, NULL);
  guint64 old = phoc_layout_transaction_add_layer_dirty (tx, a, UINT32_MAX);
  guint timer = tx->layer_timer_id;
  gint64 deadline = g_source_get_ready_time (g_main_context_find_source_by_id (NULL, timer));
  guint64 current = phoc_layout_transaction_add_layer_dirty (tx, a, 0);
  assert_pending (tx, 1);
  g_assert_cmpuint (tx->layer_timer_id, ==, timer);
  g_assert_cmpint (g_source_get_ready_time (g_main_context_find_source_by_id (NULL, timer)), ==, deadline);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, UINT32_MAX);
  phoc_layout_transaction_notify_layer_configured (tx, a, current, UINT32_MAX);
  assert_pending (tx, 1);
  /* Equal serials do not make a superseded identity valid. */
  old = current;
  current = phoc_layout_transaction_add_layer_dirty (tx, a, 0);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, 0);
  assert_pending (tx, 1);
  phoc_layout_transaction_notify_layer_configured (tx, a, current, 0);
  assert_pending (tx, 0);
  g_assert_null (g_main_context_find_source_by_id (NULL, timer));
}

static void
test_old_new_timeout (void)
{
  g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
  g_autoptr (GObject) a = g_object_new (G_TYPE_OBJECT, NULL);
  guint64 old = phoc_layout_transaction_add_layer_dirty (tx, a, 7);
  guint old_timer = tx->layer_timer_id;
  expire_transaction (tx);
  guint64 current = phoc_layout_transaction_add_layer_dirty (tx, a, 7);
  guint new_timer = tx->layer_timer_id;
  g_assert_cmpuint (old_timer, !=, new_timer);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, 7);
  assert_pending (tx, 1);
  g_assert_cmpuint (tx->layer_timer_id, ==, new_timer);
  expire_transaction (tx);
  assert_pending (tx, 0);
  guint64 newest = phoc_layout_transaction_add_layer_dirty (tx, a, 8);
  phoc_layout_transaction_notify_layer_configured (tx, a, current, 7);
  assert_pending (tx, 1);
  phoc_layout_transaction_notify_layer_configured (tx, a, newest, 8);
  assert_pending (tx, 0);
}

static void
test_surface_destroy_and_dispose (void)
{
  g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
  GObject *a = g_object_new (G_TYPE_OBJECT, NULL);
  GObject *b = g_object_new (G_TYPE_OBJECT, NULL);
  phoc_layout_transaction_add_layer_dirty (tx, a, 1);
  phoc_layout_transaction_add_layer_dirty (tx, b, 2);
  /* Weak references cannot keep destroyed surfaces alive or leave stale keys. */
  g_object_unref (a);
  assert_pending (tx, 1);
  g_object_unref (b);
  assert_pending (tx, 0);
  a = g_object_new (G_TYPE_OBJECT, NULL);
  phoc_layout_transaction_add_layer_dirty (tx, a, 3);
  expire_transaction (tx);
  g_object_unref (a);
  assert_pending (tx, 0);
  a = g_object_new (G_TYPE_OBJECT, NULL);
  phoc_layout_transaction_add_layer_dirty (tx, a, 4);
  guint timer = tx->layer_timer_id;
  g_clear_object (&tx);
  g_assert_null (g_main_context_find_source_by_id (NULL, timer));
  /* Disposing the transaction must unregister surface weak callbacks. */
  g_object_unref (a);
}

static void
test_callback_wrap_and_fence (void)
{
  g_autoptr (PhocLayoutTransaction) tx = phoc_layout_transaction_get_default ();
  g_autoptr (PhocLayerSurface) a = new_surface ();
  next_serial = UINT32_MAX;
  phoc_layer_surface_send_configure (a);
  phoc_layer_surface_send_configure (a);
  g_assert_cmpuint (a->pending_serial, ==, 0);
  g_assert_cmpuint (a->pending_configure_id, !=, 0);
  commit_surface (a, UINT32_MAX, true);
  assert_pending (tx, 1);
  commit_surface (a, 0, false);
  assert_pending (tx, 1);
  a->layer_surface->configured = false;
  a->layer_surface->surface->has_buffer = true;
  handle_surface_commit (&a->surface_commit, NULL);
  assert_pending (tx, 1);
  commit_surface (a, 0, true);
  assert_pending (tx, 0);
  phoc_layer_surface_send_configure (a);
  g_assert_cmpuint (a->pending_serial, ==, 1);
  commit_surface (a, UINT32_MAX, true);
  commit_surface (a, 0, true);
  assert_pending (tx, 1);
  commit_surface (a, 1, true);
  assert_pending (tx, 0);
}

static PhocLayerSurface *arrange_surface;
static void
replace_during_arrange (void)
{
  phoc_layer_surface_send_configure (arrange_surface);
}

static void
test_callback_replacement_during_commit (void)
{
  g_autoptr (PhocLayoutTransaction) tx = phoc_layout_transaction_get_default ();
  g_autoptr (PhocLayerSurface) a = new_surface ();
  next_serial = 100;
  phoc_layer_surface_send_configure (a);
  guint timer = tx->layer_timer_id;
  a->layer_surface->current.committed = WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE;
  arrange_surface = a;
  arrange_hook = replace_during_arrange;
  commit_surface (a, 100, true);
  g_assert_cmpuint (a->pending_serial, ==, 101);
  g_assert_cmpuint (tx->layer_timer_id, ==, timer);
  assert_pending (tx, 1);
  commit_surface (a, 101, true);
  assert_pending (tx, 0);
}

static void
test_callback_new_after_timeout (void)
{
  g_autoptr (PhocLayoutTransaction) tx = phoc_layout_transaction_get_default ();
  g_autoptr (PhocLayerSurface) a = new_surface ();
  g_autoptr (PhocLayerSurface) b = new_surface ();
  next_serial = 200;
  phoc_layer_surface_send_configure (a);
  expire_transaction (tx);
  phoc_layer_surface_send_configure (b);
  commit_surface (b, 201, true);
  assert_pending (tx, 0);
  /* The old local pending serial must not prevent rejoining a new transaction. */
  phoc_layer_surface_send_configure (a);
  assert_pending (tx, 1);
  commit_surface (a, 200, true);
  assert_pending (tx, 1);
  commit_surface (a, 202, true);
  assert_pending (tx, 0);
  phoc_layer_surface_send_configure (a);
  expire_transaction (tx);
  phoc_layer_surface_send_configure (b);
  commit_surface (a, 203, true);
  g_assert_cmpuint (a->pending_configure_id, ==, 0);
  assert_pending (tx, 1);
  commit_surface (b, 204, true);
  assert_pending (tx, 0);
}

static void
test_callback_unmap_destroy (void)
{
  g_autoptr (PhocLayoutTransaction) tx = phoc_layout_transaction_get_default ();
  g_autoptr (PhocLayerSurface) a = new_surface ();
  g_autoptr (PhocLayerSurface) b = new_surface ();
  next_serial = 300;
  phoc_layer_surface_send_configure (a);
  phoc_layer_surface_send_configure (b);
  arrange_surface = a;
  arrange_hook = replace_during_arrange;
  handle_unmap (&a->unmap, NULL);
  g_assert_false (a->mapped);
  g_assert_cmpuint (a->pending_configure_id, ==, 0);
  g_assert_cmpuint (a->pending_serial, ==, 0);
  assert_pending (tx, 1);
  commit_surface (b, 301, true);
  assert_pending (tx, 0);
  /* The unmap's later commit callback must not re-enrol the reset surface. */
  a->layer_surface->initialized = false;
  a->layer_surface->surface->WLR_PRIVATE.unmap_commit = true;
  a->layer_surface->current.committed = WLR_LAYER_SURFACE_V1_STATE_EXCLUSIVE_ZONE;
  arrange_hook = replace_during_arrange;
  commit_surface (a, 300, false);
  assert_pending (tx, 0);
  g_assert_cmpuint (next_serial, ==, 303);
  a->layer_surface->surface->WLR_PRIVATE.unmap_commit = false;
  phoc_layer_surface_send_configure (a);
  assert_pending (tx, 0);
  a->layer_surface->initialized = true;
  a->mapped = true;
  phoc_layer_surface_send_configure (a);
  commit_surface (a, 300, true);
  assert_pending (tx, 1);
  commit_surface (a, 303, true);
  assert_pending (tx, 0);
  /* A protocol destroy must release the fence even if another ref keeps the GObject alive. */
  phoc_layer_surface_send_configure (a);
  g_object_ref (a);
  handle_destroy (&a->destroy, NULL);
  assert_pending (tx, 0);
  g_assert_cmpuint (a->pending_configure_id, ==, 0);
  phoc_layer_surface_send_configure (b);
  expire_transaction (tx);
  g_object_ref (b);
  handle_destroy (&b->destroy, NULL);
  assert_pending (tx, 0);
}

typedef struct {
  GObject *surface;
  guint starts, finishes;
  guint64 id;
  gboolean restart;
} NotificationState;

static void
on_active (PhocLayoutTransaction *tx, GParamSpec *pspec, NotificationState *state)
{
  if (phoc_layout_transaction_is_active (tx)) {
    state->starts++;
  } else {
    state->finishes++;
    if (state->restart) {
      state->restart = FALSE;
      state->id = phoc_layout_transaction_add_layer_dirty (tx, state->surface, 900);
    }
  }
}

static void
test_notifications_and_reentrancy (void)
{
  g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
  g_autoptr (GObject) a = g_object_new (G_TYPE_OBJECT, NULL);
  NotificationState state = { .surface = a, .restart = TRUE };
  g_signal_connect (tx, "notify::active", G_CALLBACK (on_active), &state);
  guint64 old = phoc_layout_transaction_add_layer_dirty (tx, a, 800);
  expire_transaction (tx);
  assert_pending (tx, 1);
  g_assert_cmpuint (state.starts, ==, 2);
  g_assert_cmpuint (state.finishes, ==, 1);
  phoc_layout_transaction_notify_layer_configured (tx, a, old, 800);
  assert_pending (tx, 1);
  phoc_layout_transaction_notify_layer_configured (tx, a, state.id, 900);
  assert_pending (tx, 0);
  g_assert_cmpuint (state.finishes, ==, 2);
  g_signal_handlers_disconnect_by_data (tx, &state);
}

static void
test_timeout_configuration (void)
{
  const struct { const char *value; guint expected; } cases[] = {
    { NULL, 3000 }, { "", 3000 }, { "invalid", 3000 }, { "30ms", 3000 },
    { "16", 16 }, { "0", 16 }, { "120", 120 }, { "9000", 3000 },
  };
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
    if (cases[i].value)
      g_setenv ("PHOC_LAYOUT_TRANSACTION_TIMEOUT_MS", cases[i].value, TRUE);
    else
      g_unsetenv ("PHOC_LAYOUT_TRANSACTION_TIMEOUT_MS");
    g_autoptr (PhocLayoutTransaction) tx = g_object_new (PHOC_TYPE_LAYOUT_TRANSACTION, NULL);
    g_assert_cmpuint (tx->layer_timeout_ms, ==, cases[i].expected);
  }
  g_unsetenv ("PHOC_LAYOUT_TRANSACTION_TIMEOUT_MS");
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_unsetenv ("PHOC_LAYOUT_TRANSACTION_TIMEOUT_MS");
  g_test_add_func ("/phoc/layout/cross-surface-timeout", test_cross_surface_timeout);
  g_test_add_func ("/phoc/layout/identity-and-replacement", test_identity_and_replacement);
  g_test_add_func ("/phoc/layout/old-new-timeout", test_old_new_timeout);
  g_test_add_func ("/phoc/layout/destroy-and-dispose", test_surface_destroy_and_dispose);
  g_test_add_func ("/phoc/layout/callback-wrap-buffer-fence", test_callback_wrap_and_fence);
  g_test_add_func ("/phoc/layout/callback-replacement-during-commit", test_callback_replacement_during_commit);
  g_test_add_func ("/phoc/layout/callback-new-after-timeout", test_callback_new_after_timeout);
  g_test_add_func ("/phoc/layout/callback-unmap-destroy", test_callback_unmap_destroy);
  g_test_add_func ("/phoc/layout/notifications-reentrancy", test_notifications_and_reentrancy);
  g_test_add_func ("/phoc/layout/timeout-configuration", test_timeout_configuration);
  return g_test_run ();
}
