/* Build separately with gtk+-3.0 and gtk4; no display or service is needed. */
#include <gtk/gtk.h>

int
main (int argc, char **argv)
{
  GtkIconTheme *theme;
  const char *paths[2];

  if (argc < 4) {
    g_printerr ("usage: %s ICON_ROOT THEME ICON...\n", argv[0]);
    return 2;
  }
  paths[0] = argv[1];
  paths[1] = NULL;
  theme = gtk_icon_theme_new ();
#if GTK_MAJOR_VERSION >= 4
  gtk_icon_theme_set_search_path (theme, paths);
  gtk_icon_theme_set_theme_name (theme, argv[2]);
#else
  gtk_icon_theme_set_search_path (theme, paths, 1);
  gtk_icon_theme_set_custom_theme (theme, argv[2]);
#endif

  for (int i = 3; i < argc; i++) {
    char *filename = NULL;

    if (!gtk_icon_theme_has_icon (theme, argv[i])) {
      g_printerr ("missing icon: %s\n", argv[i]);
      g_object_unref (theme);
      return 1;
    }
#if GTK_MAJOR_VERSION >= 4
    GtkIconPaintable *icon = gtk_icon_theme_lookup_icon (
      theme, argv[i], NULL, 48, 1, GTK_TEXT_DIR_NONE, 0);
    GFile *file = icon ? gtk_icon_paintable_get_file (icon) : NULL;
    if (file)
      filename = g_file_get_path (file);
#else
    GtkIconInfo *icon = gtk_icon_theme_lookup_icon (theme, argv[i], 48, 0);
    if (icon)
      filename = g_strdup (gtk_icon_info_get_filename (icon));
#endif
    if (!filename || !g_file_test (filename, G_FILE_TEST_IS_REGULAR)) {
      g_printerr ("icon has no readable file: %s\n", argv[i]);
      g_free (filename);
      g_clear_object (&icon);
      g_object_unref (theme);
      return 1;
    }
    g_print ("%s %s %s\n", argv[2], argv[i], filename);
    g_free (filename);
    g_clear_object (&icon);
  }
  g_object_unref (theme);
  return 0;
}
