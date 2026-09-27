#!/usr/bin/env bash
# Regression test for offline GSI/vendor preflight on compressed images.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gsi-vendor-preflight-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

for command_name in debugfs file gzip mke2fs truncate xz; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

truncate -s 8M "$TEST_DIR/gsi.img"
truncate -s 8M "$TEST_DIR/vendor.img"
mke2fs -t ext4 -F -L system "$TEST_DIR/gsi.img" >/dev/null
mke2fs -t ext4 -F -L vendor "$TEST_DIR/vendor.img" >/dev/null

cat > "$TEST_DIR/gsi.prop" <<'EOF'
ro.build.version.sdk=35
ro.vndk.version=35
ro.product.cpu.abilist=arm64-v8a,armeabi-v7a,armeabi
EOF
cat > "$TEST_DIR/vendor.prop" <<'EOF'
ro.vendor.build.version.sdk=34
ro.vndk.version=34
ro.vendor.product.cpu.abilist64=arm64-v8a
EOF
debugfs -w -R "write $TEST_DIR/gsi.prop /build.prop" \
  "$TEST_DIR/gsi.img" >/dev/null 2>&1
debugfs -w -R "write $TEST_DIR/vendor.prop /build.prop" \
  "$TEST_DIR/vendor.img" >/dev/null 2>&1
xz -c "$TEST_DIR/gsi.img" > "$TEST_DIR/gsi.img.xz"

bash "$ROOT_DIR/scripts/preflight_gsi_against_vendor.sh" \
  "$TEST_DIR/gsi.img.xz" "$TEST_DIR/vendor.img" "$TEST_DIR/report.txt" >/dev/null
grep -Fx 'Status: WARN' "$TEST_DIR/report.txt" >/dev/null
grep -F 'Vendor ABI64 list: arm64-v8a' "$TEST_DIR/report.txt" >/dev/null

truncate -s 8M "$TEST_DIR/incompatible-vendor.img"
mke2fs -t ext4 -F -L vendor "$TEST_DIR/incompatible-vendor.img" >/dev/null
cat > "$TEST_DIR/incompatible-vendor.prop" <<'EOF'
ro.vendor.build.version.sdk=35
ro.vendor.product.cpu.abilist=armeabi-v7a,armeabi
EOF
debugfs -w -R "write $TEST_DIR/incompatible-vendor.prop /build.prop" \
  "$TEST_DIR/incompatible-vendor.img" >/dev/null 2>&1
if bash "$ROOT_DIR/scripts/preflight_gsi_against_vendor.sh" \
  "$TEST_DIR/gsi.img.xz" "$TEST_DIR/incompatible-vendor.img" \
  "$TEST_DIR/fail-report.txt" >/dev/null 2>&1; then
  echo "[-] Confirmed ABI-incompatible GSI/vendor pair incorrectly passed." >&2
  exit 1
fi
grep -F 'no matching ARM64 ABI' "$TEST_DIR/fail-report.txt" >/dev/null

echo "==> Offline GSI/vendor preflight test passed."
