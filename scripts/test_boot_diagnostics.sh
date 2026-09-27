#!/usr/bin/env bash
# Regression tests for boot-failure classification.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/boot-diagnostics-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/blocked"
cat > "$TEST_DIR/blocked/getprop.txt" <<'EOF'
[ro.boot.verifiedbootstate]: [red]
[sys.boot_completed]: [0]
EOF
cat > "$TEST_DIR/blocked/dmesg.txt" <<'EOF'
Kernel panic - not syncing: VFS: Unable to mount root fs
EOF
cat > "$TEST_DIR/blocked/logcat-all.txt" <<'EOF'
avb_slot_verify failed: vbmeta verification failed
avc: denied { read } for name="vendor"
EOF

bash "$ROOT_DIR/scripts/analyze_boot_diagnostics.sh" \
  "$TEST_DIR/blocked" "$TEST_DIR/blocked-report.txt" >/dev/null
grep -Fx 'Status: BOOT_BLOCKED' "$TEST_DIR/blocked-report.txt" >/dev/null
grep -F 'AVB / dm-verity' "$TEST_DIR/blocked-report.txt" >/dev/null
grep -F 'Kernel / boot chain' "$TEST_DIR/blocked-report.txt" >/dev/null
grep -F 'SELinux policy' "$TEST_DIR/blocked-report.txt" >/dev/null
grep -F 'exact target vbmeta/AVB procedure' "$TEST_DIR/blocked-report.txt" >/dev/null

mkdir -p "$TEST_DIR/booted"
cat > "$TEST_DIR/booted/getprop.txt" <<'EOF'
[sys.boot_completed]: [1]
EOF
bash "$ROOT_DIR/scripts/analyze_boot_diagnostics.sh" \
  "$TEST_DIR/booted" "$TEST_DIR/booted-report.txt" >/dev/null
grep -Fx 'Status: ANDROID_REACHED_BOOT_COMPLETED' "$TEST_DIR/booted-report.txt" >/dev/null

echo "==> Boot diagnostics analysis test passed."
