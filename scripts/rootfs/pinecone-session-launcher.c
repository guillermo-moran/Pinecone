#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stddef.h>
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

static const char *const session_log = "/var/log/pinecone/phosh-session.log";
static const char *const settings_log = "/var/log/pinecone/settings.log";
static const char *const console_path = "/dev/ttyAMA0";
static const char *const settings_ready_path =
    "/run/user/0/pinecone-settings-prewarm-ready";

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

static void write_exit_status(int fd, int status, int before_ready)
{
    static const char prefix[] = "pinecone-session: Phosh exited with status ";
    static const char before_ready_suffix[] = " before ready\n";
    static const char suffix[] = "\n";
    char digits[16];
    size_t count = 0;
    unsigned int value = status < 0 ? 0u : (unsigned int)status;
    do {
        digits[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0 && count < sizeof(digits));

    (void)write_fully(fd, prefix, sizeof(prefix) - 1);
    while (count != 0)
        (void)write_fully(fd, &digits[--count], 1);
    if (before_ready) {
        (void)write_fully(
            fd, before_ready_suffix, sizeof(before_ready_suffix) - 1);
    } else {
        (void)write_fully(fd, suffix, sizeof(suffix) - 1);
    }
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

static int file_contains(const char *path, const char *needle)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || metadata.st_size <= 0 ||
        metadata.st_size > 1024 * 1024) {
        close(fd);
        return 0;
    }
    size_t length = (size_t)metadata.st_size;
    char *contents = malloc(length + 1);
    if (contents == NULL) {
        close(fd);
        return 0;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, contents + offset, length - offset);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            break;
        offset += (size_t)count;
    }
    close(fd);
    contents[offset] = '\0';
    int found = strstr(contents, needle) != NULL;
    free(contents);
    return found;
}

static int input_database_ready(void)
{
    DIR *directory = opendir("/run/udev/data");
    if (directory == NULL)
        return 0;
    int ready = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (strncmp(entry->d_name, "c13:", 4) != 0)
            continue;
        static const char prefix[] = "/run/udev/data/";
        char path[512];
        size_t name_length = strlen(entry->d_name);
        if (sizeof(prefix) + name_length > sizeof(path))
            continue;
        memcpy(path, prefix, sizeof(prefix) - 1);
        memcpy(path + sizeof(prefix) - 1, entry->d_name, name_length + 1);
        if (file_contains(path, "E:ID_INPUT_TOUCHSCREEN=1")) {
            ready = 1;
            break;
        }
    }
    closedir(directory);
    return ready;
}

static int udevd_is_running(void)
{
    int fd = open("/run/udev/udevd.pid", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    char text[32];
    ssize_t count;
    do {
        count = read(fd, text, sizeof(text) - 1);
    } while (count < 0 && errno == EINTR);
    close(fd);
    if (count <= 0)
        return 0;
    text[count] = '\0';
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (end == text || value <= 1 || value > INT_MAX)
        return 0;
    return kill((pid_t)value, 0) == 0 || errno == EPERM;
}

static int system_bus_ready(void)
{
    static const char path[] = "/run/dbus/system_bus_socket";
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (sizeof(path) > sizeof(address.sun_path))
        return 0;
    memcpy(address.sun_path, path, sizeof(path));

    int socket_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0)
        return 0;
    int result = connect(
        socket_fd,
        (const struct sockaddr *)&address,
        (socklen_t)(offsetof(struct sockaddr_un, sun_path) + sizeof(path))
    );
    close(socket_fd);
    return result == 0;
}

static void prepare_system_bus(void)
{
    if (system_bus_ready())
        return;

    make_directory("/run/dbus", 0755);
    if (access("/run/dbus/system_bus_socket", F_OK) == 0) {
        for (unsigned int attempt = 0; attempt < 20; attempt++) {
            usleep(50000);
            if (system_bus_ready())
                return;
        }
    }
    (void)unlink("/run/dbus/system_bus_socket");
    (void)unlink("/run/dbus/pid");
    if (access("/usr/bin/dbus-uuidgen", X_OK) == 0) {
        char *uuidgen[] = { "/usr/bin/dbus-uuidgen", "--ensure", NULL };
        if (spawn_and_wait(uuidgen) != 0) {
            errno = EIO;
            fatal("initialize D-Bus machine ID");
        }
    }

    char *daemon[] = {
        "/usr/bin/dbus-daemon", "--system", "--fork", "--nopidfile", NULL
    };
    if (access(daemon[0], X_OK) != 0 || spawn_and_wait(daemon) != 0) {
        errno = EIO;
        fatal("start system D-Bus");
    }
    for (unsigned int attempt = 0; attempt < 20; attempt++) {
        if (system_bus_ready())
            return;
        usleep(50000);
    }
    errno = ETIMEDOUT;
    fatal("wait for system D-Bus");
}

static void start_network_manager(void)
{
    static const char helper[] = "/usr/local/bin/pinecone-network";
    if (access(helper, X_OK) != 0)
        return;
    pid_t child = fork();
    if (child < 0)
        return;
    if (child == 0) {
        /* Reap only the intermediate child. Neither NM readiness nor daemon
         * lifetime is part of the graphical session's startup/shutdown. */
        pid_t daemon = fork();
        if (daemon < 0)
            _exit(1);
        if (daemon != 0)
            _exit(0);
        if (setsid() < 0)
            _exit(1);
        int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
        int output = open("/var/log/pinecone/network.log",
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (input < 0 || output < 0)
            _exit(1);
        if (dup2(input, STDIN_FILENO) < 0 ||
            dup2(output, STDOUT_FILENO) < 0 ||
            dup2(output, STDERR_FILENO) < 0)
            _exit(1);
        close(input);
        close(output);
        unsetenv("LD_PRELOAD");
        execl(helper, "pinecone-network", "start", (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
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
    setenv("PINECONE_WLROOTS_DMABUF", "1", 0);
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
    setenv("PINECONE_PIXMAN_DIAGNOSTICS", "0", 0);
    setenv("PINECONE_PIXMAN_OPERATOR_MASK", "0x3fff", 0);
    setenv("PINECONE_PHOSH_PROFILE", "1", 1);
    setenv("PINECONE_PHOSH_APP_MANIFEST", "/usr/share/pinecone/phosh-apps.list", 1);
    setenv("PINECONE_SETTINGS_PREWARM_READY_FILE", settings_ready_path, 0);
    setenv("PHOSH_DEBUG", "fake-builtin", 1);
    /* A layer client must never hold a fixed virtual display for seconds.
     * The patched Phoc publishes the latest layout at this deadline and
     * safely consumes a late configure acknowledgement afterward. */
    setenv("PHOC_LAYOUT_TRANSACTION_TIMEOUT_MS", "100", 0);
    if (getenv("PINECONE_PHOC_ANIMATIONS") == NULL ||
        strcmp(getenv("PINECONE_PHOC_ANIMATIONS"), "1") != 0) {
        setenv("PHOC_DEBUG", "disable-animations", 1);
    } else {
        unsetenv("PHOC_DEBUG");
    }
}

static void prepare_input(void)
{
    if (access("/sbin/udevd", X_OK) != 0 || access("/sbin/udevadm", X_OK) != 0)
        return;

    if (input_database_ready())
        return;

    /* rcS starts udevd and triggers the input subsystem before the login
     * shell. Give that in-flight work a short chance to publish its database
     * instead of immediately launching a second udevadm trigger and settle. */
    if (udevd_is_running()) {
        for (unsigned int attempt = 0; attempt < 8; attempt++) {
            usleep(25000);
            if (input_database_ready())
                return;
        }
    }

    if (!udevd_is_running()) {
        char *udevd[] = { "/sbin/udevd", "--daemon", NULL };
        (void)spawn_and_wait(udevd);
    }
    char *trigger[] = {
        "/sbin/udevadm", "trigger", "--subsystem-match=input", "--action=add", NULL
    };
    (void)spawn_and_wait(trigger);
    char *settle[] = { "/sbin/udevadm", "settle", "--timeout=2", NULL };
    (void)spawn_and_wait(settle);
}

static int run_session(void)
{
    configure_environment();
    prepare_system_bus();
    prepare_input();
    start_network_manager();
    (void)setpriority(PRIO_PROCESS, 0, -5);

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
    /* Remove Phosh's inherited nice=-5 boost before OSK initialization.
     * Keep nice=0 for the keyboard's lifetime: permanently lowering its
     * priority could penalize touch/typing latency under foreground load.
     * Use an absolute priority, not a relative increment. */
    if (setpriority(PRIO_PROCESS, 0, 0) != 0) {
        static const char warning[] =
            "pinecone-session: cannot normalize Squeekboard priority: ";
        const char *description = strerror(errno);
        (void)write_fully(STDERR_FILENO, warning, sizeof(warning) - 1);
        (void)write_fully(STDERR_FILENO, description, strlen(description));
        (void)write_fully(STDERR_FILENO, "\n", 1);
        /* Scheduling restrictions must not leave the session without an OSK. */
    }
    unsigned long delay = 10;
    const char *configured_delay =
        getenv("PINECONE_OSK_POST_READY_DELAY_SECONDS");
    if (configured_delay == NULL)
        configured_delay = getenv("PINECONE_OSK_START_DELAY_SECONDS");
    if (configured_delay != NULL)
        delay = strtoul(configured_delay, NULL, 10);
    sleep((unsigned int)delay);
    execl("/usr/bin/squeekboard", "squeekboard", (char *)NULL);
    _exit(127);
}

static void sleep_milliseconds(unsigned long milliseconds)
{
    struct timespec delay = {
        .tv_sec = (time_t)(milliseconds / 1000),
        .tv_nsec = (long)(milliseconds % 1000) * 1000000L,
    };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}

static pid_t start_settings_prewarm(void)
{
    const char *enabled = getenv("PINECONE_SETTINGS_PREWARM");
    if (enabled == NULL || strcmp(enabled, "1") != 0 ||
        access("/usr/bin/gnome-control-center", X_OK) != 0) {
        return -1;
    }

    (void)unlink(settings_ready_path);
    pid_t child = fork();
    if (child != 0)
        return child;

    unsigned long delay = 2500;
    const char *configured_delay =
        getenv("PINECONE_SETTINGS_PREWARM_DELAY_MS");
    if (configured_delay != NULL) {
        char *end = NULL;
        unsigned long parsed = strtoul(configured_delay, &end, 10);
        if (end != configured_delay && *end == '\0' && parsed <= 60000)
            delay = parsed;
    }
    sleep_milliseconds(delay);
    int log_fd = open(
        settings_log,
        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
        0644
    );
    if (log_fd >= 0) {
        (void)dup2(log_fd, STDOUT_FILENO);
        (void)dup2(log_fd, STDERR_FILENO);
        close(log_fd);
    }
    execl(
        "/usr/bin/gnome-control-center",
        "gnome-control-center",
        "--pinecone-prewarm",
        (char *)NULL
    );
    _exit(127);
}

static void terminate_child(pid_t child)
{
    if (child <= 0)
        return;
    if (kill(child, SIGTERM) != 0 && errno != ESRCH)
        return;
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

static int run_client(void)
{
    configure_environment();
    if (access("/usr/share/pinecone/phosh-ui/lockscreen.ui", R_OK) == 0)
        setenv("G_RESOURCE_OVERLAYS", "/mobi/phosh/ui=/usr/share/pinecone/phosh-ui", 1);

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
    pid_t osk = -1;
    pid_t settings_prewarm = -1;
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
                    osk = start_osk();
                    settings_prewarm = start_settings_prewarm();
                    announced_ready = 1;
                    break;
                }
            }
        }
    }
    int status = 0;
    while (waitpid(phosh, &status, 0) < 0 && errno == EINTR) {}
    int exit_status = WIFEXITED(status)
        ? WEXITSTATUS(status)
        : 128 + WTERMSIG(status);
    write_exit_status(log_fd, exit_status, !announced_ready);
    if (console >= 0)
        write_exit_status(console, exit_status, !announced_ready);
    close(output[0]);
    close(log_fd);
    if (console >= 0)
        close(console);
    terminate_child(settings_prewarm);
    terminate_child(osk);
    return exit_status;
}

static int run_settings(void)
{
    configure_environment();
    static const char launch_marker[] =
        "Pinecone app launch requested: settings\n";
    int console = open(console_path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (console >= 0) {
        (void)write_fully(
            console, launch_marker, sizeof(launch_marker) - 1);
        close(console);
    }
    int log_fd = open(
        settings_log,
        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
        0644
    );
    if (log_fd < 0)
        fatal("open Settings log");
    if (dup2(log_fd, STDOUT_FILENO) < 0 ||
        dup2(log_fd, STDERR_FILENO) < 0)
        fatal("redirect Settings log");
    close(log_fd);
    (void)write_fully(
        STDERR_FILENO, launch_marker, sizeof(launch_marker) - 1);
    execl(
        "/usr/bin/gnome-control-center",
        "gnome-control-center",
        (char *)NULL
    );
    fatal("exec gnome-control-center");
    return 1;
}

int main(int argc, char **argv)
{
    const char *name = strrchr(argv[0], '/');
    name = name != NULL ? name + 1 : argv[0];
    if (strcmp(name, "pinecone-phosh-client") == 0 ||
        (argc > 1 && strcmp(argv[1], "--client") == 0))
        return run_client();
    if (strcmp(name, "pinecone-launch-settings") == 0)
        return run_settings();
    return run_session();
}
