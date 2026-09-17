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

/* The unrelated system-bus code is not exercised by this host-side test. */
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif

static int osk_access(const char *, int);
static pid_t osk_fork(void);
static int osk_setpriority(int, id_t, int);
static unsigned int osk_sleep(unsigned int);
static int osk_execl(const char *, const char *, ...);
static _Noreturn void osk_exit(int);

#define access osk_access
#define fork osk_fork
#define setpriority osk_setpriority
#define sleep osk_sleep
#define execl osk_execl
#define _exit osk_exit
#define main session_launcher_main
#include "rootfs/pinecone-session-launcher.c"
#undef main
#undef access
#undef fork
#undef setpriority
#undef sleep
#undef execl
#undef _exit

static jmp_buf exited;
static int available, priority_error, priority_calls, exec_calls, exit_status;
static int child_priority, real_priority, kernel_priority_error;
static unsigned int slept;
static pid_t fork_result;
static const char *test_executable;

static int osk_access(const char *path, int mode)
{
    assert(strcmp(path, "/usr/bin/squeekboard") == 0);
    assert(mode == X_OK);
    return available ? 0 : -1;
}

static pid_t osk_fork(void)
{
    return fork_result;
}

static int osk_setpriority(int which, id_t who, int value)
{
    assert(which == PRIO_PROCESS && who == 0);
    assert(value == 0);
    assert(priority_calls++ == 0);
    assert(slept == UINT_MAX && exec_calls == 0);
    if (priority_error) {
        errno = priority_error;
        return -1;
    }
    child_priority = value;
    if (real_priority) {
        int result = setpriority(which, who, value);
        if (result != 0)
            kernel_priority_error = errno;
        return result;
    }
    return 0;
}

static unsigned int osk_sleep(unsigned int seconds)
{
    assert(priority_calls == 1);
    slept = seconds;
    return 0;
}

static int osk_execl(const char *path, const char *name, ...)
{
    assert(priority_calls == 1 && slept != UINT_MAX);
    assert(strcmp(path, "/usr/bin/squeekboard") == 0);
    assert(strcmp(name, "squeekboard") == 0);
    va_list arguments;
    va_start(arguments, name);
    assert(va_arg(arguments, char *) == NULL);
    va_end(arguments);
    exec_calls++;
    if (real_priority) {
        /* Reach exec even when priority normalization fails: the production
         * warning must not prevent keyboard startup. Only known environment
         * restrictions skip the kernel check; unexpected errors still fail. */
        if (kernel_priority_error != 0) {
            int unavailable = kernel_priority_error == EPERM ||
                kernel_priority_error == EACCES ||
                kernel_priority_error == ENOSYS ||
                kernel_priority_error == ENOTSUP;
            dprintf(STDERR_FILENO,
                "%s: kernel OSK priority/exec check: setpriority: %s\n",
                unavailable ? "SKIP" : "FAIL",
                strerror(kernel_priority_error));
            _exit(unavailable ? 77 : 1);
        }
        char *args[] = { (char *)test_executable, "--check-priority", NULL };
        execv(args[0], args);
        _exit(125);
    }
    errno = ENOENT;
    return -1;
}

static _Noreturn void osk_exit(int status)
{
    exit_status = status;
    longjmp(exited, 1);
}

static void reset(void)
{
    available = 1;
    priority_error = priority_calls = exec_calls = exit_status = 0;
    child_priority = -5;
    real_priority = 0;
    kernel_priority_error = 0;
    slept = UINT_MAX;
    fork_result = 0;
    unsetenv("PINECONE_OSK_POST_READY_DELAY_SECONDS");
    unsetenv("PINECONE_OSK_START_DELAY_SECONDS");
}

static void run_child(unsigned int expected_delay)
{
    if (setjmp(exited) == 0) {
        (void)start_osk();
        assert(!"OSK child returned instead of exec/exit");
    }
    assert(priority_calls == 1 && exec_calls == 1);
    assert(slept == expected_delay && exit_status == 127);
    assert(child_priority == (priority_error ? -5 : 0));
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--check-priority") == 0)
        return getpriority(PRIO_PROCESS, 0) == 0 ? 0 : 1;
    test_executable = argv[0];
    reset();
    available = 0;
    assert(start_osk() == -1);
    assert(priority_calls == 0 && exec_calls == 0);

    reset();
    fork_result = -1;
    assert(start_osk() == -1);
    assert(priority_calls == 0 && slept == UINT_MAX);

    reset();
    fork_result = 123;
    assert(start_osk() == 123);
    assert(priority_calls == 0 && slept == UINT_MAX);
    assert(child_priority == -5);

    reset();
    /* Remove the inherited boost without leaving typing at background nice. */
    run_child(10);
    reset();
    child_priority = 0;
    run_child(10);
    reset();
    child_priority = 5;
    setenv("PINECONE_OSK_START_DELAY_SECONDS", "2", 1);
    run_child(2);
    reset();
    setenv("PINECONE_OSK_START_DELAY_SECONDS", "2", 1);
    setenv("PINECONE_OSK_POST_READY_DELAY_SECONDS", "0", 1);
    run_child(0);

    reset();
    priority_error = EPERM;
    int diagnostic[2];
    assert(pipe(diagnostic) == 0);
    int saved_stderr = dup(STDERR_FILENO);
    assert(saved_stderr >= 0);
    assert(dup2(diagnostic[1], STDERR_FILENO) >= 0);
    close(diagnostic[1]);
    run_child(10);
    assert(dup2(saved_stderr, STDERR_FILENO) >= 0);
    close(saved_stderr);
    char warning[512];
    ssize_t count = read(diagnostic[0], warning, sizeof(warning) - 1);
    assert(count > 0);
    warning[count] = '\0';
    close(diagnostic[0]);
    assert(strstr(warning, "cannot normalize Squeekboard priority") != NULL);
    assert(strstr(warning, strerror(EPERM)) != NULL);

    /* Check normal kernel priority across exec without launching a desktop,
     * changing the test parent's priority, or sleeping. The inherited -5
     * case above is mocked so the test needs no privilege to raise priority. */
    reset();
    int parent_priority = getpriority(PRIO_PROCESS, 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        real_priority = 1;
        (void)start_osk();
        _exit(124);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status));
    assert(WEXITSTATUS(status) == 0 || WEXITSTATUS(status) == 77);
    assert(getpriority(PRIO_PROCESS, 0) == parent_priority);
    puts(WEXITSTATUS(status) == 77
        ? "session launcher OSK mocked regressions passed; kernel check skipped"
        : "session launcher OSK regressions passed (including kernel priority/exec)");
    return 0;
}
