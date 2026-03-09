# Troubleshooting & Technical Notes

## Architecture Overview

The legacy-glibc build repackages the upstream OpenCode binary (a Bun/TypeScript app) to run on
systems with old GLIBC (e.g., QNAP NAS with GLIBC 2.21). It replaces the GLIBC dependency with
bundled **musl libc** libraries.

### Wrapper chain

```
bin/opencode            (outer wrapper — creates musl loader symlink + .path file)
  └─ bin/opencode.bin   (inner wrapper — sets LD_PRELOAD=clear_ldpath.so, exec's real binary)
       └─ lib/opencode  (patched ELF binary using musl dynamic linker)
```

When opencode re-invokes itself via `process.execPath` (plugin install):

```
lib/opencode            (called directly — musl linker finds libs via .path file)
```

No wrapper or `LD_LIBRARY_PATH` needed for re-invocation. The musl linker reads
`/tmp/etc/ld-musl-x86_64.path` to find bundled libs.

### Key files

| File | Purpose |
|------|---------|
| `bin/opencode` | Outer shell wrapper — creates musl loader symlink + `.path` file |
| `bin/opencode.bin` | Inner shell wrapper — sets `LD_PRELOAD`, exec's real binary |
| `lib/opencode` | Patched OpenCode ELF binary (~152MB, musl dynamic linker) |
| `lib/ld-musl-x86_64.so.1` | musl dynamic linker (from Alpine) |
| `lib/libstdc++.so.6` | C++ standard library (from Alpine, musl-compiled) |
| `lib/libgcc_s.so.1` | GCC support library (from Alpine, musl-compiled) |
| `lib/clear_ldpath.so` | Self-contained LD_PRELOAD lib (~14KB, no deps) |

### Runtime files (created by bin/opencode at startup)

| File | Purpose |
|------|---------|
| `/tmp/.opencode-ld/ld-musl-x86_64.so.1` | Symlink to `lib/ld-musl-x86_64.so.1` (ELF interpreter target) |
| `/tmp/etc/ld-musl-x86_64.path` | Contains `lib/` absolute path (musl library search path) |

## How musl Finds Libraries (the .path file)

The musl dynamic linker resolves its `.path` file relative to its **grandparent directory**
(second-to-last `/` in its own path). Since the ELF interpreter is patched to
`/tmp/.opencode-ld/ld-musl-x86_64.so.1`, the grandparent is `/tmp`, so the linker reads
`/tmp/etc/ld-musl-x86_64.path`.

This is a **musl-specific mechanism invisible to glibc**. Glibc children never read this file
and are completely unaffected. This eliminates the `LD_LIBRARY_PATH` catch-22 entirely.

**Important**: the `.path` file location depends on the **symlink path**, not the resolved
target. musl uses `ldso.name` (from the kernel's auxiliary vector), which retains the
PT_INTERP path.

## Plugin Installation Mechanism

OpenCode installs plugins (npm packages) by re-invoking itself with `BUN_BE_BUN=1`:

```
process.execPath add --force --exact --cwd ~/.cache/opencode <pkg>@<version>
```

- `process.execPath` resolves via `/proc/self/exe` to `lib/opencode` — the **real binary**.
  Bun uses `/proc/self/exe` on Linux; there is no env var to override it.
- The re-invoked binary finds its musl libs via the `.path` file — no `LD_LIBRARY_PATH` needed.
- `BUN_BE_BUN=1` tells the compiled Bun binary to act as the `bun` CLI instead of running the app.
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=true` skips built-in npm plugins.

## Environment Sanitization (clear_ldpath.so)

`clear_ldpath.so` is compiled with `-nostdlib` to produce a **self-contained shared library with
zero dynamic dependencies**. Its only job is to clear `LD_PRELOAD` from the environment so the
`.so` doesn't propagate to child processes.

`LD_LIBRARY_PATH` is **never set** — the musl linker uses the `.path` file instead.

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
4. **v1.2.22 LD_LIBRARY_PATH only:** Only cleared `LD_PRELOAD`. `LD_LIBRARY_PATH` preserved
   always. Plugin install and glibc children worked in Docker, but `LD_LIBRARY_PATH` with
   musl-compiled libs broke glibc children on the actual QNAP NAS (ABI mismatch on same sonames).
5. **v1.2.22 ELF wrapper:** Static ELF wrapper at `lib/opencode` re-established env before
   exec'ing the real binary. But `process.execPath` still resolved via `/proc/self/exe` to the
   real binary (not the wrapper), so plugin install bypassed the wrapper and failed.
6. **Current (musl .path file):** `LD_LIBRARY_PATH` eliminated entirely. The musl linker reads
   `/tmp/etc/ld-musl-x86_64.path` to find bundled libs. `clear_ldpath.so` only clears
   `LD_PRELOAD`. Plugin install works because `process.execPath` → `lib/opencode` finds its
   libs via the `.path` file without any env vars. 12/12 tests pass on all Docker distros.
   **Verified on QNAP NAS (GLIBC 2.21):** all 5 plugins install successfully, node/git/MCP
   servers work, no `LD_LIBRARY_PATH` or `LD_PRELOAD` leaks to child processes.

## Known Issues & Gotchas

### 1. patchelf --set-rpath causes segfaults on Bun binaries

Do NOT use `--set-rpath` with Bun binaries (~152MB). It corrupts them.

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
`/tmp/.opencode-ld/ld-musl-x86_64.so.1` and the `.path` file at
`/tmp/etc/ld-musl-x86_64.path`. These are needed because:

- The binary's ELF interpreter is hardcoded to `/tmp/.opencode-ld/ld-musl-x86_64.so.1` via
  `patchelf --set-interpreter`
- The musl linker reads `.path` relative to its grandparent dir (the symlink path, not resolved)

The inner wrapper (`bin/opencode.bin`) sets `LD_PRELOAD=clear_ldpath.so` before exec'ing the
real binary, so the `.so` constructor can remove `LD_PRELOAD` from the environment.

### 5. process.execPath resolves via /proc/self/exe

Bun reads `/proc/self/exe` to determine `process.execPath`. This always resolves to the final
exec'd binary, ignoring shell wrappers and argv[0]. There is no env var override. This is why
the `.path` file approach is necessary — it allows the raw binary to find its libs without any
env vars.

### 6. musl .path file location depends on the linker's symlink path

The musl linker computes the `.path` file location from its own name (the PT_INTERP path from
the binary, before resolving symlinks). It extracts the grandparent directory:

```
/tmp/.opencode-ld/ld-musl-x86_64.so.1
     ^^^^^^^^^^^^                          → last component
/tmp/                                      → grandparent
/tmp/etc/ld-musl-x86_64.path              → path file location
```

If you change the `patchelf --set-interpreter` path, the `.path` file location changes too.

## Testing

### Build the artifact

```bash
docker buildx build --platform linux/amd64 --build-arg VERSION=v1.2.22 \
  -f build/legacy-glibc/Dockerfile -o out build/legacy-glibc/
```

### Run the automated test suite

The test script (`build/test/test-env.sh`) runs 12 deterministic tests covering wrapper chain,
direct binary launch, plugin install, process.execPath re-invocation, LD_PRELOAD safety, and
git compatibility. No API key required.

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
