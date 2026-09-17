#define _GNU_SOURCE
#include <assert.h>
#include <cairo.h>
#include <dlfcn.h>
#include <pixman.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* These test hooks observe the real patched Cairo call sites, without a GPU. */
static unsigned depth, begins, ends, scoped_data, unscoped_data, escapes;
static uint32_t *(*real_data)(pixman_image_t *);

void pinecone_pixman_begin_cpu_access_flags(uint32_t flags) {
    assert(flags == 1u || flags == 3u);
    ++depth;
    ++begins;
}

void pinecone_pixman_end_cpu_access(void) {
    assert(depth);
    --depth;
    ++ends;
}

uint32_t *pixman_image_get_data(pixman_image_t *image) {
    if (!real_data) real_data = dlsym(RTLD_NEXT, "pixman_image_get_data");
    assert(real_data);
    if (depth) ++scoped_data;
    else ++unscoped_data;
    return real_data(image);
}

uint32_t *pinecone_pixman_get_data_escaping(pixman_image_t *image) {
    ++escapes;
    if (!real_data) real_data = dlsym(RTLD_NEXT, "pixman_image_get_data");
    assert(real_data);
    return real_data(image);
}

int main(int argc, char **argv) {
    int patched = argc == 2 && strcmp(argv[1], "--expect-hooks") == 0;
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 64, 64);
    assert(cairo_surface_status(s) == CAIRO_STATUS_SUCCESS);
    if (patched) assert(scoped_data == 0 && unscoped_data == 0 && escapes == 0);
    cairo_t *cr = cairo_create(s);
    cairo_set_source_rgba(cr, 0.2, 0.4, 0.8, 1);
    cairo_paint(cr);
    cairo_set_source_rgba(cr, 0.8, 0.1, 0.2, 0.7);
    cairo_move_to(cr, 2, 3);
    cairo_curve_to(cr, 60, 3, 3, 60, 60, 60);
    cairo_line_to(cr, 2, 60);
    cairo_close_path(cr);
    cairo_fill(cr);
    assert(cairo_status(cr) == CAIRO_STATUS_SUCCESS);
    if (patched) {
        assert(begins && begins == ends && depth == 0);
        assert(scoped_data && unscoped_data == 0 && escapes == 0);
    }
    cairo_surface_flush(s);
    unsigned prior = escapes;
    pinecone_pixman_begin_cpu_access_flags(3u);
    unsigned char *data = cairo_image_surface_get_data(s);
    assert(data);
    if (patched) assert(escapes == prior + 1);
    pinecone_pixman_end_cpu_access();
    uint64_t hash = UINT64_C(14695981039346656037);
    for (int i = 0; i < cairo_image_surface_get_stride(s) * 64; ++i) {
        hash ^= data[i];
        hash *= UINT64_C(1099511628211);
    }
    printf("pixels: %016llx\n", (unsigned long long)hash);
    data[0] = 17;
    cairo_surface_mark_dirty(s);
    assert(cairo_image_surface_get_data(s)[0] == 17);
    cairo_rectangle_int_t bounds = { 0, 0, 8, 8 };
    prior = escapes;
    cairo_surface_t *mapped = cairo_surface_map_to_image(s, &bounds);
    assert(cairo_surface_status(mapped) == CAIRO_STATUS_SUCCESS);
    if (patched) assert(escapes > prior);
    cairo_surface_unmap_image(s, mapped);
    cairo_destroy(cr);
    cairo_surface_finish(s);
    if (patched) assert(cairo_image_surface_get_data(s) == NULL);
    cairo_surface_destroy(s);
    assert(depth == 0 && begins == ends);
    if (patched) puts("Cairo access: lazy acquisition, draw scopes, flush, exports, mapping and finish passed");
    return 0;
}
