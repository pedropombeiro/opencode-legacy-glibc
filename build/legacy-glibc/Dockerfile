# Build on linux/amd64 to ensure correct baseline binary
ARG BUILD_PLATFORM=linux/amd64
FROM --platform=$BUILD_PLATFORM oven/bun:1.3.5-debian AS builder

ARG VERSION

RUN apt-get update && apt-get install -y git patchelf && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch "${VERSION}" https://github.com/anomalyco/opencode.git .

RUN bun install

# Strip 'v' prefix from VERSION for OPENCODE_VERSION (e.g., v1.1.35 -> 1.1.35)
RUN OPENCODE_VERSION="${VERSION#v}" ./packages/opencode/script/build.ts

# Patch the binary to use a custom interpreter path that we'll symlink at runtime
RUN patchelf --set-interpreter /tmp/.opencode-ld/ld-musl-x86_64.so.1 \
    /build/packages/opencode/dist/opencode-linux-x64-baseline-musl/bin/opencode

# Get musl and libs from Alpine (x86_64 for QNAP target)
FROM --platform=$BUILD_PLATFORM alpine:latest AS musl
RUN apk add --no-cache musl libstdc++ libgcc

FROM alpine:latest AS wrapper
COPY opencode /opencode/bin/opencode
RUN chmod +x /opencode/bin/opencode

FROM scratch AS export
COPY --from=builder /build/packages/opencode/dist/opencode-linux-x64-baseline-musl/bin/opencode /opencode/bin/opencode.bin
COPY --from=musl /lib/ld-musl-x86_64.so.1 /opencode/lib/
COPY --from=musl /usr/lib/libstdc++.so.6 /opencode/lib/
COPY --from=musl /usr/lib/libgcc_s.so.1 /opencode/lib/
COPY --from=wrapper /opencode/bin/opencode /opencode/bin/opencode
