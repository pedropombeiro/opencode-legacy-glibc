#!/bin/sh
# Deterministic tests for the LD_LIBRARY_PATH / LD_PRELOAD / clear_ldpath.so
# interaction. Runs inside a test container with the legacy-glibc opencode build.
# No LLM API key required.
#
# Tests use BUN_BE_BUN=1 to access bun runtime for JS execution. This also
# exercises the real clear_ldpath.so code path since the .so is loaded via
# LD_PRELOAD into the musl binary.
#
# IMPORTANT: Bun caches process.env at startup and uses that cache when
# spawning child processes. The clear_ldpath.so constructor modifies the
# C-level environ, but Bun passes its own cached copy to children. Therefore
# clear_ldpath.so is compiled with -nostdlib (no libc dependency) so that
# even if LD_PRELOAD leaks to glibc children, they can load the .so harmlessly.
#
# Usage: docker run --platform linux/amd64 --rm <image> sh /opt/test-env.sh

set -e

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m: %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m: %s\n" "$1"; }

LIB=/opt/opencode/lib
BIN=/opt/opencode/bin

mkdir -p /tmp/.opencode-ld
ln -sf "$LIB/ld-musl-x86_64.so.1" /tmp/.opencode-ld/ld-musl-x86_64.so.1

echo "=== 1. Wrapper chain launches opencode ==="
if "$BIN/opencode" --version >/dev/null 2>&1; then
  pass "opencode --version via wrapper"
else
  fail "opencode --version via wrapper"
fi

echo ""
echo "=== 2. clear_ldpath.so has no dynamic dependencies ==="
NEEDED=$(readelf -d "$LIB/clear_ldpath.so" 2>/dev/null | grep NEEDED || true)
if [ -z "$NEEDED" ]; then
  pass "clear_ldpath.so is self-contained (no NEEDED entries)"
else
  fail "clear_ldpath.so has dependencies: $NEEDED"
fi

echo ""
echo "=== 3. glibc child can load clear_ldpath.so via LD_PRELOAD ==="
if LD_PRELOAD="$LIB/clear_ldpath.so" /bin/sh -c 'echo ok' >/dev/null 2>&1; then
  pass "glibc /bin/sh works with LD_PRELOAD=clear_ldpath.so"
else
  fail "glibc /bin/sh crashes with LD_PRELOAD=clear_ldpath.so"
fi

echo ""
echo "=== 4. glibc child works with LD_LIBRARY_PATH + LD_PRELOAD ==="
if LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$LIB/clear_ldpath.so" /bin/sh -c 'echo ok' >/dev/null 2>&1; then
  pass "glibc /bin/sh works with both LD_LIBRARY_PATH and LD_PRELOAD"
else
  fail "glibc /bin/sh crashes with both LD_LIBRARY_PATH and LD_PRELOAD"
fi

echo ""
echo "=== 5. BUN_BE_BUN=1 launches bun (plugin install path) ==="
BUN_VERSION=$(
  LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" --version 2>&1
) || true
if echo "$BUN_VERSION" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "BUN_BE_BUN=1 works: bun $BUN_VERSION"
else
  fail "BUN_BE_BUN=1 failed: $BUN_VERSION"
fi

echo ""
echo "=== 6. BUN_BE_BUN=1 preserves LD_LIBRARY_PATH for bun process ==="
cat > /tmp/test_bun_ld.js <<'JSEOF'
process.stdout.write(process.env.LD_LIBRARY_PATH || "");
JSEOF
BUN_LD=$(
  LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" run /tmp/test_bun_ld.js 2>/dev/null
) || true
if [ "$BUN_LD" = "$LIB" ]; then
  pass "LD_LIBRARY_PATH preserved with BUN_BE_BUN=1: $BUN_LD"
else
  fail "LD_LIBRARY_PATH expected '$LIB' with BUN_BE_BUN=1, got '$BUN_LD'"
fi

echo ""
echo "=== 7. Grandchild glibc processes work (no crash from LD_PRELOAD leak) ==="
cat > /tmp/test_grandchild.js <<'JSEOF'
var cp = require("child_process");
try {
  var out = cp.execSync("/bin/sh -c 'echo grandchild_ok'", { encoding: "utf8" });
  process.stdout.write(out.trim());
} catch(e) {
  process.stdout.write("CRASH:" + e.message.split("\n")[0]);
}
JSEOF
GRANDCHILD=$(
  LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" run /tmp/test_grandchild.js 2>/dev/null
) || true
if [ "$GRANDCHILD" = "grandchild_ok" ]; then
  pass "grandchild glibc process runs without crashing"
else
  fail "grandchild failed: '$GRANDCHILD'"
fi

echo ""
echo "=== 8. Plugin install succeeds ==="
mkdir -p /tmp/testpkg
echo '{}' > /tmp/testpkg/package.json
if LD_LIBRARY_PATH="$LIB" LD_PRELOAD="$LIB/clear_ldpath.so" BUN_BE_BUN=1 \
    "$LIB/opencode" add --cwd /tmp/testpkg opencode-anthropic-auth@0.0.13 >/dev/null 2>&1; then
  PKG_COUNT=$(ls /tmp/testpkg/node_modules/ 2>/dev/null | wc -l)
  if [ "$PKG_COUNT" -gt 0 ]; then
    pass "plugin install: $PKG_COUNT packages in node_modules"
  else
    fail "plugin install exited 0 but node_modules is empty"
  fi
else
  fail "plugin install failed"
fi

echo ""
echo "=== 9. git works when LD_LIBRARY_PATH is set ==="
if LD_LIBRARY_PATH="$LIB" git --version >/dev/null 2>&1; then
  pass "git works with LD_LIBRARY_PATH set"
else
  fail "git broken with LD_LIBRARY_PATH set"
fi

echo ""
echo "=== 10. opencode.bin restores LD_LIBRARY_PATH from _OPENCODE_LIB_PATH ==="
OC_VERSION=$(
  _OPENCODE_LIB_PATH="$LIB" "$BIN/opencode.bin" --version 2>&1
) || true
if echo "$OC_VERSION" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "opencode.bin restores lib path: v$OC_VERSION"
else
  fail "opencode.bin with _OPENCODE_LIB_PATH failed: $OC_VERSION"
fi

echo ""
echo "=== 11. opencode.bin falls back to SCRIPT_DIR/lib without stash ==="
OC_VERSION2=$(
  "$BIN/opencode.bin" --version 2>&1
) || true
if echo "$OC_VERSION2" | grep -qE '^[0-9]+\.[0-9]+'; then
  pass "opencode.bin works without _OPENCODE_LIB_PATH: v$OC_VERSION2"
else
  fail "opencode.bin without _OPENCODE_LIB_PATH failed: $OC_VERSION2"
fi

echo ""
echo "============================================"
printf "Results: \033[32m%d passed\033[0m" "$PASS"
[ "$FAIL" -gt 0 ] && printf ", \033[31m%d failed\033[0m" "$FAIL"
echo ""
echo "============================================"
[ "$FAIL" -eq 0 ]
