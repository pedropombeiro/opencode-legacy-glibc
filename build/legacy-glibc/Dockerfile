# Build on linux/amd64 to ensure correct baseline binary
ARG BUILD_PLATFORM=linux/amd64

# ---------------------------------------------------------------------------
# Stage 1: clone opencode, discover the @opentui/core version it depends on.
# This stage exists only to extract metadata; the version is written to
# /opt/opentui-version so later stages can read it via COPY --from.
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM oven/bun:debian AS opencode-clone

ARG VERSION

RUN apt-get update && apt-get install -y --no-install-recommends git jq ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch "${VERSION}" https://github.com/anomalyco/opencode.git .

RUN mkdir -p /opt \
    && set -eux \
    # opencode's packages/opencode/package.json may use "catalog:" for the
    # @opentui/core dependency (bun workspaces catalog). Resolve the concrete
    # version from the root workspaces.catalog. Fall back to the package
    # dependency if the value is a real version string.
    && PKG_VERSION=$(jq -r '.dependencies["@opentui/core"] // ""' packages/opencode/package.json) \
    && case "$PKG_VERSION" in \
        catalog:*|"") \
            OPENTUI_VERSION=$(jq -r '.workspaces.catalog["@opentui/core"]' package.json) \
            ;; \
        *) \
            OPENTUI_VERSION="$PKG_VERSION" \
            ;; \
    esac \
    && OPENTUI_VERSION=${OPENTUI_VERSION#^} \
    && OPENTUI_VERSION=${OPENTUI_VERSION#~} \
    && echo "$OPENTUI_VERSION" > /opt/opentui-version \
    && echo "Detected @opentui/core version: $OPENTUI_VERSION"

# ---------------------------------------------------------------------------
# Stage 2: rebuild @opentui/core native library against musl libc.
#
# Upstream opentui (anomalyco/opentui) ships a single linux-x64 prebuild
# linked against glibc 2.28+ (see packages/core/src/zig/build.zig). On systems
# with older glibc (e.g. QTS 5.2.9, glibc 2.21), the .so fails to load:
#
#     /lib/libc.so.6: version `GLIBC_2.27' not found
#
# We patch build.zig to target x86_64-linux-musl and rebuild. The resulting
# .so links against musl libc, which is already bundled in lib/. The musl
# dynamic linker resolves it via the .path file mechanism — no glibc needed.
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM oven/bun:debian AS opentui-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl xz-utils build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2 (required by opentui's build.zig — see
# packages/core/src/zig/build.zig SUPPORTED_ZIG_VERSIONS).
ARG ZIG_VERSION=0.15.2
ARG ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
RUN set -eux \
    && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -xJ -C /opt -f /tmp/zig.tar.xz \
    && rm /tmp/zig.tar.xz \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && zig version

COPY --from=opencode-clone /opt/opentui-version /opt/opentui-version

WORKDIR /opentui
RUN OPENTUI_VERSION="$(cat /opt/opentui-version)" \
    && echo "Cloning opentui v${OPENTUI_VERSION}" \
    && git clone --depth 1 --branch "v${OPENTUI_VERSION}" https://github.com/anomalyco/opentui.git .

# Patch build.zig:
#   1. Replace the SUPPORTED_TARGETS array with a single linux-musl x86_64 entry.
#      The `--all` build path (-Dall) iterates all supported targets; restricting
#      to one avoids needing the macOS SDK and cross-toolchains we don't have.
#   2. Without this, building the host target alone (default code path) crashes
#      Zig 0.15.2's build_runner with an index-out-of-bounds panic in
#      shuffleWithIndex. The `--all` path takes a different graph traversal.
#
# Use awk to surgically rewrite SUPPORTED_TARGETS. We trigger on the array
# opener and skip lines until the closing `};` on its own line.
RUN awk ' \
        /^const SUPPORTED_TARGETS = / { \
            print "const SUPPORTED_TARGETS = [_]SupportedTarget{"; \
            print "    .{ .zig_target = \"x86_64-linux-musl\", .output_name = \"x86_64-linux\", .description = \"Linux x86_64 (musl)\" },"; \
            print "};"; \
            skipping = 1; next \
        } \
        skipping && /^\};/ { skipping = 0; next } \
        !skipping { print } \
    ' packages/core/src/zig/build.zig > /tmp/build.zig.new \
    && mv /tmp/build.zig.new packages/core/src/zig/build.zig \
    && echo "--- patched SUPPORTED_TARGETS:" \
    && grep -A2 'SUPPORTED_TARGETS' packages/core/src/zig/build.zig | head -5

# Run bun install from the repo root (matches opentui's CI). Running from
# packages/core in isolation gives a degenerate workspace graph that may
# trigger different build_runner behaviour.
RUN bun install

# Build the native library for linux/amd64. Using the script's `--all` path
# (which passes -Dall to zig) takes the buildAllTargets code path. Combined
# with our patched SUPPORTED_TARGETS, this builds only x86_64-linux-musl.
#
# Zig 0.15.2's build_runner has a probabilistic index-out-of-bounds panic in
# shuffleWithIndex (Random.zig:375) that depends on the random seed picked
# at startup. Empirically the bug fires on roughly 1 in 2 seeds, so we retry
# the build up to N times until a seed lands that doesn't trigger it.
RUN set -eu \
    && cd packages/core \
    && ATTEMPT=0 \
    && MAX_ATTEMPTS=12 \
    && while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do \
        ATTEMPT=$((ATTEMPT + 1)); \
        echo "=== opentui zig build attempt ${ATTEMPT}/${MAX_ATTEMPTS} ==="; \
        if bun scripts/build.ts --native --all; then \
            echo "=== opentui zig build succeeded on attempt ${ATTEMPT} ==="; \
            break; \
        fi; \
        if [ "$ATTEMPT" -eq "$MAX_ATTEMPTS" ]; then \
            echo "ERROR: opentui zig build failed ${MAX_ATTEMPTS} times"; \
            exit 1; \
        fi; \
        echo "Build attempt ${ATTEMPT} failed (likely Zig 0.15.2 shuffle panic), retrying..."; \
        rm -rf src/zig/.zig-cache; \
    done \
    && ls -la node_modules/@opentui/core-linux-x64/

# Verify the resulting .so links against musl and not glibc.
RUN set -e \
    && SO=packages/core/node_modules/@opentui/core-linux-x64/libopentui.so \
    && echo "=== Verifying $SO links against musl ===" \
    && ls -la "$SO" \
    && (readelf -d "$SO" | grep -E 'NEEDED|RPATH' || true) \
    && if readelf -V "$SO" 2>/dev/null | grep -qE 'GLIBC_[0-9]'; then \
        echo "ERROR: $SO still references GLIBC symbols — musl rebuild failed"; \
        readelf -V "$SO" | grep -E 'GLIBC_[0-9]' | head -20; \
        exit 1; \
    fi \
    && echo "OK: $SO is musl-linked"

# ---------------------------------------------------------------------------
# Stage 3: build opencode, embedding the musl-built opentui .so.
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM oven/bun:debian AS builder

ARG VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git patchelf python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch "${VERSION}" https://github.com/anomalyco/opencode.git .

RUN bun install

# Replace the glibc-linked opentui .so with our musl-built one BEFORE running
# opencode's build.ts. `bun build --compile` embeds whatever is in
# node_modules/@opentui/core-linux-x64/ into the final binary via bunfs.
COPY --from=opentui-builder \
    /opentui/packages/core/node_modules/@opentui/core-linux-x64/libopentui.so \
    /tmp/libopentui-musl.so
RUN set -e \
    && TARGET=$(find node_modules -path '*/@opentui/core-linux-x64/libopentui.so' -not -path '*/.bun-tag*' | head -1) \
    && if [ -z "$TARGET" ]; then \
        echo "ERROR: could not locate @opentui/core-linux-x64/libopentui.so in node_modules"; \
        find node_modules -name 'libopentui.so' -print; \
        exit 1; \
    fi \
    && echo "Replacing $TARGET with musl-built variant" \
    && cp /tmp/libopentui-musl.so "$TARGET" \
    && readelf -d "$TARGET" | grep -E 'NEEDED' \
    && rm /tmp/libopentui-musl.so

# Strip 'v' prefix from VERSION for OPENCODE_VERSION (e.g., v1.1.35 -> 1.1.35)
RUN OPENCODE_VERSION="${VERSION#v}" ./packages/opencode/script/build.ts

# Patch the binary to use a custom interpreter path that we'll symlink at runtime
RUN patchelf --set-interpreter /tmp/.opencode-ld/ld-musl-x86_64.so.1 \
    /build/packages/opencode/dist/opencode-linux-x64-baseline-musl/bin/opencode

# ---------------------------------------------------------------------------
# Stage 4: get musl and libs from Alpine (x86_64 for QNAP target)
# ---------------------------------------------------------------------------
FROM --platform=$BUILD_PLATFORM alpine:latest AS musl
RUN apk add --no-cache musl libstdc++ libgcc

# ---------------------------------------------------------------------------
# Stage 5: package wrapper scripts
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
COPY --from=builder /build/packages/opencode/dist/opencode-linux-x64-baseline-musl/bin/opencode /opencode/lib/opencode
COPY --from=musl /lib/ld-musl-x86_64.so.1 /opencode/lib/
COPY --from=musl /usr/lib/libstdc++.so.6 /opencode/lib/
COPY --from=musl /usr/lib/libgcc_s.so.1 /opencode/lib/
COPY --from=ldpreload /opencode/lib/clear_ldpath.so /opencode/lib/
COPY --from=wrapper /opencode/bin/opencode /opencode/bin/opencode
COPY --from=wrapper /opencode/bin/opencode.bin /opencode/bin/opencode.bin
