/*
 * LD_PRELOAD library to sanitize the environment for child processes.
 *
 * This runs as a constructor before main(), ensuring that:
 * 1. LD_PRELOAD is cleared (prevents clear_ldpath.so from being injected
 *    into glibc-linked child processes like node, git, MCP servers)
 * 2. LD_LIBRARY_PATH is stashed into _OPENCODE_LIB_PATH and cleared
 *    (prevents glibc child processes from finding musl's libc.musl-x86_64.so.1)
 *
 * The stashed _OPENCODE_LIB_PATH is used by opencode.bin to restore
 * LD_LIBRARY_PATH when re-entering the wrapper chain. It is also checked
 * here: if BUN_BE_BUN=1 is set (plugin installation re-invocation via
 * process.execPath), LD_LIBRARY_PATH is restored so the musl binary can
 * find its bundled libstdc++ and libgcc_s.
 */

#include <stdlib.h>
#include <string.h>

__attribute__((constructor))
static void clean_env(void) {
    const char *lib_path = getenv("LD_LIBRARY_PATH");

    if (lib_path && lib_path[0] != '\0')
        setenv("_OPENCODE_LIB_PATH", lib_path, 1);

    unsetenv("LD_PRELOAD");

    const char *bun_be_bun = getenv("BUN_BE_BUN");
    if (bun_be_bun && strcmp(bun_be_bun, "1") == 0) {
        /* Plugin install: keep LD_LIBRARY_PATH so the re-invoked musl
           binary can find libstdc++ and libgcc_s. */
        return;
    }

    unsetenv("LD_LIBRARY_PATH");
}
