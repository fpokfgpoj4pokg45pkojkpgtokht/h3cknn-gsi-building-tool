#!/usr/bin/env bash
# ============================================================================
# preflight_gsi_against_vendor.sh - compare any GSI with a target vendor image
#
# This is a device-neutral preflight.  It checks the system/vendor properties
# that can be inspected offline, while explicitly leaving kernel, DTB, boot
# ramdisk, AVB, recovery, and proprietary HAL behavior to the target package.
#
# Usage: preflight_gsi_against_vendor.sh <gsi> <vendor> [report-path]
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
GSI_INPUT="${1:-}"
VENDOR_INPUT="${2:-}"
REPORT_PATH="${3:-compatibility-report.txt}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gsi-vendor-preflight.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

if [ -z "$GSI_INPUT" ] || [ ! -f "$GSI_INPUT" ] \
  || [ -z "$VENDOR_INPUT" ] || [ ! -f "$VENDOR_INPUT" ]; then
  echo "Usage: preflight_gsi_against_vendor.sh <gsi> <vendor> [report-path]" >&2
  exit 2
fi

materialize() {
  local input="$1"
  local output="$2"
  local lower
  lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.img.xz|*.xz) xz -dc -- "$input" > "$output" ;;
    *.img.gz|*.gz) gzip -dc -- "$input" > "$output" ;;
    *.img.lz4|*.lz4) lz4 -dc -- "$input" > "$output" ;;
    *) cp -- "$input" "$output" ;;
  esac
  [ -s "$output" ] || {
    echo "[-] ERROR: Materialized image is empty: $input" >&2
    exit 1
  }
}

GSI_IMAGE="$WORK_DIR/gsi.img"
VENDOR_IMAGE="$WORK_DIR/vendor.img"
GSI_PROP="$WORK_DIR/gsi-build.prop"
VENDOR_PROP="$WORK_DIR/vendor-build.prop"
materialize "$GSI_INPUT" "$GSI_IMAGE"
materialize "$VENDOR_INPUT" "$VENDOR_IMAGE"

bash "$SCRIPT_DIR/extract_build_prop_from_image.sh" \
  "$GSI_IMAGE" "$GSI_PROP" "$WORK_DIR/gsi-prop" >/dev/null
bash "$SCRIPT_DIR/extract_build_prop_from_image.sh" \
  "$VENDOR_IMAGE" "$VENDOR_PROP" "$WORK_DIR/vendor-prop" >/dev/null

bash "$SCRIPT_DIR/check_gsi_vendor_compatibility.sh" \
  "$GSI_PROP" "$VENDOR_PROP" "$REPORT_PATH"
