#include <gtk/gtk.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>

static unsigned entries, exits;

/* Exported by the test executable for GTK's optional weak reference. */
void pinecone_gtk_frame_mark(const char *stage, int entering)
{
    assert(strcmp(stage, "texture_download") == 0);
    if (entering) ++entries;
    else ++exits;
}

int main(int argc, char **argv)
{
    assert(argc == 1 || (argc == 2 && strcmp(argv[1], "--stock") == 0));
    unsigned expected = argc == 2 ? 0 : 1;
    const uint32_t input[4] = {0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff};
    GBytes *bytes = g_bytes_new_static(input, sizeof input);
    GdkTexture *texture = gdk_memory_texture_new(2, 2,
        GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, 8);
    GskRenderNode *node = gsk_texture_node_new(texture,
        &GRAPHENE_RECT_INIT(0, 0, 2, 2));
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 2, 2);
    cairo_t *cr = cairo_create(surface);
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gsk_render_node_draw(node, cr);
G_GNUC_END_IGNORE_DEPRECATIONS
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    assert(cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS);
    assert(entries == expected && exits == expected);
    const unsigned char *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    assert(memcmp(pixels, input, 8) == 0);
    assert(memcmp(pixels + stride, input + 2, 8) == 0);
    cairo_surface_destroy(surface);
    gsk_render_node_unref(node);
    g_object_unref(texture);
    g_bytes_unref(bytes);
    g_print("PASS: %s GTK; expected hooks %u; texture pixels unchanged\n",
            expected ? "diagnostic" : "stock", expected);
    return 0;
}
