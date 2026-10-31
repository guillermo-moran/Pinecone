/* Optional Linux integration regression, not a latency benchmark or IME driver. */
#include <gtksourceview/gtksource.h>
#include "trace.h"

static void expect(GtkTextBuffer *buffer, const char *expected)
{
  GtkTextIter begin, end;
  gtk_text_buffer_get_bounds(buffer, &begin, &end);
  char *text = gtk_text_buffer_get_text(buffer, &begin, &end, TRUE);
  g_assert_cmpstr(text, ==, expected);
  g_assert_true(g_utf8_validate(text, -1, NULL));
  g_assert_cmpint(gtk_text_buffer_get_char_count(buffer), ==, g_utf8_strlen(expected, -1));
  g_free(text);
}

static void changed(GtkTextBuffer *buffer, unsigned *count)
{
  (void)buffer;
  ++*count;
}

static void loaded(GObject *object, GAsyncResult *result, gpointer data)
{
  GError *error = NULL;
  g_assert_true(gtk_source_file_loader_load_finish(GTK_SOURCE_FILE_LOADER(object), result, &error));
  g_assert_no_error(error);
  g_main_loop_quit(data);
}

static void exercise(void)
{
  PC_TEXT_SCOPE("test-buffer.operations", g_getenv("PC_TEXT_TEST_STANDALONE") == NULL);
  GtkSourceBuffer *source = gtk_source_buffer_new(NULL);
  GtkTextBuffer *buffer = GTK_TEXT_BUFFER(source);
  GtkTextIter begin, end;
  unsigned changes = 0;
  g_signal_connect(buffer, "changed", G_CALLBACK(changed), &changes);
  gtk_text_buffer_insert_at_cursor(buffer, "hello world", -1);
  expect(buffer, "hello world");
  g_assert_cmpuint(changes, ==, 1);

  gtk_text_buffer_get_iter_at_offset(buffer, &begin, 5);
  gtk_text_buffer_get_end_iter(buffer, &end);
  gtk_text_buffer_delete(buffer, &begin, &end);
  expect(buffer, "hello");
  g_assert_cmpuint(changes, ==, 2);

  gtk_text_buffer_get_iter_at_offset(buffer, &begin, 1);
  gtk_text_buffer_get_iter_at_offset(buffer, &end, 4);
  gtk_text_buffer_select_range(buffer, &begin, &end);
  g_assert_true(gtk_text_buffer_get_has_selection(buffer));
  gtk_text_buffer_begin_user_action(buffer);
  g_assert_true(gtk_text_buffer_delete_selection(buffer, TRUE, TRUE));
  gtk_text_buffer_insert_at_cursor(buffer, "ipp", -1);
  gtk_text_buffer_end_user_action(buffer);
  expect(buffer, "hippo");
  g_assert_false(gtk_text_buffer_get_has_selection(buffer));
  g_assert_true(gtk_text_buffer_get_can_undo(buffer));
  gtk_text_buffer_undo(buffer);
  expect(buffer, "hello");
  gtk_text_buffer_redo(buffer);
  expect(buffer, "hippo");

  /* Committed UTF-8 and decomposed characters; real preedit remains a UI gate. */
  gtk_text_buffer_set_text(buffer, "caf\xc3\xa9", -1);
  gtk_text_buffer_get_end_iter(buffer, &end);
  gtk_text_buffer_place_cursor(buffer, &end);
  gtk_text_buffer_begin_user_action(buffer);
  gtk_text_buffer_insert_at_cursor(buffer, " e\xcc\x81 \xe6\x97\xa5", -1);
  gtk_text_buffer_end_user_action(buffer);
  expect(buffer, "caf\xc3\xa9 e\xcc\x81 \xe6\x97\xa5");
  gtk_text_buffer_undo(buffer);
  expect(buffer, "caf\xc3\xa9");
  gtk_text_buffer_redo(buffer);
  expect(buffer, "caf\xc3\xa9 e\xcc\x81 \xe6\x97\xa5");
  gtk_text_buffer_get_end_iter(buffer, &end);
  begin = end;
  g_assert_true(gtk_text_iter_backward_char(&begin));
  gtk_text_buffer_delete(buffer, &begin, &end);
  expect(buffer, "caf\xc3\xa9 e\xcc\x81 ");

  GtkSourceLanguageManager *manager = gtk_source_language_manager_get_default();
  const char *language_path = g_getenv("PC_TEXT_LANGUAGE_PATH");
  if (language_path)
    gtk_source_language_manager_prepend_search_path(manager, language_path);
  GtkSourceLanguage *language = gtk_source_language_manager_get_language(manager, "c");
  g_assert_nonnull(language);
  gtk_source_buffer_set_language(source, language);
  gtk_text_buffer_set_text(buffer, "int main(void) { return 0; }\n", -1);
  gtk_text_buffer_get_bounds(buffer, &begin, &end);
  gtk_source_buffer_ensure_highlight(source, &begin, &end);
  expect(buffer, "int main(void) { return 0; }\n");
  g_assert_true(gtk_source_buffer_get_highlight_syntax(source));
  g_object_unref(source);

  /* Exercise the real loader's loading path, including its terminal-newline
   * convention. The memory stream avoids filesystem or user document changes. */
  source = gtk_source_buffer_new(NULL);
  GtkSourceFile *file = gtk_source_file_new();
  GInputStream *stream = g_memory_input_stream_new_from_data("qwerty\n", 7, NULL);
  GtkSourceFileLoader *loader = gtk_source_file_loader_new_from_stream(source, file, stream);
  GMainLoop *loop = g_main_loop_new(NULL, FALSE);
  gtk_source_file_loader_load_async(loader, G_PRIORITY_DEFAULT, NULL, NULL, NULL, NULL, loaded, loop);
  g_main_loop_run(loop);
  expect(GTK_TEXT_BUFFER(source), "qwerty");
  g_main_loop_unref(loop);
  g_object_unref(loader);
  g_object_unref(stream);
  g_object_unref(file);
  g_object_unref(source);
}

int main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  char *version = g_strdup_printf("%u.%u.%u", gtk_get_major_version(),
                                  gtk_get_minor_version(), gtk_get_micro_version());
  g_test_message("runtime GTK %s", version);
  if (g_getenv("PC_TEXT_EXPECT_GTK"))
    g_assert_cmpstr(version, ==, g_getenv("PC_TEXT_EXPECT_GTK"));
  g_free(version);
  /* Buffer/UTF-8/highlighting regression needs no window or display server. */
  gtk_init_check();
  gtk_source_init();
  g_test_add_func("/text-insertion/buffer-contract", exercise);
  int result = g_test_run();
  gtk_source_finalize();
  return result;
}
