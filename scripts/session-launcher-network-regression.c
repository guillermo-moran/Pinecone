#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif

static int net_access(const char *, int);
static pid_t net_fork(void);
static pid_t net_waitpid(pid_t, int *, int);
static pid_t net_setsid(void);
static int net_open(const char *, int, ...);
static int net_dup2(int, int);
static int net_close(int);
static int net_unsetenv(const char *);
static int net_execl(const char *, const char *, ...);
static _Noreturn void net_exit(int);
#define access net_access
#define fork net_fork
#define waitpid net_waitpid
#define setsid net_setsid
#define open net_open
#define dup2 net_dup2
#define close net_close
#define unsetenv net_unsetenv
#define execl net_execl
#define _exit net_exit
#define main launcher_main
#include "rootfs/pinecone-session-launcher.c"
#undef main
#undef access
#undef fork
#undef waitpid
#undef setsid
#undef open
#undef dup2
#undef close
#undef unsetenv
#undef execl
#undef _exit

static jmp_buf escaped;
static int available, forks, waits, execs, redirects, closed, detached, cleaned;
static int exit_code, open_error, detach_error, redirect_error;
static pid_t results[2];

static int net_access(const char *path, int mode)
{
    assert(strcmp(path, "/usr/local/bin/pinecone-network") == 0 && mode == X_OK);
    return available ? 0 : -1;
}
static pid_t net_fork(void) { assert(forks < 2); return results[forks++]; }
static pid_t net_waitpid(pid_t child, int *status, int options)
{
    assert(child == results[0] && status == NULL && options == 0);
    if (waits++ == 0) { errno = EINTR; return -1; }
    return child;
}
static pid_t net_setsid(void) { detached++; return detach_error ? -1 : 10; }
static int net_open(const char *path, int flags, ...)
{
    assert(detached == 1);
    if (open_error) return -1;
    if (strcmp(path, "/dev/null") == 0) {
        assert(flags == (O_RDONLY | O_CLOEXEC)); return 10;
    }
    assert(strcmp(path, "/var/log/pinecone/network.log") == 0);
    assert(flags == (O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC));
    return 11;
}
static int net_dup2(int from, int to)
{
    assert(to == redirects++);
    assert(from == (to == 0 ? 10 : 11));
    return redirect_error ? -1 : to;
}
static int net_close(int fd) { assert(fd == 10 + closed++); return 0; }
static int net_unsetenv(const char *name)
{
    assert(strcmp(name, "LD_PRELOAD") == 0); cleaned++; return 0;
}
static int net_execl(const char *path, const char *name, ...)
{
    assert(strcmp(path, "/usr/local/bin/pinecone-network") == 0);
    assert(strcmp(name, "pinecone-network") == 0);
    assert(redirects == 3 && closed == 2 && cleaned == 1 && waits == 0);
    va_list args;
    va_start(args, name);
    assert(strcmp(va_arg(args, char *), "start") == 0);
    assert(va_arg(args, char *) == NULL);
    va_end(args);
    execs++;
    return -1;
}
static _Noreturn void net_exit(int code) { exit_code = code; longjmp(escaped, 1); }
static void reset(void)
{
    available = 1;
    forks = waits = execs = redirects = closed = detached = cleaned = 0;
    exit_code = -1;
    open_error = detach_error = redirect_error = 0;
    results[0] = results[1] = 0;
}
static void child_exits(int expected)
{
    if (setjmp(escaped) == 0) {
        start_network_manager();
        assert(!"child returned");
    }
    assert(exit_code == expected && waits == 0);
}
int main(void)
{
    reset(); available = 0;
    start_network_manager(); assert(forks == 0);
    reset(); results[0] = -1;
    start_network_manager(); assert(waits == 0);
    reset(); results[0] = 42;
    start_network_manager(); assert(waits == 2 && forks == 1 && execs == 0);
    reset(); results[1] = -1;
    child_exits(1); assert(detached == 0);
    reset(); results[1] = 43;
    child_exits(0); assert(detached == 0 && execs == 0);
    reset(); detach_error = 1;
    child_exits(1); assert(execs == 0);
    reset(); open_error = 1;
    child_exits(1); assert(execs == 0);
    reset(); redirect_error = 1;
    child_exits(1); assert(execs == 0);
    reset(); child_exits(127); assert(execs == 1);
    puts("session launcher network regressions passed");
    return 0;
}
