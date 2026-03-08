/*
 * LD_PRELOAD library to clear LD_LIBRARY_PATH and LD_PRELOAD from the environment.
 *
 * This runs as a constructor before main(), ensuring that:
 * 1. The main binary loads with LD_LIBRARY_PATH set (finds its bundled libs)
 * 2. Child processes spawned by the binary won't inherit these variables
 *    (so they use the system's native libraries instead of bundled musl libs)
 *
 * When opencode re-executes itself for plugin installation, it invokes
 * process.execPath (opencode.bin), which is a shell wrapper that re-sets
 * LD_LIBRARY_PATH and LD_PRELOAD before exec'ing the real binary.
 */

#include <stdlib.h>

__attribute__((constructor))
static void clear_ld_vars(void) {
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_PRELOAD");
}
