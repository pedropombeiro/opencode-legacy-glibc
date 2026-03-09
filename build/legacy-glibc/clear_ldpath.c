/*
 * LD_PRELOAD library to sanitize the environment for child processes.
 *
 * Compiled with -nostdlib -static to produce a self-contained .so with NO
 * dynamic dependencies (no libc.musl, no libc.so). This is critical because
 * Bun caches process.env at startup and passes it (including LD_PRELOAD) to
 * child processes via execve. If this .so had a musl dependency, glibc-linked
 * children (git, node, MCP servers) would fail trying to load libc.musl.
 *
 * This runs as a constructor before main(), ensuring that:
 * 1. LD_PRELOAD is cleared (prevents clear_ldpath.so from being injected
 *    into glibc-linked child processes like node, git, MCP servers)
 * 2. LD_LIBRARY_PATH is stashed into _OPENCODE_LIB_PATH and cleared
 *    (prevents glibc child processes from finding musl's libc.musl-x86_64.so.1)
 *
 * The stashed _OPENCODE_LIB_PATH is used by opencode.bin to restore
 * LD_LIBRARY_PATH when re-entering the wrapper chain. If BUN_BE_BUN=1 is set
 * (plugin installation re-invocation via process.execPath), LD_LIBRARY_PATH
 * is preserved so the musl binary can find its bundled libstdc++ and libgcc_s.
 */

extern char **environ;

static int str_eq(const char *a, const char *b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return *a == *b;
}

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

static const char *env_get(const char *name) {
    int name_len = str_len(name);
    int i;
    if (!environ) return 0;
    for (i = 0; environ[i]; i++) {
        if (prefix_match(environ[i], name, name_len))
            return environ[i] + name_len + 1;
    }
    return 0;
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

static void env_set(const char *name, const char *value) {
    int name_len = str_len(name);
    int val_len = str_len(value);
    int total = name_len + 1 + val_len + 1;
    int i, count;

    /* Build "NAME=VALUE" string in a static buffer.
     * We only set _OPENCODE_LIB_PATH, so one buffer is enough. */
    static char buf[4096];
    if (total > (int)sizeof(buf)) return;
    for (i = 0; i < name_len; i++) buf[i] = name[i];
    buf[name_len] = '=';
    for (i = 0; i < val_len; i++) buf[name_len + 1 + i] = value[i];
    buf[total - 1] = '\0';

    if (!environ) return;

    /* Replace existing entry if found */
    for (i = 0; environ[i]; i++) {
        if (prefix_match(environ[i], name, name_len)) {
            environ[i] = buf;
            return;
        }
    }

    /* Append: overwrite the NULL terminator with our new entry.
     * This only works if there's space in the original environ array.
     * In practice, LD_PRELOAD was just removed so there's a free slot. */
    count = i;
    environ[count] = buf;
    environ[count + 1] = 0;
}

__attribute__((constructor))
static void clean_env(void) {
    const char *lib_path = env_get("LD_LIBRARY_PATH");

    if (lib_path && lib_path[0] != '\0')
        env_set("_OPENCODE_LIB_PATH", lib_path);

    env_unset("LD_PRELOAD");

    const char *bun_be_bun = env_get("BUN_BE_BUN");
    if (bun_be_bun && str_eq(bun_be_bun, "1")) {
        return;
    }

    env_unset("LD_LIBRARY_PATH");
}
