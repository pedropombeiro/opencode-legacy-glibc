# Build on linux/amd64 to ensure correct baseline binary
ARG BUILD_PLATFORM=linux/amd64

# ---------------------------------------------------------------------------
# Stage 1: fetch the upstream OpenCode v2 musl baseline binary from npm.
#
# Upstream v2 publishes @opencode/cli-linux-x64-baseline-musl, which embeds
# musl builds of every native dependency (@opentui/core, @parcel/watcher,
# fff) and a static-pie opencode-pty. We only need to redirect its ELF
# interpreter to the bundled musl loader so it runs without a system musl.
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM debian:bookworm-slim AS fetch

ARG VERSION
ARG NPM_PACKAGE=@opencode/cli-linux-x64-baseline-musl

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq patchelf binutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download the tarball and verify it against the npm registry's sha512 integrity.
RUN set -eu \
    && NPM_VERSION="${VERSION#v}" \
    && META=$(curl -fsSL "https://registry.npmjs.org/${NPM_PACKAGE}/${NPM_VERSION}") \
    && TARBALL=$(printf '%s' "$META" | jq -er '.dist.tarball') \
    && INTEGRITY=$(printf '%s' "$META" | jq -er '.dist.integrity') \
    && case "$INTEGRITY" in sha512-*) ;; *) echo "Unexpected integrity format: $INTEGRITY"; exit 1 ;; esac \
    && EXPECTED=$(printf '%s' "${INTEGRITY#sha512-}" | base64 -d | od -An -vtx1 | tr -d ' \n') \
    && echo "Downloading ${NPM_PACKAGE}@${NPM_VERSION} from ${TARBALL}" \
    && curl -fsSL -o pkg.tgz "$TARBALL" \
    && ACTUAL=$(sha512sum pkg.tgz | cut -d' ' -f1) \
    && if [ "$ACTUAL" != "$EXPECTED" ]; then \
        echo "ERROR: sha512 mismatch for ${TARBALL}"; \
        echo "  expected: $EXPECTED"; \
        echo "  actual:   $ACTUAL"; \
        exit 1; \
    fi \
    && tar -xzf pkg.tgz \
    && test -x package/bin/opencode \
    && rm pkg.tgz

# Patch the binary to use a custom interpreter path that we'll symlink at runtime.
# Do NOT use --set-rpath: it corrupts Bun-compiled binaries.
RUN patchelf --set-interpreter /tmp/.opencode-ld/ld-musl-x86_64.so.1 package/bin/opencode

# Verify the binary no longer references glibc and only needs bundled libs.
RUN set -eu \
    && BIN=package/bin/opencode \
    && echo "=== Interpreter: $(patchelf --print-interpreter "$BIN")" \
    && NEEDED=$(patchelf --print-needed "$BIN") \
    && echo "=== NEEDED:" && echo "$NEEDED" \
    && if readelf -V "$BIN" 2>/dev/null | grep -qE 'GLIBC_[0-9]'; then \
        echo "ERROR: $BIN references GLIBC symbol versions"; \
        exit 1; \
    fi \
    && for lib in $NEEDED; do \
        case "$lib" in \
            libc.musl-x86_64.so.1|libstdc++.so.6|libgcc_s.so.1) ;; \
            *) echo "ERROR: unexpected NEEDED library: $lib"; exit 1 ;; \
        esac; \
    done \
    && echo "OK: $BIN only depends on bundled musl libraries"

# ---------------------------------------------------------------------------
# Stage 2: get musl and libs from Alpine (x86_64 for QNAP target)
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM alpine:latest AS musl
RUN apk add --no-cache musl libstdc++ libgcc

# ---------------------------------------------------------------------------
# Stage 3: package wrapper scripts
# ---------------------------------------------------------------------------
FROM alpine:latest AS wrapper
COPY opencode /opencode/bin/opencode
COPY opencode.bin /opencode/bin/opencode.bin
RUN chmod +x /opencode/bin/opencode /opencode/bin/opencode.bin

# Build clear_ldpath.so: self-contained shared library with no dynamic deps.
# Uses -nostdlib so glibc children can load it harmlessly when LD_PRELOAD leaks.
FROM --platform=$BUILD_PLATFORM alpine:latest AS ldpreload
RUN apk add --no-cache gcc musl-dev
COPY clear_ldpath.c /tmp/
RUN mkdir -p /opencode/lib && gcc -shared -fPIC -nostdlib \
    -o /opencode/lib/clear_ldpath.so /tmp/clear_ldpath.c

FROM scratch AS export
COPY --from=fetch /build/package/bin/opencode /opencode/lib/opencode
COPY --from=musl /lib/ld-musl-x86_64.so.1 /opencode/lib/
COPY --from=musl /usr/lib/libstdc++.so.6 /opencode/lib/
COPY --from=musl /usr/lib/libgcc_s.so.1 /opencode/lib/
COPY --from=ldpreload /opencode/lib/clear_ldpath.so /opencode/lib/
COPY --from=wrapper /opencode/bin/opencode /opencode/bin/opencode
COPY --from=wrapper /opencode/bin/opencode.bin /opencode/bin/opencode.bin
