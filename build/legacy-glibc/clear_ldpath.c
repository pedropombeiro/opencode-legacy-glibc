/*
 * LD_PRELOAD library to clear LD_PRELOAD from the environment.
 *
 * This runs as a constructor before main(), ensuring that:
 * 1. The main binary loads with LD_PRELOAD set (this library is loaded)
 * 2. Child processes won't inherit LD_PRELOAD (preventing clear_ldpath.so
 *    from being injected into glibc-linked child processes like git)
 *
 * LD_LIBRARY_PATH is intentionally preserved: it points to the bundled musl
 * libs (libstdc++, libgcc_s) which are harmless to glibc child processes
 * (different sonames/ABI). Keeping it set allows process.execPath
 * re-invocations (plugin installation) to find their libs without needing
 * RPATH or wrapper scripts.
 */

#include <stdlib.h>

__attribute__((constructor))
static void clear_ld_preload(void) {
    unsetenv("LD_PRELOAD");
}
