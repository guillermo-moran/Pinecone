#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "guest-gtk-preload-scope.h"

/* Diagnostic only. Never installed by the production image builder. */
static uint64_t now_us(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_nsec / 1000;
}

static void record(const char *event, uint64_t sequence, int length)
{
    char line[256];
    int n = snprintf(line, sizeof line,
        "PINECONE_GTK pid=%ld mono_us=%" PRIu64 " event=%s seq=%" PRIu64 " length=%d\n",
        (long)getpid(), now_us(), event, sequence, length);
    if (n > 0 && (size_t)n < sizeof line) (void)write(STDERR_FILENO, line, (size_t)n);
}

#ifdef PINECONE_PROFILE_LAUNCHER
int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    const char *value = getenv("PINECONE_GTK_PRELOAD");
    char *preload = value ? strdup(value) : NULL;
    if (!preload) return 2;
    if (pc_gtk_prepare_scope(preload) < 0 || setenv("LD_PRELOAD", preload, 1) ||
        unsetenv("PINECONE_GTK_PRELOAD")) {
        perror("GTK diagnostic preload scope");
        free(preload);
        return 2;
    }
    free(preload);
    record("exec", 0, 0);
    execvp(argv[1], argv + 1);
    perror("execvp");
    return 127;
}
#else
#include <gtk/gtk.h>
#include "guest-gtk-frame-profile.h"

static gboolean enabled;
static guint attempts;
static uint64_t sequence, painted_sequence, painting_sequence;
static gboolean mapped, painted;
static GtkWidget *observed_window;
static gboolean frame_details;
static guint profiled_frames;
static uint64_t profiled_sequence;
static guint profiled_sequence_frames;
static uint64_t frame_end_sequence;
static GdkFrameClock *observed_clock;

/* Optional GTK source hooks call this directly, including hidden/internal GSK
 * paths which cannot reliably be observed with LD_PRELOAD interposition. */
__attribute__((visibility("default")))
void pinecone_gtk_frame_mark(const char *stage, int entering)
{
    pc_frame_mark(stage, entering);
}

static gboolean frame_capture_allowed(uint64_t current_sequence)
{
    if (!current_sequence || current_sequence > 256 || profiled_frames >= 512)
        return FALSE;
    if (profiled_sequence != current_sequence) {
        profiled_sequence = current_sequence;
        profiled_sequence_frames = 0;
    }
    return profiled_sequence_frames < 4;
}

static gboolean frame_should_emit(void)
{
    if (!pc_frame.ready) return FALSE;
    /* Idle update ticks must not exhaust the budget before the next keystroke.
     * Keep invalid records so accounting failures remain visible. */
    if (pc_frame.valid && !pc_frame.stages[3].calls) {
        pc_frame.ready = 0;
        return FALSE;
    }
    ++profiled_frames;
    ++profiled_sequence_frames;
    return TRUE;
}

static gboolean phase_begin(GSignalInvocationHint *hint, guint count,
                            const GValue *values, gpointer data)
{
    (void)hint;
    if (!count || g_value_get_object(values) != (gpointer)observed_clock) return TRUE;
    const char *phase = data;
    if (strcmp(phase, "frame_end") == 0) {
        frame_end_sequence = sequence;
        pc_frame_stop();
    } else if (strcmp(phase, "frame") == 0) {
        if (frame_capture_allowed(sequence)) {
            pc_frame_begin((uint64_t)gdk_frame_clock_get_frame_counter(observed_clock), sequence);
        }
    } else {
        pc_frame_mark(phase, 1);
    }
    return TRUE;
}

static void phase_end(GdkFrameClock *clock, gpointer data)
{
    (void)clock;
    pc_frame_mark(data, 0);
}

static void frame_end(GdkFrameClock *clock, gpointer data)
{
    (void)clock; (void)data;
    if (!frame_should_emit()) return;
    char line[2048];
    size_t length = pc_frame_finish(line, sizeof line, (long)getpid(), frame_end_sequence);
    if (length) (void)write(STDERR_FILENO, line, length);
}

static void attach_frame_details(GdkFrameClock *clock)
{
    observed_clock = clock;
    g_object_add_weak_pointer(G_OBJECT(clock), (gpointer *)&observed_clock);
    const char *signals[] = {"before-paint", "update", "layout", "paint"};
    const char *phases[] = {"frame", "update", "layout", "paint"};
    for (unsigned i = 0; i < G_N_ELEMENTS(signals); ++i) {
        /* An ordinary handler connected here would run AFTER GTK's existing
         * layout/paint handler. Emission hooks observe the entry instead. */
        guint id = g_signal_lookup(signals[i], GDK_TYPE_FRAME_CLOCK);
        g_signal_add_emission_hook(id, 0, phase_begin, (gpointer)phases[i], NULL);
        if (i) g_signal_connect_after(clock, signals[i], G_CALLBACK(phase_end), (gpointer)phases[i]);
    }
    g_signal_add_emission_hook(g_signal_lookup("after-paint", GDK_TYPE_FRAME_CLOCK),
                              0, phase_begin, "frame_end", NULL);
    g_signal_connect_after(clock, "after-paint", G_CALLBACK(frame_end), NULL);
}

static void insert_before(GtkTextBuffer *buffer, GtkTextIter *where,
                          char *text, int length, void *data)
{
    (void)buffer; (void)where; (void)text; (void)data;
    if (++sequence <= 256) record("insert_begin", sequence, length);
}

static void insert_after(GtkTextBuffer *buffer, GtkTextIter *where,
                         char *text, int length, void *data)
{
    (void)buffer; (void)where; (void)text; (void)data;
    if (sequence <= 256) record("insert_end", sequence, length);
}

static void after_paint(GdkFrameClock *clock, void *data)
{
    (void)clock; (void)data;
    if (!painted) { record("first_after_paint", 0, 0); painted = TRUE; }
    if (sequence <= 256 && sequence != painted_sequence) {
        record("after_paint", sequence, 0);
        painted_sequence = sequence;
    }
}

static void before_paint(GdkFrameClock *clock, void *data)
{
    (void)clock; (void)data;
    if (sequence <= 256 && sequence != painting_sequence) {
        record("before_paint", sequence, 0);
        painting_sequence = sequence;
    }
}

static void on_map(GtkWidget *window, void *data)
{
    (void)data;
    if (mapped) return;
    mapped = TRUE;
    record("window_map", 0, 0);
    GdkFrameClock *clock = gtk_widget_get_frame_clock(window);
    if (clock) {
        g_signal_connect(clock, "before-paint", G_CALLBACK(before_paint), NULL);
        g_signal_connect(clock, "after-paint", G_CALLBACK(after_paint), NULL);
        if (frame_details) attach_frame_details(clock);
    }
}

static void attach_buffers(GtkWidget *widget)
{
    if (GTK_IS_TEXT_VIEW(widget)) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
        if (!g_object_get_data(G_OBJECT(buffer), "pinecone-latency-probe")) {
            g_object_set_data(G_OBJECT(buffer), "pinecone-latency-probe", GINT_TO_POINTER(1));
            g_signal_connect(buffer, "insert-text", G_CALLBACK(insert_before), NULL);
            g_signal_connect_after(buffer, "insert-text", G_CALLBACK(insert_after), NULL);
            record("buffer_attached", 0, 0);
        }
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) attach_buffers(child);
}

static gboolean find_window(void *data)
{
    (void)data;
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
        GtkWidget *window = g_list_model_get_item(windows, i);
        if (!GTK_IS_APPLICATION_WINDOW(window)) { g_object_unref(window); continue; }
        observed_window = window;
        g_object_add_weak_pointer(G_OBJECT(window), (gpointer *)&observed_window);
        record("window_found", 0, 0);
        g_signal_connect(window, "map", G_CALLBACK(on_map), NULL);
        if (gtk_widget_get_mapped(window)) on_map(window, NULL);
        attach_buffers(window);
        g_object_unref(window);
        return G_SOURCE_REMOVE;
    }
    return ++attempts < 6000 ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

static void on_startup(GApplication *app, void *data)
{
    (void)app; (void)data;
    record("startup_end", 0, 0);
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) {
        gboolean animations;
        g_object_get(settings, "gtk-enable-animations", &animations, NULL);
        record("animations_before", 0, animations);
        const char *disable = getenv("PINECONE_GTK_DISABLE_ANIMATIONS");
        if (disable && strcmp(disable, "1") == 0)
            g_object_set(settings, "gtk-enable-animations", FALSE, NULL);
        g_object_get(settings, "gtk-enable-animations", &animations, NULL);
        record("animations_after", 0, animations);
    }
    g_timeout_add(20, find_window, NULL);
}

static void on_activate(GApplication *app, void *data)
{
    (void)app; (void)data;
    record("activate_end", 0, 0);
    if (observed_window) attach_buffers(observed_window);
}

__attribute__((constructor)) static void loaded(void)
{
    int scoped = pc_gtk_activate_scope();
    if (scoped < 0) {
        perror("GTK diagnostic child preload scope");
        _exit(125);
    }
    enabled = scoped == 1;
    const char *value = getenv("PINECONE_GTK_FRAME_PROFILE");
    frame_details = enabled && value && strcmp(value, "1") == 0;
    if (enabled) record("constructor", 0, 0);
}

int g_application_run(GApplication *application, int argc, char **argv)
{
    int (*original)(GApplication *, int, char **) = dlsym(RTLD_NEXT, "g_application_run");
    if (!original) { fputs("missing g_application_run\n", stderr); _exit(127); }
    if (enabled) {
        record("application_run", 0, 0);
        FILE *maps = fopen("/proc/self/maps", "r");
        if (maps) {
            char line[1024];
            fprintf(stderr, "PINECONE_MAP:%ld:%s\n", (long)getpid(), g_get_prgname());
            while (fgets(line, sizeof line, maps)) fputs(line, stderr);
            fclose(maps);
        }
        g_signal_connect_after(application, "startup", G_CALLBACK(on_startup), NULL);
        g_signal_connect_after(application, "activate", G_CALLBACK(on_activate), NULL);
    }
    return original(application, argc, argv);
}
#endif
