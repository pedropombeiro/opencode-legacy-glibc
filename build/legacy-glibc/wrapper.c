/*
 * ELF wrapper for the opencode binary.
 *
 * This sits at lib/opencode (where process.execPath points) and:
 * 1. Resolves its own directory via /proc/self/exe
 * 2. Sets LD_LIBRARY_PATH to that directory (for musl libs)
 * 3. Sets LD_PRELOAD to clear_ldpath.so (which clears both LD_PRELOAD
 *    and LD_LIBRARY_PATH from the C environ before main)
 * 4. Execs the real binary at lib/opencode.bin
 *
 * This solves the process.execPath re-invocation problem: when opencode
 * spawns "process.execPath add --cwd ... <pkg>" for plugin install, it
 * hits this wrapper which re-establishes the environment, then
 * clear_ldpath.so cleans it up for child processes.
 *
 * Compiled as a static PIE binary with musl (-static) so it runs on
 * any Linux system regardless of glibc version.
 */

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char exe_path[PATH_MAX];
    char dir_path[PATH_MAX];
    char real_bin[PATH_MAX];
    char preload_path[PATH_MAX];

    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len < 0) {
        perror("readlink /proc/self/exe");
        return 127;
    }
    exe_path[len] = '\0';

    /* Extract directory from exe_path */
    strncpy(dir_path, exe_path, sizeof(dir_path));
    char *last_slash = strrchr(dir_path, '/');
    if (last_slash)
        *last_slash = '\0';
    else {
        fprintf(stderr, "wrapper: cannot determine directory\n");
        return 127;
    }

    /* Build paths */
    snprintf(real_bin, sizeof(real_bin), "%s/opencode.bin", dir_path);
    snprintf(preload_path, sizeof(preload_path), "%s/clear_ldpath.so", dir_path);

    setenv("LD_LIBRARY_PATH", dir_path, 1);
    setenv("LD_PRELOAD", preload_path, 1);

    /* Replace argv[0] with the real binary path */
    argv[0] = real_bin;
    execv(real_bin, argv);

    perror("execv");
    return 127;
}
