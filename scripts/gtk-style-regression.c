/* Compile against the guest's GTK 3 version; parsing needs no display server. */
#include <gtk/gtk.h>
#include <stdio.h>

static void parsing_error(GtkCssProvider *provider, GtkCssSection *section,
                          GError *error, gpointer data)
{
    (void)provider;
    (void)section;
    (*(unsigned int *)data)++;
    fprintf(stderr, "%s\n", error->message);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: gtk-style-regression stylesheet.css\n");
        return 2;
    }
    GtkCssProvider *provider = gtk_css_provider_new();
    unsigned int errors = 0;
    g_signal_connect(provider, "parsing-error", G_CALLBACK(parsing_error), &errors);
    gboolean loaded = gtk_css_provider_load_from_path(provider, argv[1], NULL);
    g_object_unref(provider);
    if (!loaded || errors != 0)
        return 1;
    puts("GTK stylesheet parsed without errors or warnings");
    return 0;
}
