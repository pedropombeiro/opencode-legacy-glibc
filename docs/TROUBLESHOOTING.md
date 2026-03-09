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
| `clear_ldpath.so` | LD_PRELOAD lib that unsets `LD_PRELOAD` before `main()` |

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

## Known Issues & Gotchas

### 1. Plugin install fails silently when LD_LIBRARY_PATH is cleared

**Root cause:** The original `clear_ldpath.c` stripped both `LD_LIBRARY_PATH` and `LD_PRELOAD` via
a GCC constructor (runs before `main()`). When OpenCode re-invokes itself via `process.execPath`
for plugin installation, the child process is the raw ELF binary (`lib/opencode`) — not
`opencode.bin`. Without `LD_LIBRARY_PATH`, the musl linker can't find `libstdc++.so.6` and
`libgcc_s.so.1`, and the child process fails with:

```
Error loading shared library libstdc++.so.6: No such file or directory
Error loading shared library libgcc_s.so.1: No such file or directory
```

**Fix:** Only clear `LD_PRELOAD` in `clear_ldpath.c`, preserve `LD_LIBRARY_PATH`. The musl lib
paths in `LD_LIBRARY_PATH` are harmless to glibc child processes (like `git`) because glibc's
linker uses different sonames and won't pick up musl-specific libs. This was confirmed via Docker
testing: `LD_LIBRARY_PATH=/opt/opencode/lib git --version` works correctly.

With `LD_LIBRARY_PATH` preserved:
1. `opencode.bin` sets `LD_LIBRARY_PATH` and `LD_PRELOAD`
2. `clear_ldpath.c` clears only `LD_PRELOAD` (so `clear_ldpath.so` isn't injected into children)
3. `LD_LIBRARY_PATH` is inherited by child processes
4. `process.execPath` re-invocations find `libstdc++.so.6` and `libgcc_s.so.1` via the
   inherited `LD_LIBRARY_PATH`

### 2. patchelf --set-rpath causes segfaults on Bun binaries

**Observed:** Using `patchelf --set-rpath '$ORIGIN'` on the ~152MB Bun binary (either combined
with `--set-interpreter` or as a separate invocation) produces a binary that segfaults immediately
on startup. `patchelf --print-rpath` confirms the RPATH was set correctly, but the binary is
corrupted.

**Conclusion:** Do NOT use `--set-rpath` with Bun binaries. The `LD_LIBRARY_PATH` preservation
approach is simpler and works correctly.

### 3. Docker testing requires `--platform linux/amd64`

The build targets x86_64 (QNAP NAS). On Apple Silicon (arm64) hosts, Docker containers must use
`--platform linux/amd64` for the test container, otherwise:
- OrbStack shows misleading "Dynamic loader not found" errors that look like musl issues
  but are actually architecture mismatch errors
- The x86_64 musl binary won't run under arm64 emulation without proper multiarch setup

### 4. debian:stretch repos are archived

Debian Stretch (GLIBC 2.24, good test proxy for QNAP's 2.21) repos have moved to
`archive.debian.org`. The test Dockerfile must:
- Replace `deb.debian.org` with `archive.debian.org`
- Remove `stretch-updates` entries (404s even on archive)
- Set `Acquire::Check-Valid-Until "false"`

### 5. The two-wrapper design exists for a reason

The outer wrapper (`bin/opencode`) creates the musl loader symlink at
`/tmp/.opencode-ld/ld-musl-x86_64.so.1`. This is needed because the binary's ELF interpreter is
hardcoded to that path via `patchelf --set-interpreter`. The symlink must point to the actual
`ld-musl-x86_64.so.1` in `lib/`.

The inner wrapper (`bin/opencode.bin`) exists because OpenCode uses `process.execPath` for
self-re-execution during plugin installation. Since `process.execPath` resolves to the raw binary
(`lib/opencode`), not the wrappers, the env vars set by `opencode.bin` must be inherited rather
than re-set by a wrapper.

### 6. clear_ldpath.so must still clear LD_PRELOAD

Even though `LD_LIBRARY_PATH` is now preserved, `LD_PRELOAD` must still be cleared. If
`clear_ldpath.so` (a musl-compiled shared library) were inherited by glibc-linked child processes,
the glibc dynamic linker would attempt to load it, potentially causing ABI incompatibilities or
crashes. By clearing `LD_PRELOAD` in the constructor, the library removes itself from the
environment before any child process is spawned.

## Testing in Docker

### Build the artifact

```bash
docker buildx build --build-arg VERSION=v1.2.22 --output type=local,dest=./out build/legacy-glibc
```

### Build and run the test container

```bash
docker build --platform linux/amd64 -t opencode-legacy-test -f build/test/Dockerfile .
docker run --platform linux/amd64 --rm opencode-legacy-test sh -c '
  /opt/opencode/bin/opencode --version
'
```

### Simulate plugin install (the critical test)

The key test is that `LD_LIBRARY_PATH` survives through the wrapper chain into child processes:

```bash
docker run --platform linux/amd64 --rm opencode-legacy-test sh -c '
  # Set up the full environment as the wrappers do
  mkdir -p /tmp/.opencode-ld
  ln -sf /opt/opencode/lib/ld-musl-x86_64.so.1 /tmp/.opencode-ld/ld-musl-x86_64.so.1

  # Simulate process.execPath plugin install (with inherited LD_LIBRARY_PATH)
  LD_LIBRARY_PATH=/opt/opencode/lib LD_PRELOAD=/opt/opencode/lib/clear_ldpath.so \
    BUN_BE_BUN=1 /opt/opencode/lib/opencode --version

  # Full plugin install test
  mkdir -p /tmp/testpkg && echo "{}" > /tmp/testpkg/package.json
  LD_LIBRARY_PATH=/opt/opencode/lib LD_PRELOAD=/opt/opencode/lib/clear_ldpath.so \
    BUN_BE_BUN=1 /opt/opencode/lib/opencode add --cwd /tmp/testpkg opencode-anthropic-auth@0.0.13
  ls /tmp/testpkg/node_modules/
'
```

### Verify child processes work

```bash
docker run --platform linux/amd64 --rm opencode-legacy-test sh -c '
  /opt/opencode/bin/opencode --version > /dev/null 2>&1
  git --version  # Should use system git, not musl-linked
'
```
