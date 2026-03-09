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
| `clear_ldpath.so` | Self-contained LD_PRELOAD lib that clears LD_PRELOAD from env |

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
zero dynamic dependencies**. Its only job is to **clear `LD_PRELOAD`** from the environ so the
`.so` doesn't propagate to further descendants.

### Why only LD_PRELOAD is cleared

- **`LD_PRELOAD` must be cleared:** Bun caches `process.env` at startup and passes it to child
  processes. If `clear_ldpath.so` (a musl-compiled `.so`) leaked to glibc children, they'd crash.
  Since the `.so` is compiled with `-nostdlib` (no musl dependency), it's harmless if it does leak,
  but clearing `LD_PRELOAD` prevents unnecessary loading.
- **`LD_LIBRARY_PATH` must NOT be cleared:** It points to bundled musl libs (libstdc++, libgcc_s)
  which are harmless to glibc children (different sonames — glibc won't try to load them). Keeping
  it set is critical because `process.execPath` re-invocations (plugin install) bypass the wrapper
  and need `LD_LIBRARY_PATH` to find their libs.

### Why -nostdlib is required

Bun caches `process.env` at startup and uses that cache — not the C `environ` — when spawning
child processes via `execve`. This means `LD_PRELOAD` leaks to glibc children regardless of what
the constructor clears at the C level. If `clear_ldpath.so` had a musl dependency, glibc children
would crash trying to load `libc.musl-x86_64.so.1`. With `-nostdlib`, the `.so` has zero deps and
is loadable by any libc.

### Evolution of the approach

1. **v1.2.19:** Cleared both `LD_PRELOAD` and `LD_LIBRARY_PATH`. Plugins didn't exist yet.
2. **v1.2.22 initial:** Preserved `LD_LIBRARY_PATH`. Compiled with musl libc. Glibc children
   crashed because `LD_PRELOAD` leaked the musl `.so`.
3. **v1.2.22 nostdlib:** Compiled with `-nostdlib`, cleared both vars conditionally on `BUN_BE_BUN`.
   Glibc children worked, but plugin install failed (exit 127) because Bun's `process.env` cache
   already lost `LD_LIBRARY_PATH` before the child spawn.
4. **Current:** Only clears `LD_PRELOAD`. `LD_LIBRARY_PATH` is preserved always. Both plugin
   install and glibc children work correctly.

## Known Issues & Gotchas

### 1. patchelf --set-rpath causes segfaults on Bun binaries

Do NOT use `--set-rpath` with Bun binaries. The `LD_LIBRARY_PATH` approach works.

### 2. Docker testing requires `--platform linux/amd64`

The build targets x86_64 (QNAP NAS). On Apple Silicon (arm64) hosts, Docker containers must use
`--platform linux/amd64`, otherwise OrbStack shows misleading architecture mismatch errors.

### 3. Archived Debian/CentOS repos

- **Debian Stretch** (GLIBC 2.24): repos moved to `archive.debian.org`, `stretch-updates` removed
- **Debian Buster** (GLIBC 2.28): repos moved to `archive.debian.org`, `buster-updates` removed
- **CentOS 7** (GLIBC 2.17): repos moved to `vault.centos.org`

All test Dockerfiles include the necessary repo fixes.

### 4. The two-wrapper design exists for a reason

The outer wrapper (`bin/opencode`) creates the musl loader symlink at
`/tmp/.opencode-ld/ld-musl-x86_64.so.1`. This is needed because the binary's ELF interpreter is
hardcoded to that path via `patchelf --set-interpreter`.

The inner wrapper (`bin/opencode.bin`) sets `LD_LIBRARY_PATH` and `LD_PRELOAD` before exec'ing
the real binary. Plugin install bypasses both wrappers (via `process.execPath`), but works because
`LD_LIBRARY_PATH` is inherited from the parent process.

## Testing

### Build the artifact

```bash
docker buildx build --build-arg VERSION=v1.2.22 --output type=local,dest=./out build/legacy-glibc
```

### Run the automated test suite

The test script (`build/test/test-env.sh`) runs 11 deterministic tests covering wrapper chain,
plugin install, process.execPath re-invocation, LD_PRELOAD safety, and git compatibility.
No API key required.

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
