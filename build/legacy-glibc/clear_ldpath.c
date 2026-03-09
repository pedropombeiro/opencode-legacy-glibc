/*
 * LD_PRELOAD library that clears LD_PRELOAD and LD_LIBRARY_PATH.
 *
 * Compiled with -nostdlib to produce a self-contained .so with NO dynamic
 * dependencies. This is critical because Bun caches process.env at startup
 * and passes it to child processes. With -nostdlib, the .so is harmless
 * when loaded by any libc (musl or glibc).
 *
 * Clears both LD_PRELOAD and LD_LIBRARY_PATH to prevent glibc children
 * from loading musl libs. When BUN_BE_BUN=1 (plugin install re-invocation),
 * LD_LIBRARY_PATH is preserved so the musl binary can find its libs.
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

static int str_eq(const char *a, const char *b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return *a == *b;
}

__attribute__((constructor))
static void clean_env(void) {
    env_unset("LD_PRELOAD");

    const char *bun_be_bun = env_get("BUN_BE_BUN");
    if (bun_be_bun && str_eq(bun_be_bun, "1"))
        return;

    env_unset("LD_LIBRARY_PATH");
}
