# OpenCode Legacy GLIBC Builds

Automated builds of [OpenCode](https://github.com/anomalyco/opencode) with bundled musl libraries for systems with older GLIBC versions (e.g., QNAP NAS).

## Installation

### Using mise

```bash
mise install github:pedropombeiro/opencode-legacy-glibc@latest
```

### Manual

1. Download the latest release from the [Releases](https://github.com/pedropombeiro/opencode-legacy-glibc/releases) page
2. Extract the tarball
3. Run `./opencode/bin/opencode`

## How it works

A scheduled GitHub Action checks daily for new releases from the upstream OpenCode repository and builds a version with bundled musl libraries, allowing it to run on systems with older GLIBC versions.
