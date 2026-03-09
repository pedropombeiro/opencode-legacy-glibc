# Troubleshooting & Technical Notes

## Architecture Overview

The legacy-glibc build repackages the upstream OpenCode binary (a Bun/TypeScript app) to run on
systems with old GLIBC (e.g., QNAP NAS with GLIBC 2.21). It replaces the GLIBC dependency with
bundled **musl libc** libraries.

### Wrapper chain

```
bin/opencode          (outer wrapper — creates musl loader symlink, delegates to opencode.bin)
  └─ bin/opencode.bin (inner wrapper — sets LD_LIBRARY_PATH + LD_PRELOAD, exec's the real binary)
       └─ lib/opencode (patched ELF binary using musl dynamic linker)
```

### Key files in `lib/`

| File | Purpose |
|------|---------|
| `opencode` | Patched OpenCode ELF binary |
| `ld-musl-x86_64.so.1` | musl dynamic linker (from Alpine) |
| `libstdc++.so.6` | C++ standard library (from Alpine) |
| `libgcc_s.so.1` | GCC support library (from Alpine) |
| `clear_ldpath.so` | Self-contained LD_PRELOAD lib that sanitizes env before `main()` |

## Plugin Installation Mechanism

OpenCode installs plugins (npm packages) by re-invoking itself with `BUN_BE_BUN=1`:

```
process.execPath add --force --exact --cwd ~/.cache/opencode <pkg>@<version>
```

- `process.execPath` resolves to the **real ELF binary** (`lib/opencode`), **not** the shell
  wrappers. This is a critical detail — the binary is called directly, bypassing both wrappers.
- `BUN_BE_BUN=1` tells the compiled Bun binary to act as the `bun` CLI instead of running the app.
- There is no config to point to a custom bun binary; `process.execPath` is hardcoded.
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=true` skips built-in npm plugins (currently just
  `opencode-anthropic-auth`).

## Environment Sanitization (clear_ldpath.so)

`clear_ldpath.so` is compiled with `-nostdlib` to produce a **self-contained shared library with
zero dynamic dependencies**. This is critical because Bun leaks `LD_PRELOAD` to child processes
(see below), and if the `.so` depended on musl libc, glibc children would crash trying to load it.

The library manipulates the `environ` pointer directly (no libc calls) via a GCC constructor that
runs before `main()`:

1. **Stashes `LD_LIBRARY_PATH`** into `_OPENCODE_LIB_PATH` (so `opencode.bin` can restore it when
   re-entering the wrapper chain)
2. **Always clears `LD_PRELOAD`** from the C environ
3. **Conditionally clears `LD_LIBRARY_PATH`**:
   - If `BUN_BE_BUN=1`: preserves `LD_LIBRARY_PATH` (plugin install needs musl libs)
   - Otherwise: clears `LD_LIBRARY_PATH` (prevents glibc children from finding musl libs)

### Why conditional clearing matters

- **Without clearing:** glibc-linked child processes (node, git, MCP servers) find musl's
  `libc.musl-x86_64.so.1` in `LD_LIBRARY_PATH` and fail
- **With unconditional clearing (v1.2.19 approach):** Plugin install fails because the re-invoked
  musl binary can't find `libstdc++.so.6` and `libgcc_s.so.1`
- **With conditional clearing (current approach):** Both paths work correctly

### Bun's process.env caching (critical gotcha)

**Bun caches `process.env` at startup and uses that cache — not the C `environ` — when spawning
child processes via `execve`.** This means:

- `clear_ldpath.so`'s constructor successfully modifies the C-level `environ`, but Bun's child
  spawning ignores those changes
- `LD_PRELOAD` and `LD_LIBRARY_PATH` **leak to child processes** despite being cleared in C
- This is why `clear_ldpath.so` MUST be compiled with `-nostdlib`: since it leaks to glibc
  children via `LD_PRELOAD`, it must be loadable by glibc's dynamic linker without any musl deps
- When loaded by glibc children, the constructor runs and cleans the environ for their descendants

**Prior approach (broken):** Compiled with musl libc as a dependency. Constructor cleared env at
C level, but Bun re-injected the values. Glibc children crashed trying to load `libc.musl-x86_64.so.1`
(a dependency of the `.so` itself).

## Known Issues & Gotchas

### 1. patchelf --set-rpath causes segfaults on Bun binaries

**Observed:** Using `patchelf --set-rpath '$ORIGIN'` on the ~152MB Bun binary (either combined
with `--set-interpreter` or as a separate invocation) produces a binary that segfaults immediately
on startup.

**Conclusion:** Do NOT use `--set-rpath` with Bun binaries. The `LD_LIBRARY_PATH` approach works.

### 2. Docker testing requires `--platform linux/amd64`

The build targets x86_64 (QNAP NAS). On Apple Silicon (arm64) hosts, Docker containers must use
`--platform linux/amd64` for the test container, otherwise:
- OrbStack shows misleading "Dynamic loader not found" errors that look like musl issues
  but are actually architecture mismatch errors
- The x86_64 musl binary won't run under arm64 emulation without proper multiarch setup

### 3. Archived Debian/CentOS repos

- **Debian Stretch** (GLIBC 2.24): repos moved to `archive.debian.org`, `stretch-updates` removed
- **Debian Buster** (GLIBC 2.28): repos moved to `archive.debian.org`, `buster-updates` removed
- **CentOS 7** (GLIBC 2.17): repos moved to `vault.centos.org`

All test Dockerfiles include the necessary repo fixes.

### 4. The two-wrapper design exists for a reason

The outer wrapper (`bin/opencode`) creates the musl loader symlink at
`/tmp/.opencode-ld/ld-musl-x86_64.so.1`. This is needed because the binary's ELF interpreter is
hardcoded to that path via `patchelf --set-interpreter`. The symlink must point to the actual
`ld-musl-x86_64.so.1` in `lib/`.

The inner wrapper (`bin/opencode.bin`) exists because OpenCode uses `process.execPath` for
self-re-execution during plugin installation. Since `process.execPath` resolves to the raw binary
(`lib/opencode`), not the wrappers, the env vars set by `opencode.bin` must be inherited rather
than re-set by a wrapper. `opencode.bin` also restores `LD_LIBRARY_PATH` from `_OPENCODE_LIB_PATH`
if available (set by `clear_ldpath.so`), falling back to `$SCRIPT_DIR/lib`.

## Testing

### Build the artifact

```bash
docker buildx build --build-arg VERSION=v1.2.22 --output type=local,dest=./out build/legacy-glibc
```

### Run the automated test suite

The test script (`build/test/test-env.sh`) runs 11 deterministic tests covering wrapper chain,
plugin install, env sanitization, LD_PRELOAD safety, and git compatibility. No API key required.

```bash
# Build and test on a specific distro
docker build --platform linux/amd64 -t opencode-test -f build/test/Dockerfile .
docker run --platform linux/amd64 --rm opencode-test sh /opt/test-env.sh

# Test on other distros
docker build --platform linux/amd64 -t opencode-test-buster -f build/test/Dockerfile.buster .
docker run --platform linux/amd64 --rm opencode-test-buster sh /opt/test-env.sh

docker build --platform linux/amd64 -t opencode-test-centos7 -f build/test/Dockerfile.centos7 .
docker run --platform linux/amd64 --rm opencode-test-centos7 sh /opt/test-env.sh
```

### GLIBC compatibility matrix

Tested and passing (11/11 tests) as of v1.2.22:

| Image | GLIBC | Status |
|-------|-------|--------|
| centos:7 | 2.17 | 11/11 |
| debian:stretch-slim | 2.24 | 11/11 |
| debian:buster-slim | 2.28 | 11/11 |
