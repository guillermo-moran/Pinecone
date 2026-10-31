#ifndef PINECONE_GTK_PRELOAD_SCOPE_H
#define PINECONE_GTK_PRELOAD_SCOPE_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Diagnostic launcher only. An alternate probe location must be supplied as
 * its exact LD_PRELOAD token, not a basename or substring inferred from a path. */
#define PC_GTK_PROBE_TOKEN "/usr/local/lib/libpinecone-gtk-latency.so"
#define PC_GTK_SCOPE_PID_ENV "PINECONE_GTK_PROFILE_PID"
#define PC_GTK_SCOPE_TOKEN_ENV "PINECONE_GTK_PROBE_TOKEN"
#define PC_GTK_SCOPE_EXTRA_ENV "PINECONE_GTK_SCOPED_PRELOADS"
#define PC_GTK_CHILD_DIAGNOSTICS \
    "/usr/local/lib/pinecone-text-insertion/libpinecone-text-commit.so:" \
    "/usr/local/lib/pinecone-text-insertion/libpinecone-text-wait.so:" \
    "/usr/local/lib/pinecone-text-insertion/libpinecone-wordexp-trace.so"
#define PC_PRODUCTION_PIXMAN_TOKEN "/usr/lib/libpinecone-pixman.so"

static inline int pc_preload_separator(unsigned char c)
{
    /* musl load_preload uses ':' or isspace; no shell quoting/escaping. */
    return c == ':' || c == ' ' || (c >= '\t' && c <= '\r');
}

/* 1: exact matches removed, 0: absent (no allocation), -1: invalid/error.
 * Preserve remaining tokens, order, and duplicates; normalize separators only
 * when a diagnostic token was removed. Never mutate the caller's string. */
static inline int pc_preload_without_probe(const char *preload, const char *probe,
                                           char **filtered)
{
    *filtered = NULL;
    if (!probe || !*probe) { errno = EINVAL; return -1; }
    for (const unsigned char *p = (const unsigned char *)probe; *p; ++p)
        if (pc_preload_separator(*p)) { errno = EINVAL; return -1; }
    if (!preload) return 0;
    size_t probe_length = strlen(probe);
    int found = 0;
    for (const char *p = preload; *p;) {
        while (pc_preload_separator((unsigned char)*p)) ++p;
        const char *start = p;
        while (*p && !pc_preload_separator((unsigned char)*p)) ++p;
        if ((size_t)(p - start) == probe_length && !memcmp(start, probe, probe_length))
            found = 1;
    }
    if (!found) return 0;
    char *result = malloc(strlen(preload) + 1);
    if (!result) return -1;
    size_t used = 0;
    for (const char *p = preload; *p;) {
        while (pc_preload_separator((unsigned char)*p)) ++p;
        const char *start = p;
        while (*p && !pc_preload_separator((unsigned char)*p)) ++p;
        size_t length = (size_t)(p - start);
        if (!length || (length == probe_length && !memcmp(start, probe, length))) continue;
        if (used) result[used++] = ':';
        memcpy(result + used, start, length);
        used += length;
    }
    result[used] = 0;
    *filtered = result;
    return 1;
}

static inline int pc_gtk_profile_requested(void)
{
    const char *value = getenv("PINECONE_GTK_LATENCY");
    return value && !strcmp(value, "1");
}

static inline const char *pc_gtk_probe_token(void)
{
    const char *token = getenv(PC_GTK_SCOPE_TOKEN_ENV);
    return token ? token : PC_GTK_PROBE_TOKEN;
}

/* Remove additional explicitly scoped diagnostics, never inferred basenames.
 * Build the complete result before changing environ. */
static inline int pc_preload_remove_list(char **preload, const char *tokens)
{
    if (!tokens) return 0;
    for (const char *p = tokens; *p;) {
        while (pc_preload_separator((unsigned char)*p)) ++p;
        const char *start = p;
        while (*p && !pc_preload_separator((unsigned char)*p)) ++p;
        size_t length = (size_t)(p - start);
        if (!length) continue;
        char *token = malloc(length + 1);
        if (!token) return -1;
        memcpy(token, start, length);
        token[length] = 0;
        if (!strcmp(token, PC_PRODUCTION_PIXMAN_TOKEN)) {
            free(token);
            errno = EINVAL;
            return -1;
        }
        char *filtered = NULL;
        int result = pc_preload_without_probe(*preload, token, &filtered);
        free(token);
        if (result < 0) return -1;
        if (result) { free(*preload); *preload = filtered; }
    }
    return 0;
}

static inline int pc_gtk_child_preload(const char *preload, char **filtered)
{
    *filtered = NULL;
    const char *probe = pc_gtk_probe_token();
    if (!strcmp(probe, PC_PRODUCTION_PIXMAN_TOKEN)) { errno = EINVAL; return -1; }
    int result = pc_preload_without_probe(preload, probe, filtered);
    if (result != 1) { errno = EINVAL; return -1; }
    if (pc_preload_remove_list(filtered, PC_GTK_CHILD_DIAGNOSTICS) ||
        pc_preload_remove_list(filtered, getenv(PC_GTK_SCOPE_EXTRA_ENV))) {
        free(*filtered);
        *filtered = NULL;
        return -1;
    }
    return 1;
}

/* Runs before exec, whose PID is preserved. Refuse an unrecognised manifest
 * instead of claiming child scoping while leaving the probe inherited. */
static inline int pc_gtk_prepare_scope(const char *preload)
{
    if (!pc_gtk_profile_requested()) return 0;
    char *filtered = NULL;
    int result = pc_gtk_child_preload(preload, &filtered);
    free(filtered);
    if (result != 1) { errno = EINVAL; return -1; }
    char pid[32];
    int length = snprintf(pid, sizeof pid, "%ld", (long)getpid());
    if (length <= 0 || (size_t)length >= sizeof pid) { errno = EINVAL; return -1; }
    return setenv(PC_GTK_SCOPE_PID_ENV, pid, 1) ? -1 : 1;
}

/* Runs in the probe constructor, before application startup can spawn a shell.
 * The probe remains loaded here, but ordinary child execs inherit only the
 * remaining preload tokens. A PID mismatch is a strict environment no-op. */
static inline int pc_gtk_activate_scope(void)
{
    if (!pc_gtk_profile_requested()) return 0;
    const char *designated = getenv(PC_GTK_SCOPE_PID_ENV);
    if (!designated) return 0;
    char pid[32];
    int length = snprintf(pid, sizeof pid, "%ld", (long)getpid());
    if (length <= 0 || (size_t)length >= sizeof pid || strcmp(designated, pid)) return 0;
    char *filtered = NULL;
    int result = pc_gtk_child_preload(getenv("LD_PRELOAD"), &filtered);
    if (result != 1) { free(filtered); errno = EINVAL; return -1; }
    int failed = *filtered ? setenv("LD_PRELOAD", filtered, 1) : unsetenv("LD_PRELOAD");
    free(filtered);
    return failed ? -1 : 1;
}

#endif
