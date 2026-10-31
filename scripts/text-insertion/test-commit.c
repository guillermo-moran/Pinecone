/* The library arm models the exact external registration used by libspelling. */
#include <gtk/gtk.h>
#include "trace.h"

typedef struct {
  unsigned calls, destroyed;
  GtkTextBufferNotifyFlags flags[16];
  guint position[16], length[16];
} State;

static void observe(GtkTextBuffer *buffer, GtkTextBufferNotifyFlags flags,
                    guint position, guint length, gpointer data)
{
  State *state = data;
  g_assert_true(GTK_IS_TEXT_BUFFER(buffer));
  unsigned index = state->calls++;
  g_assert_cmpuint(index, <, G_N_ELEMENTS(state->flags));
  state->flags[index] = flags;
  state->position[index] = position;
  state->length[index] = length;
}

static void destroyed(gpointer data)
{
  State *state = data;
  state->destroyed++;
}

#ifdef PC_COMMIT_LIBRARY
guint fixture_register(GtkTextBuffer *buffer, GtkTextBufferNotifyFlags flags, State *state)
{
  return gtk_text_buffer_add_commit_notify(buffer, flags, observe, state, destroyed);
}
#else
guint fixture_register(GtkTextBuffer *, GtkTextBufferNotifyFlags, State *);

int main(void)
{
  State state = {0}, foreign = {0}, filtered = {0};
  GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
  const unsigned all = GTK_TEXT_BUFFER_NOTIFY_BEFORE_INSERT | GTK_TEXT_BUFFER_NOTIFY_AFTER_INSERT |
                       GTK_TEXT_BUFFER_NOTIFY_BEFORE_DELETE | GTK_TEXT_BUFFER_NOTIFY_AFTER_DELETE;
  guint id = fixture_register(buffer, all, &state);
  g_assert_cmpuint(id, >, 0);
  gtk_text_buffer_add_commit_notify(buffer, all, observe, &foreign, destroyed);
  fixture_register(buffer, GTK_TEXT_BUFFER_NOTIFY_AFTER_INSERT, &filtered);
  {
    PC_TEXT_SCOPE("commit.test", 1);
    GtkTextIter start, end;
    gtk_text_buffer_insert_at_cursor(buffer, "\xc3\xa9", 2);
    g_assert_cmpint(gtk_text_buffer_get_char_count(buffer), ==, 1);
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *text = gtk_text_buffer_get_text(buffer, &start, &end, TRUE);
    g_assert_cmpstr(text, ==, "\xc3\xa9");
    g_free(text);
    gtk_text_buffer_delete(buffer, &start, &end);
    g_assert_cmpint(gtk_text_buffer_get_char_count(buffer), ==, 0);
  }
  g_assert_cmpuint(state.calls, ==, 4);
  g_assert_cmpuint(foreign.calls, ==, 4);
  g_assert_cmpuint(filtered.calls, ==, 1);
  g_assert_cmpuint(filtered.flags[0], ==, GTK_TEXT_BUFFER_NOTIFY_AFTER_INSERT);
  const unsigned flags[] = {GTK_TEXT_BUFFER_NOTIFY_BEFORE_INSERT, GTK_TEXT_BUFFER_NOTIFY_AFTER_INSERT,
                            GTK_TEXT_BUFFER_NOTIFY_BEFORE_DELETE, GTK_TEXT_BUFFER_NOTIFY_AFTER_DELETE};
  for (unsigned i = 0; i < 4; i++) {
    g_assert_cmpuint(state.flags[i], ==, flags[i]);
    g_assert_cmpuint(state.position[i], ==, 0);
    g_assert_cmpuint(state.length[i], ==, i == 3 ? 0 : 1);
  }
  gtk_text_buffer_remove_commit_notify(buffer, id);
  g_assert_cmpuint(state.destroyed, ==, 1);
  g_object_unref(buffer);
  g_assert_cmpuint(state.destroyed, ==, 1);
  g_assert_cmpuint(foreign.destroyed, ==, 1);
  g_assert_cmpuint(filtered.destroyed, ==, 1);
  return 0;
}
#endif
