#include <gtk/gtk.h>
#include <string.h>
#include <wordexp.h>

char *reference_expand(const char *path);
char *reference_collapse(const char *path);
char *_editor_path_expand(const char *path);
char *_editor_path_collapse(const char *path);
static unsigned shell_calls;

int counted_wordexp(const char *words, wordexp_t *state, int flags)
{
  shell_calls++;
  return wordexp(words, state, flags);
}

static void compare(const char *path)
{
  char *old_expand = reference_expand(path);
  char *old_collapse = reference_collapse(path);
  unsigned before = shell_calls;
  char *new_expand = _editor_path_expand(path);
  char *new_collapse = _editor_path_collapse(path);
  g_assert_cmpuint(shell_calls, ==, before);
  g_assert_cmpstr(new_expand, ==, old_expand);
  g_assert_cmpstr(new_collapse, ==, old_collapse);
  if (path) {
    char *literal = g_path_is_absolute(path) ? g_strdup(path) :
        g_build_filename(g_get_home_dir(), path, NULL);
    g_assert_cmpstr(new_expand, ==, literal);
    g_free(literal);
  }
  g_free(new_expand);
  g_free(new_collapse);
  g_free(old_expand);
  g_free(old_collapse);
}

static void literals(void)
{
  const char *cases[] = {NULL, "", "/", "/root", "/root/", "/root/file",
    "relative", "./relative", "../relative", "a//b/../c", "~", "~/file", "~root/file",
    "$HOME", "${HOME}/file", "$((1+2))", "$(printf forbidden)", "`printf forbidden`",
    "*?[abc]", "semi;colon|pipe&and<in>out", "#comment", "a b\tline\nbreak\r",
    "'", "a'b", "''''", "\\", "\\\"'end", "\"double quoted\"", "trailing\\",
    "/tmp/a'b/$HOME/*", "/tmp/caf\xc3\xa9/e\xcc\x81/\xe6\x97\xa5", "\xff\x80-path"};
  for (unsigned i = 0; i < G_N_ELEMENTS(cases); i++) compare(cases[i]);
  compare(g_get_home_dir());
  char *child = g_build_filename(g_get_home_dir(), "child's file", NULL);
  compare(child);
  g_free(child);
  char *prefix_sibling = g_strconcat(g_get_home_dir(), "-sibling", NULL);
  compare(prefix_sibling); /* Preserve existing prefix behavior; no unrelated fix. */
  g_free(prefix_sibling);
  for (unsigned c = 1; c < 128; c++) {
    char path[] = {'p', (char)c, '\'', '$', '\\', 'x', 0};
    compare(path);
  }
  g_assert_cmpuint(shell_calls, >, 0);
}

typedef struct { unsigned changed, notify; const char *expected; } Notifications;
static void lookup_subtitle(Notifications *counts)
{
  char *subtitle = _editor_path_collapse("/root");
  g_assert_cmpstr(subtitle, ==, counts->expected);
  g_free(subtitle);
}
static void changed(GtkTextBuffer *buffer, Notifications *counts)
{
  (void)buffer;
  counts->changed++;
  lookup_subtitle(counts);
}
static void notified(GObject *object, GParamSpec *pspec, Notifications *counts)
{
  (void)object;
  (void)pspec;
  counts->notify++;
  lookup_subtitle(counts);
}
static void expect(GtkTextBuffer *buffer, const char *expected)
{
  GtkTextIter first, last;
  gtk_text_buffer_get_bounds(buffer, &first, &last);
  char *text = gtk_text_buffer_get_text(buffer, &first, &last, TRUE);
  g_assert_cmpstr(text, ==, expected);
  g_assert_true(g_utf8_validate(text, -1, NULL));
  g_free(text);
}
static void edits(void)
{
  char *expected = reference_collapse("/root");
  Notifications counts = {.expected = expected};
  unsigned before = shell_calls;
  GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
  gtk_text_buffer_set_enable_undo(buffer, TRUE);
  g_signal_connect(buffer, "changed", G_CALLBACK(changed), &counts);
  g_signal_connect(buffer, "notify::cursor-position", G_CALLBACK(notified), &counts);
  gtk_text_buffer_insert_at_cursor(buffer, "hello", -1);
  expect(buffer, "hello");
  GtkTextIter first, last;
  gtk_text_buffer_get_iter_at_offset(buffer, &first, 1);
  gtk_text_buffer_get_iter_at_offset(buffer, &last, 4);
  gtk_text_buffer_delete(buffer, &first, &last);
  expect(buffer, "ho");
  gtk_text_buffer_get_bounds(buffer, &first, &last);
  gtk_text_buffer_select_range(buffer, &first, &last);
  g_assert_true(gtk_text_buffer_get_has_selection(buffer));
  gtk_text_buffer_begin_user_action(buffer);
  g_assert_true(gtk_text_buffer_delete_selection(buffer, TRUE, TRUE));
  gtk_text_buffer_insert_at_cursor(buffer, "caf\xc3\xa9", -1);
  gtk_text_buffer_end_user_action(buffer);
  expect(buffer, "caf\xc3\xa9");
  gtk_text_buffer_undo(buffer);
  expect(buffer, "ho");
  gtk_text_buffer_redo(buffer);
  expect(buffer, "caf\xc3\xa9");
  gtk_text_buffer_begin_user_action(buffer);
  gtk_text_buffer_insert_at_cursor(buffer, " e\xcc\x81 \xe6\x97\xa5", -1);
  gtk_text_buffer_end_user_action(buffer);
  expect(buffer, "caf\xc3\xa9 e\xcc\x81 \xe6\x97\xa5");
  gtk_text_buffer_get_end_iter(buffer, &last);
  first = last;
  g_assert_true(gtk_text_iter_backward_char(&first));
  gtk_text_buffer_delete(buffer, &first, &last);
  expect(buffer, "caf\xc3\xa9 e\xcc\x81 ");
  g_assert_cmpuint(counts.changed, >, 0);
  g_assert_cmpuint(counts.notify, >, 0);
  g_assert_cmpuint(shell_calls, ==, before);
  g_object_unref(buffer);
  g_free(expected);
}

int main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  g_test_add_func("/editor-path/literal-differential", literals);
  g_test_add_func("/editor-path/edit-notifications", edits);
  return g_test_run();
}
