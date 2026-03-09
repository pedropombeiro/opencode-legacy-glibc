/*
 * LD_PRELOAD library that removes itself from the environment.
 *
 * Compiled with -nostdlib to produce a self-contained .so with NO dynamic
 * dependencies. This is critical because Bun caches process.env at startup
 * and passes it (including LD_PRELOAD) to child processes via execve. If
 * this .so had a musl dependency, glibc-linked children (git, node, MCP
 * servers) would fail trying to load libc.musl-x86_64.so.1.
 *
 * With -nostdlib, the .so is harmless when loaded by any libc (musl or
 * glibc). Its only job is to remove LD_PRELOAD from the environment so
 * that the .so is not propagated to further descendants.
 *
 * LD_LIBRARY_PATH is intentionally NOT cleared. It points to bundled musl
 * libs (libstdc++, libgcc_s, ld-musl) which are harmless to glibc children
 * (different sonames). Keeping it set allows process.execPath re-invocations
 * (plugin installation with BUN_BE_BUN=1) to find their libs.
 */

extern char **environ;

static int str_len(const char *s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

static int prefix_match(const char *entry, const char *name, int name_len) {
    int i;
    for (i = 0; i < name_len; i++) {
        if (entry[i] != name[i]) return 0;
    }
    return entry[name_len] == '=';
}

static void env_unset(const char *name) {
    int name_len = str_len(name);
    int i, j;
    if (!environ) return;
    for (i = 0, j = 0; environ[i]; i++) {
        if (!prefix_match(environ[i], name, name_len))
            environ[j++] = environ[i];
    }
    environ[j] = 0;
}

__attribute__((constructor))
static void clean_env(void) {
    env_unset("LD_PRELOAD");
}
