# OpenCode Legacy GLIBC Builds

Automated builds of [OpenCode](https://github.com/anomalyco/opencode) v2 with bundled musl libraries for systems with older GLIBC versions (e.g., QNAP NAS).

[![Build for legacy GLIBC](https://github.com/pedropombeiro/opencode-legacy-glibc/actions/workflows/build.yml/badge.svg)](https://github.com/pedropombeiro/opencode-legacy-glibc/actions/workflows/build.yml)

## Installation

### Using mise

```bash
mise install github:pedropombeiro/opencode-legacy-glibc@latest
```

### Manual

1. Download the latest release from the [Releases](https://github.com/pedropombeiro/opencode-legacy-glibc/releases) page
2. Extract the tarball
3. Run `./opencode/bin/opencode`

See the [OpenCode V2 documentation](https://opencode.ai/v2/docs/) for usage and configuration.

## How it works

A scheduled GitHub Action checks hourly for new stable releases of
[`@opencode/cli`](https://www.npmjs.com/package/@opencode/cli) on npm. For each new version, it:

1. Downloads the upstream `@opencode/cli-linux-x64-baseline-musl` binary and verifies its npm integrity hash.
2. Patches the binary's ELF interpreter to point at a bundled musl dynamic linker.
3. Packages it with the musl loader, `libstdc++`, `libgcc_s`, and wrapper scripts.
4. Runs a compatibility test suite on CentOS 7 (glibc 2.17) before publishing a release.

Releases up to `v1.18.32` were built from OpenCode v1 sources. See
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for technical details.
