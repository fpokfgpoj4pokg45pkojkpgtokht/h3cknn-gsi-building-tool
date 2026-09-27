#!/usr/bin/env bash
# ============================================================================
# analyze_boot_diagnostics.sh - classify evidence collected from a failed boot
#
# This is intentionally read-only.  It does not guess or modify a GSI.  A GSI
# cannot supply a universal kernel, DTB, vendor HAL, or AVB chain; the useful
# next step is to identify which device-specific layer rejected the image.
#
# Usage: analyze_boot_diagnostics.sh <diagnostics-dir> [report-path]
# ============================================================================

set -Eeuo pipefail

DIAGNOSTICS_DIR="${1:-}"
REPORT_PATH="${2:-${DIAGNOSTICS_DIR:+$DIAGNOSTICS_DIR/boot-analysis.txt}}"

if [ -z "$DIAGNOSTICS_DIR" ] || [ ! -d "$DIAGNOSTICS_DIR" ]; then
  echo "Usage: analyze_boot_diagnostics.sh <diagnostics-dir> [report-path]" >&2
  exit 2
fi
if [ -z "$REPORT_PATH" ]; then
  echo "[-] ERROR: A report path could not be derived." >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT_PATH")"

FINDINGS=()
DETAILS=()

scan_files() {
  local category="$1"
  local pattern="$2"
  shift 2
  local file sample
  for file in "$@"; do
    [ -f "$file" ] || continue
    if grep -Eiq -- "$pattern" "$file"; then
      FINDINGS+=("$category")
      sample=$(grep -Eim 3 -- "$pattern" "$file" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g')
      DETAILS+=("$category: $sample")
      return 0
    fi
  done
  return 0
}

scan_files \
  'AVB / dm-verity' \
  'avb(_slot_verify)?.*(fail|error)|vbmeta.*(fail|error|invalid|verification)|dm-verity.*(fail|error|corrupt)|hashtree.*(fail|error)|verification failed|verifiedbootstate.*\[(red|yellow)\]' \
  "$DIAGNOSTICS_DIR/getprop.txt" \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/pstore.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

scan_files \
  'Kernel / boot chain' \
  'kernel panic|panic - not syncing|watchdog|unable to mount root|failed to load.*(dtb|module)|fatal exception.*init|first-stage init.*fail' \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/pstore.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

scan_files \
  'Vendor HAL / VINTF' \
  'hwservicemanager|vintf|hal.*(not found|failed)|manifest.*(not found|failed)|hidl.*(error|failed)|aidl.*(error|failed)|cannot find.*vendor' \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

scan_files \
  'SELinux policy' \
  'avc: *denied|selinux.*(denied|reject|permissive)|neverallow' \
  "$DIAGNOSTICS_DIR/selinux-mode.txt" \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/pstore.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

scan_files \
  'System / filesystem mount' \
  'failed to mount|mount.*(system|vendor|product).*fail|fs_mgr.*(fail|error|cannot|unable)|zygote.*(crash|abort)|system_server.*(crash|fatal)|apex.*(fail|error)' \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/pstore.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

scan_files \
  'Storage / data setup' \
  'no space left|insufficient storage|metadata.*(corrupt|fail)|unable to mount.*data|/data.*(encrypt|decrypt).*fail|fbe.*fail' \
  "$DIAGNOSTICS_DIR/dmesg.txt" \
  "$DIAGNOSTICS_DIR/pstore.txt" \
  "$DIAGNOSTICS_DIR/logcat-all.txt"

BOOT_COMPLETED=0
if [ -f "$DIAGNOSTICS_DIR/getprop.txt" ] \
  && grep -Eiq '^\[sys\.boot_completed\]: \[1\]' "$DIAGNOSTICS_DIR/getprop.txt"; then
  BOOT_COMPLETED=1
fi

if [ "$BOOT_COMPLETED" = "1" ]; then
  STATUS='ANDROID_REACHED_BOOT_COMPLETED'
elif [ "${#FINDINGS[@]}" -gt 0 ]; then
  STATUS='BOOT_BLOCKED'
else
  STATUS='INSUFFICIENT_EVIDENCE'
fi

{
  printf '%s\n' 'GSI boot diagnostics analysis'
  printf '%s\n' '============================'
  printf 'Status: %s\n' "$STATUS"
  printf 'Diagnostics directory: %s\n' "$(basename "$DIAGNOSTICS_DIR")"
  printf '\nFindings:\n'
  if [ "${#FINDINGS[@]}" -eq 0 ]; then
    printf '%s\n' 'none detected in the collected evidence'
  else
    printf -- '- %s\n' "${FINDINGS[@]}"
  fi
  printf '\nEvidence samples:\n'
  if [ "${#DETAILS[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
  else
    printf -- '- %s\n' "${DETAILS[@]}"
  fi
  printf '\nRecommended next action:\n'
  if [ "$STATUS" = 'ANDROID_REACHED_BOOT_COMPLETED' ]; then
    printf '%s\n' 'The system reached Android; investigate framework crashes, hardware services, and SELinux denials rather than replacing the kernel blindly.'
  elif printf '%s\n' "${FINDINGS[@]}" | grep -Fqx 'AVB / dm-verity'; then
    printf '%s\n' 'Use the exact target vbmeta/AVB procedure and matching boot chain. Do not disable verification by editing the GSI system image.'
  elif printf '%s\n' "${FINDINGS[@]}" | grep -Fqx 'Kernel / boot chain'; then
    printf '%s\n' 'Use the exact device/firmware kernel, DTB, vendor ramdisk, and boot image; a system-only GSI cannot repair this layer.'
  elif [ "${#FINDINGS[@]}" -gt 0 ]; then
    printf '%s\n' 'Keep the exact target vendor and boot chain, then fix the reported vendor/system or policy mismatch before rebuilding.'
  else
    printf '%s\n' 'Collect pstore/dmesg/logcat earlier in the boot loop; the current files do not contain enough evidence to identify the failing layer.'
  fi
} | tee "$REPORT_PATH"

echo "==> Boot diagnostics analysis written to: $REPORT_PATH"
