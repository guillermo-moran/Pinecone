#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *const session_log = "/var/log/pinecone/phosh-session.log";
static const char *const console_path = "/dev/ttyAMA0";

static void fatal(const char *operation)
{
    static const char prefix[] = "pinecone-session: ";
    static const char separator[] = ": ";
    const char *description = strerror(errno);
    (void)write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
    (void)write(STDERR_FILENO, operation, strlen(operation));
    (void)write(STDERR_FILENO, separator, sizeof(separator) - 1);
    (void)write(STDERR_FILENO, description, strlen(description));
    (void)write(STDERR_FILENO, "\n", 1);
    exit(1);
}

static int write_fully(int fd, const void *bytes, size_t count)
{
    const unsigned char *cursor = bytes;
    while (count != 0) {
        ssize_t written = write(fd, cursor, count);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        cursor += (size_t)written;
        count -= (size_t)written;
    }
    return 0;
}

static void make_directory(const char *path, mode_t mode)
{
    if (mkdir(path, mode) != 0 && errno != EEXIST)
        fatal(path);
    if (chmod(path, mode) != 0)
        fatal(path);
}

static int spawn_and_wait(char *const arguments[])
{
    pid_t child = fork();
    if (child < 0)
        return -1;
    if (child == 0) {
        execv(arguments[0], arguments);
        _exit(127);
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR)
            return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void configure_environment(void)
{
    make_directory("/run/user", 0755);
    make_directory("/run/user/0", 0700);
    make_directory("/run/dbus", 0755);
    make_directory("/var/log/pinecone", 0755);

    setenv("XDG_RUNTIME_DIR", "/run/user/0", 1);
    setenv("XDG_SESSION_TYPE", "wayland", 1);
    setenv("XDG_CURRENT_DESKTOP", "Phosh:GNOME", 1);
    setenv("WLR_BACKENDS", "drm,libinput", 1);
    setenv("WLR_RENDERER", "pixman", 1);
    setenv("WLR_RENDERER_ALLOW_SOFTWARE", "1", 1);
    setenv("WLR_LIBINPUT_NO_DEVICES", "1", 1);
    setenv("WLR_LOG", getenv("PINECONE_WLR_LOG") != NULL ? getenv("PINECONE_WLR_LOG") : "0", 1);
    setenv("XKB_DEFAULT_LAYOUT", "us", 1);
    setenv("LIBSEAT_BACKEND", "noop", 1);
    setenv("NO_AT_BRIDGE", "1", 1);
    setenv("GTK_A11Y", "none", 1);
    setenv("_GNOME_SESSION_ACCELERATED", "1", 1);
    setenv("_GNOME_IS_SOFTWARE_RENDERING", "1", 1);
    setenv("_GNOME_SESSION_RENDERER", "pixman", 1);
    setenv("GSK_RENDERER", "cairo", 1);
    setenv("LD_PRELOAD", "/usr/lib/libpinecone-pixman.so", 1);
    setenv("PHOSH_DEBUG", "fake-builtin", 1);
    setenv("PHOC_DEBUG", "disable-animations", 1);
}

static void prepare_input(void)
{
    if (access("/sbin/udevd", X_OK) != 0 || access("/sbin/udevadm", X_OK) != 0)
        return;

    char *udevd[] = { "/sbin/udevd", "--daemon", NULL };
    (void)spawn_and_wait(udevd);
    char *trigger[] = {
        "/sbin/udevadm", "trigger", "--subsystem-match=input", "--action=add", NULL
    };
    (void)spawn_and_wait(trigger);
    char *settle[] = { "/sbin/udevadm", "settle", "--timeout=10", NULL };
    (void)spawn_and_wait(settle);
}

static int run_session(void)
{
    configure_environment();
    prepare_input();

    const char *configuration = access("/etc/phosh/phoc.ini", R_OK) == 0
        ? "/etc/phosh/phoc.ini"
        : "/usr/share/phosh/phoc.ini";
    int log_fd = open(
        "/var/log/pinecone/phoc.log",
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
        0644
    );
    if (log_fd < 0)
        fatal("open phoc log");
    if (dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0)
        fatal("redirect phoc log");
    close(log_fd);

    char *arguments[11] = {
        "/usr/bin/dbus-run-session", "--", "/usr/bin/phoc", NULL,
        "-C", (char *)configuration,
        "-E", "/usr/local/bin/pinecone-phosh-client", NULL
    };
    if (getenv("PINECONE_PHOC_VERBOSE") != NULL &&
        strcmp(getenv("PINECONE_PHOC_VERBOSE"), "1") == 0) {
        arguments[3] = "-v";
    } else {
        for (size_t index = 3; index < 9; index++)
            arguments[index] = arguments[index + 1];
    }
    execv(arguments[0], arguments);
    fatal("exec dbus-run-session");
    return 1;
}

static pid_t start_osk(void)
{
    if (access("/usr/bin/squeekboard", X_OK) != 0)
        return -1;
    pid_t child = fork();
    if (child != 0)
        return child;
    unsigned long delay = 60;
    const char *configured_delay = getenv("PINECONE_OSK_START_DELAY_SECONDS");
    if (configured_delay != NULL)
        delay = strtoul(configured_delay, NULL, 10);
    sleep((unsigned int)delay);
    execl("/usr/bin/squeekboard", "squeekboard", (char *)NULL);
    _exit(127);
}

static int run_client(void)
{
    configure_environment();
    if (access("/usr/share/pinecone/phosh-ui/lockscreen.ui", R_OK) == 0)
        setenv("G_RESOURCE_OVERLAYS", "/mobi/phosh/ui=/usr/share/pinecone/phosh-ui", 1);

    char *activation[] = {
        "/usr/bin/dbus-update-activation-environment",
        "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_RUNTIME_DIR",
        "XDG_SESSION_TYPE", NULL
    };
    if (access(activation[0], X_OK) == 0)
        (void)spawn_and_wait(activation);

    int output[2];
    if (pipe(output) != 0)
        fatal("pipe");
    pid_t phosh = fork();
    if (phosh < 0)
        fatal("fork phosh");
    if (phosh == 0) {
        close(output[0]);
        if (dup2(output[1], STDOUT_FILENO) < 0 ||
            dup2(output[1], STDERR_FILENO) < 0)
            _exit(126);
        close(output[1]);
        execl("/usr/libexec/phosh", "phosh", (char *)NULL);
        _exit(127);
    }
    close(output[1]);

    int log_fd = open(session_log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (log_fd < 0)
        fatal("open Phosh session log");
    int console = open(console_path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    pid_t osk = start_osk();
    int announced_ready = 0;
    static const char marker[] = "Phosh ready after";
    size_t marker_progress = 0;
    unsigned char buffer[4096];
    for (;;) {
        ssize_t count = read(output[0], buffer, sizeof(buffer));
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (count == 0)
            break;
        (void)write_fully(log_fd, buffer, (size_t)count);
        if (!announced_ready) {
            for (ssize_t index = 0; index < count; index++) {
                unsigned char byte = buffer[index];
                if (byte == (unsigned char)marker[marker_progress]) {
                    marker_progress++;
                } else {
                    marker_progress = byte == (unsigned char)marker[0] ? 1u : 0u;
                }
                if (marker_progress == sizeof(marker) - 1) {
                    static const char ready[] =
                        "Phosh ready after guest initialization\n";
                    if (console >= 0)
                        (void)write_fully(console, ready, sizeof(ready) - 1);
                    announced_ready = 1;
                    break;
                }
            }
        }
    }
    close(output[0]);
    close(log_fd);
    if (console >= 0)
        close(console);

    int status = 0;
    while (waitpid(phosh, &status, 0) < 0 && errno == EINTR) {}
    if (osk > 0) {
        kill(osk, SIGTERM);
        while (waitpid(osk, NULL, 0) < 0 && errno == EINTR) {}
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(int argc, char **argv)
{
    const char *name = strrchr(argv[0], '/');
    name = name != NULL ? name + 1 : argv[0];
    if (strcmp(name, "pinecone-phosh-client") == 0 ||
        (argc > 1 && strcmp(argv[1], "--client") == 0))
        return run_client();
    return run_session();
}
