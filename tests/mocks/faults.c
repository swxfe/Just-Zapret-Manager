#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void reject_writes(void)
{
    if (getenv("JZM_FORBID_WRITES") != NULL) {
        static const char message[] = "unexpected filesystem mutation during read-only/UI operation\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(96);
    }
}

/* Inject failure at the OS boundary so both shell mv and native fs.rename
 * exercise the identical publication-failure assertions. */
int rename(const char *source, const char *destination)
{
    reject_writes();
    static int (*real_rename)(const char *, const char *);
    const char *root = getenv("ZM_TEST_ROOT");
    if (real_rename == NULL) *(void **)(&real_rename) = dlsym(RTLD_NEXT, "rename");
    if (real_rename == NULL) { errno = ENOSYS; return -1; }
    if (root != NULL) {
        char crash_path[4096], crash_marker[4096];
        int a = snprintf(crash_path, sizeof(crash_path), "%s/etc/zapret-manager/state.json", root);
        int b = snprintf(crash_marker, sizeof(crash_marker), "%s/crash-state-write", root);
        if (a > 0 && (size_t)a < sizeof(crash_path) && b > 0 && (size_t)b < sizeof(crash_marker) &&
            strcmp(crash_path, destination) == 0 && unlink(crash_marker) == 0) _exit(73);
        const char *files[] = { "state.json", "update.json" };
        const char *markers[] = { "fail-state-write", "fail-update-write" };
        for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
            char path[4096], marker[4096];
            int n = snprintf(path, sizeof(path), "%s/etc/zapret-manager/%s", root, files[i]);
            int m = snprintf(marker, sizeof(marker), "%s/%s", root, markers[i]);
            if (n > 0 && (size_t)n < sizeof(path) && m > 0 && (size_t)m < sizeof(marker) &&
                strcmp(path, destination) == 0 && unlink(marker) == 0) {
                errno = EIO;
                return -1;
            }
        }
    }
    return real_rename(source, destination);
}

pid_t fork(void)
{
    static pid_t (*real_fork)(void);
    if (getenv("JZM_FORBID_FORK") != NULL) {
        static const char message[] = "unexpected fork during read-only/UI operation\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(97);
    }
    if (real_fork == NULL) *(void **)(&real_fork) = dlsym(RTLD_NEXT, "fork");
    if (real_fork == NULL) { errno = ENOSYS; return -1; }
    return real_fork();
}

FILE *popen(const char *command, const char *mode)
{
    static FILE *(*real_popen)(const char *, const char *);
    if (getenv("JZM_FORBID_FORK") != NULL) {
        static const char message[] = "unexpected popen during read-only/UI operation\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(97);
    }
    if (real_popen == NULL) *(void **)(&real_popen) = dlsym(RTLD_NEXT, "popen");
    if (real_popen == NULL) { errno = ENOSYS; return NULL; }
    return real_popen(command, mode);
}

/* A trace for managed reads only; syscall logging cannot recurse into stdio. */
static void trace_read(const char *path)
{
    const char *root = getenv("ZM_TEST_ROOT"), *log = getenv("JZM_READ_LOG");
    if (root == NULL || log == NULL || strncmp(path, root, strlen(root)) != 0) return;
    const char *relative = path + strlen(root);
    if (strncmp(relative, "/etc/", 5) != 0 && strncmp(relative, "/usr/lib/opkg/", 14) != 0 &&
        strncmp(relative, "/lib/apk/", 9) != 0) return;
    int fd = (int)syscall(SYS_openat, AT_FDCWD, log, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) _exit(98);
    (void)syscall(SYS_write, fd, path, strlen(path));
    (void)syscall(SYS_write, fd, "\n", 1);
    (void)syscall(SYS_close, fd);
}

FILE *fopen(const char *path, const char *mode)
{
    static FILE *(*real_fopen)(const char *, const char *);
    if (real_fopen == NULL) *(void **)(&real_fopen) = dlsym(RTLD_NEXT, "fopen");
    if (real_fopen == NULL) { errno = ENOSYS; return NULL; }
    if (mode[0] == 'r' && strchr(mode, '+') == NULL) trace_read(path);
    else reject_writes();
    return real_fopen(path, mode);
}

int open(const char *path, int flags, ...)
{
    static int (*real_open)(const char *, int, ...);
    mode_t mode = 0;
    if ((flags & O_CREAT) || (flags & O_ACCMODE) != O_RDONLY) reject_writes();
    if (flags & O_CREAT) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, mode_t);
        va_end(arguments);
    }
    if (real_open == NULL) *(void **)(&real_open) = dlsym(RTLD_NEXT, "open");
    if (real_open == NULL) { errno = ENOSYS; return -1; }
    if (!(flags & O_CREAT) && (flags & O_ACCMODE) != O_WRONLY) trace_read(path);
    return real_open(path, flags, mode);
}

int mkdir(const char *path, mode_t mode)
{
    static int (*real_mkdir)(const char *, mode_t);
    reject_writes();
    if (real_mkdir == NULL) *(void **)(&real_mkdir) = dlsym(RTLD_NEXT, "mkdir");
    if (real_mkdir == NULL) { errno = ENOSYS; return -1; }
    return real_mkdir(path, mode);
}
