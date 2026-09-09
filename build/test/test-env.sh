#!/bin/sh
# Deterministic tests for the legacy-glibc opencode build.
# No LLM API key required.
#
# Architecture:
#   bin/opencode      -> creates musl .path file + loader symlink -> bin/opencode.bin
#   bin/opencode.bin  -> sets LD_PRELOAD=clear_ldpath.so -> lib/opencode
#   lib/opencode      -> real 152MB musl-linked binary
#   clear_ldpath.so   -> clears LD_PRELOAD from environ
#
# The musl dynamic linker finds libs via /tmp/.opencode-ld/ld-musl-x86_64.path
# instead of LD_LIBRARY_PATH. This is invisible to glibc, solving the catch-22.
#
# Usage: docker run --platform linux/amd64 --rm <image> sh /opt/test-env.sh

set -e

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m: %s\n" "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31mFAIL\033[0m: %s\n" "$1"
}

LIB=/opt/opencode/lib
BIN=/opt/opencode/bin
LOADER_DIR=/tmp/.opencode-ld

mkdir -p "$LOADER_DIR" /tmp/etc
ln -sf "$LIB/ld-musl-x86_64.so.1" "$LOADER_DIR/ld-musl-x86_64.so.1"
printf '%s' "$LIB" >/tmp/etc/ld-musl-x86_64.path

echo "=== 1. Wrapper chain launches opencode ==="
if "$BIN/opencode" --version >/dev/null 2>&1; then
  pass "opencode --version via wrapper"
else
  fail "opencode --version via wrapper"
fi

echo ""
echo "=== 2. Direct binary launches via .path file ==="
OC_VER=$("$LIB/opencode" --version 2>&1) || true
if echo "$OC_VER" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "lib/opencode works via .path file: v$OC_VER"
else
  fail "lib/opencode failed: $OC_VER"
fi

echo ""
echo "=== 3. clear_ldpath.so has no dynamic dependencies ==="
NEEDED=$(readelf -d "$LIB/clear_ldpath.so" 2>/dev/null | grep NEEDED || true)
if [ -z "$NEEDED" ]; then
  pass "clear_ldpath.so is self-contained (no NEEDED entries)"
else
  fail "clear_ldpath.so has dependencies: $NEEDED"
fi

echo ""
echo "=== 4. glibc child can load clear_ldpath.so via LD_PRELOAD ==="
if LD_PRELOAD="$LIB/clear_ldpath.so" /bin/sh -c 'echo ok' >/dev/null 2>&1; then
  pass "glibc /bin/sh works with LD_PRELOAD=clear_ldpath.so"
else
  fail "glibc /bin/sh crashes with LD_PRELOAD=clear_ldpath.so"
fi

echo ""
echo "=== 5. LD_PRELOAD is cleared by clear_ldpath.so ==="
CHILD_PRELOAD=$(
  LD_PRELOAD="$LIB/clear_ldpath.so" \
    /bin/sh -c 'printf "%s" "$LD_PRELOAD"'
) || true
if [ -z "$CHILD_PRELOAD" ]; then
  pass "LD_PRELOAD cleared by clear_ldpath.so"
else
  fail "LD_PRELOAD leaked: '$CHILD_PRELOAD'"
fi

echo ""
echo "=== 6. BUN_BE_BUN=1 launches bun ==="
BUN_VERSION=$(
  BUN_BE_BUN=1 "$LIB/opencode" --version 2>&1
) || true
if echo "$BUN_VERSION" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "BUN_BE_BUN=1 works: bun $BUN_VERSION"
else
  fail "BUN_BE_BUN=1 failed: $BUN_VERSION"
fi

echo ""
echo "=== 7. Grandchild glibc processes work ==="
cat >/tmp/test_grandchild.js <<'JSEOF'
var cp = require("child_process");
try {
  var out = cp.execSync("/bin/sh -c 'echo grandchild_ok'", { encoding: "utf8" });
  process.stdout.write(out.trim());
} catch(e) {
  process.stdout.write("CRASH:" + e.message.split("\n")[0]);
}
JSEOF
GRANDCHILD=$(
  BUN_BE_BUN=1 "$LIB/opencode" run /tmp/test_grandchild.js 2>/dev/null
) || true
if [ "$GRANDCHILD" = "grandchild_ok" ]; then
  pass "grandchild glibc process runs without crashing"
else
  fail "grandchild failed: '$GRANDCHILD'"
fi

echo ""
echo "=== 8. No LD_LIBRARY_PATH in environment ==="
cat >/tmp/test_no_ldpath.js <<'JSEOF'
var cp = require("child_process");
var out = cp.execSync("/bin/sh -c 'printf \"%s\" \"$LD_LIBRARY_PATH\"'", { encoding: "utf8" });
process.stdout.write(out);
JSEOF
CHILD_LD=$(
  LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" run /tmp/test_no_ldpath.js 2>/dev/null
) || true
if [ -z "$CHILD_LD" ]; then
  pass "LD_LIBRARY_PATH not set in grandchild"
else
  fail "LD_LIBRARY_PATH leaked to grandchild: '$CHILD_LD'"
fi

echo ""
echo "=== 9. process.execPath re-invocation works (simulates plugin install) ==="
cat >/tmp/test_reinvoke.js <<'JSEOF'
var cp = require("child_process");
try {
  var env = Object.assign({}, process.env, { BUN_BE_BUN: "1" });
  delete env.LD_PRELOAD;
  delete env.LD_LIBRARY_PATH;
  var out = cp.execSync(process.execPath + " --version", { encoding: "utf8", env: env });
  process.stdout.write(out.trim());
} catch(e) {
  process.stdout.write("FAIL:" + (e.status || "") + ":" + e.message.split("\n")[0]);
}
JSEOF
REINVOKE=$(
  LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" run /tmp/test_reinvoke.js 2>/dev/null
) || true
if echo "$REINVOKE" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "process.execPath re-invocation works: bun $REINVOKE"
else
  fail "process.execPath re-invocation failed: '$REINVOKE'"
fi

echo ""
echo "=== 10. Plugin install succeeds ==="
mkdir -p /tmp/testpkg
echo '{}' >/tmp/testpkg/package.json
if BUN_BE_BUN=1 "$LIB/opencode" add --cwd /tmp/testpkg opencode-anthropic-auth@0.0.13 >/dev/null 2>&1; then
  PKG_COUNT=$(find /tmp/testpkg/node_modules/ -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  if [ "$PKG_COUNT" -gt 0 ]; then
    pass "plugin install: $PKG_COUNT packages in node_modules"
  else
    fail "plugin install exited 0 but node_modules is empty"
  fi
else
  fail "plugin install failed"
fi

echo ""
echo "=== 11. git works (no LD_LIBRARY_PATH contamination) ==="
if git --version >/dev/null 2>&1; then
  pass "git works without LD_LIBRARY_PATH"
else
  fail "git broken"
fi

echo ""
echo "=== 12. opencode.bin wrapper works ==="
OC_VERSION2=$(
  "$BIN/opencode.bin" --version 2>&1
) || true
if echo "$OC_VERSION2" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "opencode.bin wrapper works: v$OC_VERSION2"
else
  fail "opencode.bin wrapper failed: $OC_VERSION2"
fi

echo ""
echo "=== 13. OpenTUI native library loads (regression test for issue #3) ==="
# opencode 1.14.49+ extracts the @opentui/core .so from bunfs and dlopen's it.
# Upstream ships it linked against glibc 2.28+, which fails on glibc 2.21 (QTS
# 5.2.9) and on glibc 2.17 (centos7). We rebuild it against musl. This test
# triggers the dlopen path by running opencode with stdin closed and TUI logs
# enabled, and asserts the failure message is absent. timeout uses SIGKILL so
# the TUI cannot ignore the signal and the test cannot hang.
TUI_OUT=$(timeout -s KILL 10 "$BIN/opencode" --print-logs --log-level ERROR </dev/null 2>&1 || true)
if echo "$TUI_OUT" | grep -q "Failed to initialize OpenTUI render library"; then
  fail "OpenTUI native library failed to load — issue #3 regression"
  echo "$TUI_OUT" | grep -A2 "Failed to initialize OpenTUI" | head -6
elif echo "$TUI_OUT" | grep -qE 'GLIBC_2\.(2[5-9]|3[0-9])'; then
  fail "OpenTUI native library reports missing GLIBC symbols"
  echo "$TUI_OUT" | grep -E 'GLIBC_' | head -3
else
  pass "OpenTUI native library loads without glibc errors"
fi

echo ""
echo "=== 14. OpenCode runtime initializes without internal errors ==="
# `debug v2` exercises the runtime's dependency graph without an LLM API key.
# A bundled dependency initialization regression in v1.18.28+ crashed here with:
# TypeError: undefined is not an object (evaluating 'a.name')
if RUNTIME_OUT=$(timeout 30 "$BIN/opencode" --print-logs --log-level DEBUG debug v2 2>&1); then
  pass "opencode runtime initializes"
else
  fail "opencode runtime initialization failed"
  printf '%s\n' "$RUNTIME_OUT"
fi

echo ""
echo "============================================"
printf "Results: \033[32m%d passed\033[0m" "$PASS"
[ "$FAIL" -gt 0 ] && printf ", \033[31m%d failed\033[0m" "$FAIL"
echo ""
echo "============================================"
[ "$FAIL" -eq 0 ]
