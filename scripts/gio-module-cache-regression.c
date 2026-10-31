/* A real GIO module and scan client, built separately by test-gio-module-cache.py. */
#include <gio/gio.h>
#include <stdio.h>

#define POINT "pinecone-cache-regression"

#ifdef BUILD_MODULE
G_MODULE_EXPORT void g_io_module_load(GIOModule *module)
{
    (void)module;
    FILE *log = fopen(g_getenv("PINECONE_TEST_MODULE_LOG"), "a");
    g_assert_nonnull(log);
    fputs("load\n", log);
    fclose(log);
    g_io_extension_point_register(POINT);
    g_io_extension_point_implement(POINT, G_TYPE_OBJECT, "fixture", 42);
}

G_MODULE_EXPORT void g_io_module_unload(GIOModule *module)
{
    (void)module;
}

G_MODULE_EXPORT gchar **g_io_module_query(void)
{
    gchar *points[] = { POINT, NULL };
    return g_strdupv(points);
}
#else
int main(int argc, char **argv)
{
    g_assert_cmpint(argc, ==, 3);
    gboolean cached = g_str_equal(argv[2], "cached");
    const char *log = g_getenv("PINECONE_TEST_MODULE_LOG");
    g_assert_nonnull(log);
    g_io_modules_scan_all_in_directory(argv[1]);
    g_assert_cmpint(g_file_test(log, G_FILE_TEST_EXISTS), ==, !cached);
    GIOExtensionPoint *point = g_io_extension_point_lookup(POINT);
    g_assert_nonnull(point);
    GIOExtension *extension = g_io_extension_point_get_extension_by_name(point, "fixture");
    g_assert_nonnull(extension);
    g_assert_cmpint(g_io_extension_get_priority(extension), ==, 42);
    GObject *object = g_object_new(g_io_extension_get_type(extension), NULL);
    g_assert_true(G_IS_OBJECT(object));
    g_object_unref(object);
    gchar *contents = NULL;
    g_assert_true(g_file_get_contents(log, &contents, NULL, NULL));
    g_assert_cmpstr(contents, ==, "load\n");
    g_free(contents);
    return 0;
}
#endif
