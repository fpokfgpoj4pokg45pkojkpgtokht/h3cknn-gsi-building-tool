#!/usr/bin/env bash
# Regression tests for the GSI/vendor compatibility comparison.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gsi-vendor-compat-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

cat > "$TEST_DIR/gsi.prop" <<'EOF'
ro.build.version.sdk=35
ro.vndk.version=35
ro.product.cpu.abilist=arm64-v8a,armeabi-v7a,armeabi
EOF

cat > "$TEST_DIR/vendor.prop" <<'EOF'
ro.vendor.build.version.sdk=34
ro.vndk.version=34
ro.product.cpu.abilist64=arm64-v8a
EOF

bash "$ROOT_DIR/scripts/check_gsi_vendor_compatibility.sh" \
  "$TEST_DIR/gsi.prop" "$TEST_DIR/vendor.prop" "$TEST_DIR/report.txt" >/dev/null
grep -Fx 'Status: WARN' "$TEST_DIR/report.txt" >/dev/null
grep -F 'GSI SDK 35 is newer than target vendor SDK 34' "$TEST_DIR/report.txt" >/dev/null
grep -F 'GSI VNDK 35 is newer than target vendor VNDK 34' "$TEST_DIR/report.txt" >/dev/null

cat > "$TEST_DIR/arm64-vendor.prop" <<'EOF'
ro.vendor.build.version.sdk=35
ro.product.cpu.abilist=armeabi-v7a,armeabi
EOF

if bash "$ROOT_DIR/scripts/check_gsi_vendor_compatibility.sh" \
  "$TEST_DIR/gsi.prop" "$TEST_DIR/arm64-vendor.prop" "$TEST_DIR/fail-report.txt" >/dev/null 2>&1; then
  echo "[-] ABI-incompatible GSI/vendor pair incorrectly passed." >&2
  exit 1
fi
grep -F 'no matching ARM64 ABI' "$TEST_DIR/fail-report.txt" >/dev/null

echo "==> GSI/vendor compatibility test passed."
