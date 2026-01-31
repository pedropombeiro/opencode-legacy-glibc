/*
 * LD_PRELOAD library to clear LD_LIBRARY_PATH and LD_PRELOAD from the environment.
 *
 * This runs as a constructor before main(), ensuring that:
 * 1. The main binary loads with LD_LIBRARY_PATH set (finds its bundled libs)
 * 2. Child processes spawned by the binary won't inherit these variables
 *    (so they use the system's native libraries instead of bundled musl libs)
 *
 * However, we need to preserve these variables for opencode's own subprocesses
 * (like bun plugin installation), so we only clear them for non-opencode binaries.
 */

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((constructor))
static void clear_ld_vars(void) {
    char exe_path[4096];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    
    if (len > 0) {
        exe_path[len] = '\0';
        
        /* Check if this is the opencode binary - if so, keep the env vars */
        const char *basename = strrchr(exe_path, '/');
        if (basename) {
            basename++; /* skip the '/' */
        } else {
            basename = exe_path;
        }
        
        /* Keep env vars for opencode.bin (the main binary) */
        if (strcmp(basename, "opencode.bin") == 0) {
            return;
        }
    }
    
    /* Clear env vars for all other processes */
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_PRELOAD");
}
