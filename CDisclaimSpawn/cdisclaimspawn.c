#include "cdisclaimspawn.h"

#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef int (*disclaim_fn_t)(posix_spawnattr_t *, int);

static volatile pid_t g_child = 0;

static void forward_signal(int sig) {
    pid_t child = g_child;
    if (child > 0) {
        kill(child, sig);
    }
}

int pippin_respawn_disclaimed(char *const argv[]) {
    // Resolve the private SPI at runtime. If it's gone, re-execing would change
    // no responsibility — skip it (the caller runs in-process).
    disclaim_fn_t set_disclaim =
        (disclaim_fn_t)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (set_disclaim == NULL) {
        return -2;
    }

    char path[4096];
    uint32_t size = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        return -1;
    }

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        return -1;
    }
    // Detach the child from our TCC responsibility so it is responsible for
    // itself — its consent then keys on pippin's own code identity.
    set_disclaim(&attr, 1);

    // file_actions == NULL inherits fds 0/1/2, keeping the re-exec transparent to
    // terminals and the MCP stdio pipe alike. environ carries the PIPPIN_DISCLAIMED
    // guard the caller set, so the child (and anything it spawns) won't re-exec.
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        errno = rc;
        return -1;
    }

    g_child = pid;
    signal(SIGINT, forward_signal);
    signal(SIGTERM, forward_signal);
    signal(SIGHUP, forward_signal);
    signal(SIGQUIT, forward_signal);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}
