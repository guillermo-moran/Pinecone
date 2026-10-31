#include "guest-gtk-latency.c"
#include <assert.h>
#include <cairo.h>
#include <pango/pangocairo.h>

static void accounting_tests(void)
{
    pc_frame = (struct pc_frame_profile){.active = 1, .valid = 1};
    pc_frame_mark_at("paint", 1, 100, 20);
    pc_frame_mark_at("paint", 1, 110, 25);
    pc_frame_mark_at("paint", 0, 120, 30);
    pc_frame_mark_at("paint", 0, 140, 35);
    assert(pc_frame.valid && pc_frame.stages[3].calls == 2);
    assert(pc_frame.stages[3].wall_ns == 40 && pc_frame.stages[3].thread_ns == 15);
    pc_frame_mark_at("paint", 0, 150, 40);
    assert(!pc_frame.valid);
    pc_frame = (struct pc_frame_profile){.active = 1, .valid = 1};
    pc_frame_mark_at("layout", 1, 100, 20);
    pc_frame_mark_at("layout", 0, 99, 30);
    assert(!pc_frame.valid);
    pc_frame = (struct pc_frame_profile){.active = 1, .valid = 1};
    pc_frame_mark_at("paint", 1, 100, 0);
    assert(!pc_frame.valid);
    pc_frame.active = 0;
    pc_frame_begin(1, 1);
    pc_frame_mark("layout", 1);
    char out[2048];
    assert(pc_frame_finish(out, sizeof out, 7, 2) > 0);
    assert(strstr(out, "\"valid\":0") && strstr(out, "\"seqEnd\":2"));
    pc_frame_begin(2, 2);
    assert(pc_frame_finish(out, 8, 7, 2) == 0);
    pc_frame_begin(3, 2);
    pc_frame_begin(4, 2);
    assert(!pc_frame.valid);
    pc_frame.active = 0;
    pc_frame_begin(5, 2);
    for (unsigned i = 0; i < 8193; ++i) pc_frame_mark("paint", 1);
    assert(!pc_frame.valid);
    pc_frame.active = 0;
}

static void capture_budget_tests(void)
{
    profiled_frames = profiled_sequence_frames = 0;
    profiled_sequence = 0;
    assert(!frame_capture_allowed(0));
    assert(frame_capture_allowed(1));
    for (unsigned i = 0; i < 1000; ++i) {
        pc_frame = (struct pc_frame_profile){.ready = 1, .valid = 1};
        assert(!frame_should_emit());
        assert(profiled_frames == 0);
        assert(frame_capture_allowed(1));
    }
    for (unsigned i = 0; i < 4; ++i) {
        pc_frame = (struct pc_frame_profile){.ready = 1, .valid = 1};
        pc_frame.stages[3].calls = 1;
        assert(frame_should_emit());
    }
    assert(!frame_capture_allowed(1));
    assert(frame_capture_allowed(2));
    pc_frame = (struct pc_frame_profile){.ready = 1, .valid = 0};
    assert(frame_should_emit());
    assert(profiled_frames == 5 && profiled_sequence_frames == 1);
    profiled_frames = 512;
    assert(!frame_capture_allowed(3));
    profiled_frames = 0;
    assert(!frame_capture_allowed(257));
    pc_frame = (struct pc_frame_profile){0};
    assert(!frame_should_emit());
    profiled_sequence_frames = 0;
    profiled_sequence = 0;
}

static void existing_handler(GObject *object, gpointer data)
{
    (void)object; (void)data;
    assert(pc_frame.stages[2].depth == 1);
    pinecone_gtk_frame_mark("gsk_diff", 1);
    pinecone_gtk_frame_mark("gsk_diff", 0);
}

static void after_existing_handler(GObject *object, gpointer data)
{
    (void)object; (void)data;
    assert(!pc_frame.active && pc_frame.ready);
    sequence = 2;
}

static void signal_tests(void)
{
    /* Same RUN_LAST semantics as GdkFrameClock, without a display server. */
    GType type = g_type_register_static_simple(G_TYPE_OBJECT, "ProfileTestClock",
        sizeof(GObjectClass), NULL, sizeof(GObject), NULL, 0);
    guint id = g_signal_new("layout", type, G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    GObject *clock = g_object_new(type, NULL);
    g_signal_connect(clock, "layout", G_CALLBACK(existing_handler), NULL);
    observed_clock = (GdkFrameClock *)clock;
    gulong hook = g_signal_add_emission_hook(id, 0, phase_begin, "layout", NULL);
    g_signal_connect_after(clock, "layout", G_CALLBACK(phase_end), "layout");
    guint after = g_signal_new("after-paint", type, G_SIGNAL_RUN_LAST, 0,
                              NULL, NULL, NULL, G_TYPE_NONE, 0);
    g_signal_connect(clock, "after-paint", G_CALLBACK(after_existing_handler), NULL);
    gulong after_hook = g_signal_add_emission_hook(after, 0, phase_begin, "frame_end", NULL);
    sequence = 1;
    pc_frame_begin(5, 1);
    g_signal_emit(clock, id, 0);
    g_signal_emit(clock, id, 0);
    assert(pc_frame.stages[2].calls == 2 && pc_frame.stages[2].depth == 0);
    g_signal_emit(clock, after, 0);
    assert(sequence == 2 && frame_end_sequence == 1);
    char out[2048];
    assert(pc_frame_finish(out, sizeof out, 7, 1));
    assert(pc_frame.valid);
    g_signal_remove_emission_hook(id, hook);
    g_signal_remove_emission_hook(after, after_hook);
    observed_clock = NULL;
    g_object_unref(clock);
    sequence = 0;
}

static const char sample_text[] = "qwerty  caf\303\251  \316\273  e\314\201";
enum { WIDTH = 240, HEIGHT = 80, STRIDE = WIDTH * 4 + 16 };

static void render(unsigned char *pixels, int profile, int partial)
{
    memset(pixels, 0x55, STRIDE * HEIGHT);
    cairo_surface_t *surface = cairo_image_surface_create_for_data(
        pixels, CAIRO_FORMAT_ARGB32, WIDTH, HEIGHT, STRIDE);
    cairo_t *cr = cairo_create(surface);
    if (profile) pc_frame_begin(6 + (uint64_t)partial, 1);
    pinecone_gtk_frame_mark("cairo_draw", 1);
    GskRenderNode *node = gsk_cairo_node_new(&GRAPHENE_RECT_INIT(0, 0, WIDTH, HEIGHT));
    cairo_t *recording = gsk_cairo_node_get_draw_context(node);
    cairo_set_source_rgb(recording, 1, 1, 1);
    cairo_paint(recording);
    cairo_set_source_rgb(recording, 0, 0, 0);
    cairo_move_to(recording, 7, 12);
    PangoLayout *layout = pango_cairo_create_layout(recording);
    PangoFontDescription *font = pango_font_description_from_string("Sans 18");
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, sample_text, -1);
    assert(pango_layout_get_character_count(layout) == g_utf8_strlen(sample_text, -1));
    pango_cairo_show_layout(recording, layout);
    g_object_unref(layout);
    pango_font_description_free(font);
    cairo_destroy(recording);
    if (partial) {
        cairo_rectangle(cr, 10, 10, 90, 40);
        cairo_clip(cr);
    }
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gsk_render_node_draw(node, cr);
G_GNUC_END_IGNORE_DEPRECATIONS
    gsk_render_node_unref(node);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    assert(cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS);
    cairo_surface_destroy(surface);
    pinecone_gtk_frame_mark("cairo_draw", 0);
    if (profile) {
        char out[2048];
        assert(pc_frame_finish(out, sizeof out, (long)getpid(), 1) > 0 && pc_frame.valid);
        fputs(out, stdout);
    }
}

static void pixel_tests(void)
{
    unsigned char a[STRIDE * HEIGHT], b[STRIDE * HEIGHT];
    for (int partial = 0; partial < 2; ++partial) {
        render(a, 0, partial);
        render(b, 1, partial);
        assert(memcmp(a, b, sizeof a) == 0);
        unsigned dark = 0, changed = 0;
        for (int y = 0; y < HEIGHT; ++y) {
            for (int x = 0; x < STRIDE; ++x) {
                int outside = x >= WIDTH * 4 ||
                    (partial && (y < 10 || y >= 50 || x < 40 || x >= 400));
                if (outside) assert(b[y * STRIDE + x] == 0x55);
                else {
                    dark += b[y * STRIDE + x] < 0x40;
                    changed += b[y * STRIDE + x] != 0x55;
                }
            }
        }
        assert(dark > 100 && changed > 1000);
    }
}

static void text_tests(void)
{
    GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
    g_signal_connect(buffer, "insert-text", G_CALLBACK(insert_before), NULL);
    g_signal_connect_after(buffer, "insert-text", G_CALLBACK(insert_after), NULL);
    gtk_text_buffer_set_text(buffer, sample_text, -1);
    GtkTextIter begin, end;
    gtk_text_buffer_get_bounds(buffer, &begin, &end);
    char *text = gtk_text_buffer_get_text(buffer, &begin, &end, TRUE);
    assert(strcmp(text, sample_text) == 0);
    assert(gtk_text_buffer_get_char_count(buffer) == g_utf8_strlen(sample_text, -1));
    g_free(text);
    gtk_text_buffer_select_range(buffer, &begin, &end);
    assert(gtk_text_buffer_delete_selection(buffer, TRUE, TRUE));
    assert(gtk_text_buffer_get_char_count(buffer) == 0);
    g_object_unref(buffer);
}

int main(void)
{
    accounting_tests();
    capture_budget_tests();
    signal_tests();
    pixel_tests();
    text_tests();
    puts("GTK frame diagnostics: accounting, signals, text, glyphs, damage and padding PASS");
    return 0;
}
