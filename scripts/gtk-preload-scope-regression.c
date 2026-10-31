#define _GNU_SOURCE
#include "guest-gtk-preload-scope.h"
#include <sys/wait.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); \
} } while (0)

#ifdef PC_SCOPE_FIXTURE
__attribute__((constructor)) static void fixture_loaded(void)
{
#if PC_SCOPE_FIXTURE == 1
    CHECK(pc_gtk_activate_scope() == 1);
#endif
    FILE *log = fopen(getenv("PC_SCOPE_LOG"), "a");
    CHECK(log != NULL);
    CHECK(fprintf(log, "%d %ld\n", PC_SCOPE_FIXTURE, (long)getpid()) > 0);
    CHECK(fclose(log) == 0);
}
#else
extern char **environ;

static void reset_environment(void)
{
    const char *keys[] = {"PINECONE_GTK_LATENCY", PC_GTK_SCOPE_PID_ENV,
        PC_GTK_SCOPE_TOKEN_ENV, PC_GTK_SCOPE_EXTRA_ENV, "LD_PRELOAD"};
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; ++i)
        CHECK(unsetenv(keys[i]) == 0);
}

static char **snapshot(void)
{
    size_t count = 0;
    while (environ[count]) ++count;
    char **result = calloc(count + 1, sizeof *result);
    CHECK(result != NULL);
    for (size_t i = 0; i < count; ++i) {
        result[i] = strdup(environ[i]);
        CHECK(result[i] != NULL);
    }
    return result;
}

static void unchanged(char **before)
{
    size_t i = 0;
    for (; before[i]; ++i) {
        CHECK(environ[i] && !strcmp(before[i], environ[i]));
        free(before[i]);
    }
    CHECK(!environ[i]);
    free(before);
}

static void filter_tests(void)
{
    struct { const char *input, *probe, *expected; int result; } cases[] = {
        {NULL, "probe", NULL, 0},
        {"", "probe", NULL, 0},
        {"a:: \t\n", "probe", NULL, 0},
        {"probe", "probe", "", 1},
        {"::probe::", "probe", "", 1},
        {"a:probe:b:probe:a", "probe", "a:b:a", 1},
        {" \tprobe\n\ra\vprobe\fb:probe ", "probe", "a:b", 1},
        {"/x/probe.so:/y/probe.so:/x/probe.so.1:/x/probe.so", "/x/probe.so",
            "/y/probe.so:/x/probe.so.1", 1},
        {"'probe':\"probe\":\\probe:probe", "probe", "'probe':\"probe\":\\probe", 1},
        {"probe:\xc2\xa0:probe", "probe", "\xc2\xa0", 1},
        {"./probe.so:a", "./probe.so", "a", 1},
        {PC_PRODUCTION_PIXMAN_TOKEN ":" PC_GTK_PROBE_TOKEN ":unrelated.so",
            PC_GTK_PROBE_TOKEN, PC_PRODUCTION_PIXMAN_TOKEN ":unrelated.so", 1},
        {"probe", NULL, NULL, -1},
        {"probe", "", NULL, -1},
        {"probe", "a:b", NULL, -1},
        {"probe", "a\tb", NULL, -1},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        char *filtered = NULL;
        CHECK(pc_preload_without_probe(cases[i].input, cases[i].probe, &filtered) == cases[i].result);
        if (cases[i].expected) CHECK(filtered && !strcmp(filtered, cases[i].expected));
        else CHECK(!filtered);
        free(filtered);
    }
    puts("PASS 16 exact-token/delimiter cases");
}

static void policy_tests(void)
{
    reset_environment();
    CHECK(setenv("LD_PRELOAD", "  unlisted.so::" PC_GTK_PROBE_TOKEN, 1) == 0);
    char **before = snapshot();
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == 0);
    CHECK(pc_gtk_activate_scope() == 0);
    unchanged(before);
    CHECK(setenv("PINECONE_GTK_LATENCY", "0", 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == 0);
    CHECK(pc_gtk_activate_scope() == 0);
    unchanged(before);
    CHECK(setenv("PINECONE_GTK_LATENCY", "1", 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_activate_scope() == 0);
    unchanged(before);
    CHECK(setenv(PC_GTK_SCOPE_PID_ENV, "not-this-pid", 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_activate_scope() == 0);
    unchanged(before);
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == 1);
    CHECK(pc_gtk_activate_scope() == 1);
    CHECK(!strcmp(getenv("LD_PRELOAD"), "unlisted.so"));

    CHECK(setenv("LD_PRELOAD", PC_PRODUCTION_PIXMAN_TOKEN ":" PC_GTK_PROBE_TOKEN ":"
        PC_GTK_CHILD_DIAGNOSTICS ":/other/libpinecone-text-commit.so:unrelated.so:unrelated.so", 1) == 0);
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == 1);
    CHECK(pc_gtk_activate_scope() == 1);
    CHECK(!strcmp(getenv("LD_PRELOAD"), PC_PRODUCTION_PIXMAN_TOKEN
        ":/other/libpinecone-text-commit.so:unrelated.so:unrelated.so"));

    CHECK(setenv(PC_GTK_SCOPE_TOKEN_ENV, "./custom-gtk.so", 1) == 0);
    CHECK(setenv(PC_GTK_SCOPE_EXTRA_ENV, "custom-commit.so\t/custom-wait.so:/custom-wordexp.so", 1) == 0);
    CHECK(setenv("LD_PRELOAD", "./custom-gtk.so:custom-commit.so:/custom-wait.so:/custom-wordexp.so:keep.so", 1) == 0);
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == 1);
    CHECK(pc_gtk_activate_scope() == 1);
    CHECK(!strcmp(getenv("LD_PRELOAD"), "keep.so"));
    CHECK(setenv("LD_PRELOAD", "./custom-gtk.so", 1) == 0);
    CHECK(pc_gtk_activate_scope() == 1);
    CHECK(!getenv("LD_PRELOAD"));

    CHECK(setenv("LD_PRELOAD", "other.so", 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == -1);
    CHECK(pc_gtk_activate_scope() == -1);
    unchanged(before);
    CHECK(setenv("LD_PRELOAD", "./custom-gtk.so:" PC_PRODUCTION_PIXMAN_TOKEN, 1) == 0);
    CHECK(setenv(PC_GTK_SCOPE_EXTRA_ENV, PC_PRODUCTION_PIXMAN_TOKEN, 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == -1);
    CHECK(pc_gtk_activate_scope() == -1);
    unchanged(before);
    CHECK(setenv(PC_GTK_SCOPE_TOKEN_ENV, PC_PRODUCTION_PIXMAN_TOKEN, 1) == 0);
    before = snapshot();
    CHECK(pc_gtk_prepare_scope(getenv("LD_PRELOAD")) == -1);
    unchanged(before);
    puts("PASS 11 environment policy cases (full no-op snapshots included)");
}

int main(int argc, char **argv)
{
    if (argc > 1) {
        int child = !strcmp(argv[1], "--child");
        if (!child && getenv("PC_SCOPE_EMULATE")) CHECK(pc_gtk_activate_scope() == 1);
        const char *preload = getenv("LD_PRELOAD");
        CHECK(preload && !strcmp(preload, getenv("PC_SCOPE_EXPECTED")));
        CHECK(!getenv("PINECONE_GTK_PRELOAD"));
        if (child) {
            char **before = snapshot();
            CHECK(pc_gtk_activate_scope() == 0);
            unchanged(before);
            puts("PASS exec child inherits only retained preload tokens");
            return 0;
        }
        char pid[32];
        snprintf(pid, sizeof pid, "%ld", (long)getpid());
        CHECK(!strcmp(getenv(PC_GTK_SCOPE_PID_ENV), pid));
        pid_t spawned = fork();
        CHECK(spawned >= 0);
        if (!spawned) { execl(argv[0], argv[0], "--child", (char *)NULL); _exit(127); }
        int status;
        CHECK(waitpid(spawned, &status, 0) == spawned);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        puts("PASS actual launcher tags exec-preserved PID; parent cleanup before child exec");
        return 0;
    }
    filter_tests();
    policy_tests();
    return 0;
}
#endif
