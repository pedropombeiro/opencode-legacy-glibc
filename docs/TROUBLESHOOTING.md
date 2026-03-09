# Troubleshooting & Technical Notes

## Architecture Overview

The legacy-glibc build repackages the upstream OpenCode binary (a Bun/TypeScript app) to run on
systems with old GLIBC (e.g., QNAP NAS with GLIBC 2.21). It replaces the GLIBC dependency with
bundled **musl libc** libraries.

### Wrapper chain

```
bin/opencode            (outer wrapper — creates musl loader symlink, delegates to opencode.bin)
  └─ bin/opencode.bin   (inner wrapper — sets LD_LIBRARY_PATH + LD_PRELOAD, exec's real binary)
       └─ lib/opencode.bin  (patched ELF binary using musl dynamic linker)
```

When opencode re-invokes itself via `process.execPath` (plugin install):

```
lib/opencode            (static ELF wrapper — re-establishes LD_LIBRARY_PATH + LD_PRELOAD)
  └─ lib/opencode.bin   (patched ELF binary)
```

`lib/opencode.elf` is a symlink to `lib/opencode` so that `process.execPath` resolves to the
ELF wrapper rather than the raw binary.

### Key files in `lib/`

| File | Purpose |
|------|---------|
| `opencode` | Static ELF wrapper (~245KB, musl) — sets env and exec's `opencode.bin` |
| `opencode.elf` | Symlink to `opencode` — target for `process.execPath` resolution |
| `opencode.bin` | Patched OpenCode ELF binary (~152MB, musl dynamic linker) |
| `ld-musl-x86_64.so.1` | musl dynamic linker (from Alpine) |
| `libstdc++.so.6` | C++ standard library (from Alpine, musl-compiled) |
| `libgcc_s.so.1` | GCC support library (from Alpine, musl-compiled) |
| `clear_ldpath.so` | Self-contained LD_PRELOAD lib (~14KB, no deps) |

## Plugin Installation Mechanism

OpenCode installs plugins (npm packages) by re-invoking itself with `BUN_BE_BUN=1`:

```
process.execPath add --force --exact --cwd ~/.cache/opencode <pkg>@<version>
```

- `process.execPath` resolves to `lib/opencode` (the **ELF wrapper**), thanks to the
  `opencode.elf` symlink. This ensures re-invocations go through the wrapper which
  re-establishes `LD_LIBRARY_PATH` and `LD_PRELOAD`.
- `BUN_BE_BUN=1` tells the compiled Bun binary to act as the `bun` CLI instead of running the app.
- There is no config to point to a custom bun binary; `process.execPath` is hardcoded.
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=true` skips built-in npm plugins (currently just
  `opencode-anthropic-auth`).

## Environment Sanitization (clear_ldpath.so)

`clear_ldpath.so` is compiled with `-nostdlib` to produce a **self-contained shared library with
zero dynamic dependencies**. It clears `LD_PRELOAD` (always) and `LD_LIBRARY_PATH` (conditionally)
from the C `environ` before `main()` runs.

### What gets cleared and when

| Variable | Normal path (no BUN_BE_BUN) | Plugin install (BUN_BE_BUN=1) |
|----------|----------------------------|-------------------------------|
| `LD_PRELOAD` | Cleared | Cleared |
| `LD_LIBRARY_PATH` | Cleared | **Preserved** |

- **Normal path:** Both are cleared. Glibc children (git, MCP servers, node) get a clean
  environment with no musl lib paths.
- **Plugin install path:** `LD_LIBRARY_PATH` is preserved so the re-invoked bun binary can find
  its musl libs. `LD_PRELOAD` is still cleared (the ELF wrapper re-establishes it before exec).

### Why -nostdlib is required

Bun caches `process.env` at startup and uses that cache — not the C `environ` — when spawning
child processes via `execve`. This means `LD_PRELOAD` leaks to glibc children regardless of what
the constructor clears at the C level. If `clear_ldpath.so` had a musl dependency, glibc children
would crash trying to load `libc.musl-x86_64.so.1`. With `-nostdlib`, the `.so` has zero deps and
is loadable by any libc.

### Why the ELF wrapper exists

`process.execPath` resolves to the real ELF binary, not shell wrappers. Without the ELF wrapper,
plugin install would call the raw binary directly, with no `LD_LIBRARY_PATH` or `LD_PRELOAD` set.
The static musl ELF wrapper at `lib/opencode` solves this by:

1. Resolving its own directory via `/proc/self/exe`
2. Setting `LD_LIBRARY_PATH` to that directory
3. Setting `LD_PRELOAD` to `clear_ldpath.so`
4. Exec'ing the real binary at `lib/opencode.bin`

### Evolution of the approach

1. **v1.2.19:** Cleared both `LD_PRELOAD` and `LD_LIBRARY_PATH`. Plugins didn't exist yet.
2. **v1.2.22 initial:** Preserved `LD_LIBRARY_PATH`. Compiled with musl libc. Glibc children
   crashed because `LD_PRELOAD` leaked the musl `.so`.
3. **v1.2.22 nostdlib:** Compiled with `-nostdlib`, cleared both vars conditionally on `BUN_BE_BUN`.
   Glibc children worked, but plugin install failed (exit 127) because Bun's `process.env` cache
   already lost `LD_LIBRARY_PATH` before the child spawn.
4. **v1.2.22 LD_LIBRARY_PATH only:** Only cleared `LD_PRELOAD`. `LD_LIBRARY_PATH` preserved
   always. Plugin install and glibc children worked in Docker, but `LD_LIBRARY_PATH` with
   musl-compiled libs broke glibc children on the actual QNAP NAS (ABI mismatch on same sonames).
5. **Current (ELF wrapper):** Static ELF wrapper at `lib/opencode` re-establishes env before
   exec'ing the real binary. `clear_ldpath.so` clears both `LD_PRELOAD` and `LD_LIBRARY_PATH`
   in the normal path, preserves `LD_LIBRARY_PATH` only when `BUN_BE_BUN=1`. All 12 tests pass
   on Stretch, Buster, and CentOS 7.

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

### 4. The wrapper design exists for a reason

The outer wrapper (`bin/opencode`) creates the musl loader symlink at
`/tmp/.opencode-ld/ld-musl-x86_64.so.1`. This is needed because the binary's ELF interpreter is
hardcoded to that path via `patchelf --set-interpreter`.

The inner wrapper (`bin/opencode.bin`) sets `LD_LIBRARY_PATH` and `LD_PRELOAD` before exec'ing
the real binary. The ELF wrapper (`lib/opencode`) does the same job but as a static binary,
so it works when called via `process.execPath`.

### 5. LD_LIBRARY_PATH leaks to grandchildren in BUN_BE_BUN mode

When `BUN_BE_BUN=1`, `LD_LIBRARY_PATH` is preserved for the bun process but also leaks to its
grandchildren. This is an accepted tradeoff — plugin install is a brief operation and its
sub-processes are bun-internal (network, npm registry), not arbitrary glibc tools.

## Testing

### Build the artifact

```bash
docker buildx build --platform linux/amd64 --build-arg VERSION=v1.2.22 \
  -f build/legacy-glibc/Dockerfile -o out build/legacy-glibc/
```

### Run the automated test suite

The test script (`build/test/test-env.sh`) runs 12 deterministic tests covering wrapper chain,
ELF wrapper, plugin install, process.execPath re-invocation, LD_PRELOAD/LD_LIBRARY_PATH safety,
and git compatibility. No API key required.

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

Tested and passing (12/12 tests) as of v1.2.22:

| Image | GLIBC | Status |
|-------|-------|--------|
| centos:7 | 2.17 | 12/12 |
| debian:stretch-slim | 2.24 | 12/12 |
| debian:buster-slim | 2.28 | 12/12 |
