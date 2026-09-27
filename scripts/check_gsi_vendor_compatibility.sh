#!/usr/bin/env bash
# ============================================================================
# check_gsi_vendor_compatibility.sh - compare a GSI with target vendor props
#
# A GSI still needs the target device's vendor HALs and kernel.  This check
# cannot prove that a device will boot, but it rejects a confirmed ABI clash
# and records SDK/VNDK mismatches before a device-specific package is flashed.
# ============================================================================

set -Eeuo pipefail

GSI_PROP="${1:-}"
VENDOR_PROP="${2:-}"
REPORT_PATH="${3:-compatibility-report.txt}"

if [ -z "$GSI_PROP" ] || [ ! -f "$GSI_PROP" ] \
  || [ -z "$VENDOR_PROP" ] || [ ! -f "$VENDOR_PROP" ]; then
  echo "Usage: check_gsi_vendor_compatibility.sh <gsi-build.prop> <vendor-build.prop> <report>" >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT_PATH")"

prop() {
  local file="$1"
  local key="$2"
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, wanted "=") == 1) {
        sub(/^[^=]*=/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

first_prop() {
  local file="$1"
  shift
  local key value
  for key in "$@"; do
    value=$(prop "$file" "$key" || true)
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
  done
  printf '%s' "unknown"
}

has_abi() {
  local list=",$1,"
  local abi="$2"
  case "$list" in
    *,"$abi",*) return 0 ;;
    *) return 1 ;;
  esac
}

GSI_SDK=$(first_prop "$GSI_PROP" ro.build.version.sdk)
GSI_VNDK=$(first_prop "$GSI_PROP" ro.vndk.version)
GSI_VNDK_LITE=$(first_prop "$GSI_PROP" ro.vndk.lite)
GSI_ABI_LIST=$(first_prop "$GSI_PROP" ro.product.system.cpu.abilist ro.product.cpu.abilist)
GSI_ABI64_LIST=$(first_prop "$GSI_PROP" ro.product.system.cpu.abilist64 ro.product.cpu.abilist64)
GSI_ABI=$(first_prop "$GSI_PROP" ro.product.system.cpu.abi ro.product.cpu.abi)

VENDOR_SDK=$(first_prop "$VENDOR_PROP" ro.vendor.build.version.sdk ro.build.version.sdk)
VENDOR_VNDK=$(first_prop "$VENDOR_PROP" ro.vndk.version ro.vendor.vndk.version)
VENDOR_VNDK_LITE=$(first_prop "$VENDOR_PROP" ro.vndk.lite ro.vendor.vndk.lite)
VENDOR_ABI_LIST=$(first_prop "$VENDOR_PROP" ro.vendor.product.cpu.abilist ro.product.cpu.abilist)
VENDOR_ABI64_LIST=$(first_prop "$VENDOR_PROP" ro.vendor.product.cpu.abilist64 ro.product.cpu.abilist64)
VENDOR_ABI=$(first_prop "$VENDOR_PROP" ro.vendor.product.cpu.abi ro.product.cpu.abi)

STATUS="PASS"
FAILURES=()
WARNINGS=()

fail() {
  STATUS="FAIL"
  FAILURES+=("$1")
}

warn() {
  [ "$STATUS" = "FAIL" ] || STATUS="WARN"
  WARNINGS+=("$1")
}

GSI_ABI_TEXT="$GSI_ABI_LIST,$GSI_ABI64_LIST,$GSI_ABI"
VENDOR_ABI_TEXT="$VENDOR_ABI_LIST,$VENDOR_ABI64_LIST,$VENDOR_ABI"
GSI_HAS_ARM64=0
GSI_HAS_ARM32=0
VENDOR_HAS_ARM64=0
VENDOR_HAS_ARM32=0
has_abi "$GSI_ABI_TEXT" arm64-v8a && GSI_HAS_ARM64=1 || true
has_abi "$GSI_ABI_TEXT" arm64 && GSI_HAS_ARM64=1 || true
has_abi "$GSI_ABI_TEXT" armeabi-v7a && GSI_HAS_ARM32=1 || true
has_abi "$GSI_ABI_TEXT" armeabi && GSI_HAS_ARM32=1 || true
has_abi "$VENDOR_ABI_TEXT" arm64-v8a && VENDOR_HAS_ARM64=1 || true
has_abi "$VENDOR_ABI_TEXT" arm64 && VENDOR_HAS_ARM64=1 || true
has_abi "$VENDOR_ABI_TEXT" armeabi-v7a && VENDOR_HAS_ARM32=1 || true
has_abi "$VENDOR_ABI_TEXT" armeabi && VENDOR_HAS_ARM32=1 || true

if [ "$GSI_HAS_ARM64" = "1" ] && [ "$VENDOR_HAS_ARM64" = "0" ] \
  && [ "$VENDOR_HAS_ARM32" = "1" ]; then
  fail "The ARM64 GSI has no matching ARM64 ABI in the target vendor properties."
fi
if [ "$GSI_HAS_ARM32" = "1" ] && [ "$VENDOR_HAS_ARM32" = "0" ] \
  && [ "$VENDOR_HAS_ARM64" = "1" ] && [ "$GSI_HAS_ARM64" = "0" ]; then
  fail "The 32-bit GSI has no matching 32-bit ABI in the target vendor properties."
fi

if [[ "$GSI_SDK" =~ ^[0-9]+$ ]] && [[ "$VENDOR_SDK" =~ ^[0-9]+$ ]] \
  && [ "$GSI_SDK" -gt "$VENDOR_SDK" ]; then
  warn "GSI SDK $GSI_SDK is newer than target vendor SDK $VENDOR_SDK; VNDK compatibility must be verified."
fi

if [[ "$GSI_VNDK" =~ ^[0-9]+$ ]] && [[ "$VENDOR_VNDK" =~ ^[0-9]+$ ]] \
  && [ "$GSI_VNDK" -gt "$VENDOR_VNDK" ]; then
  warn "GSI VNDK $GSI_VNDK is newer than target vendor VNDK $VENDOR_VNDK; use a matching VNDK/VNDKLite GSI."
fi

case "$(printf '%s' "$VENDOR_VNDK_LITE" | tr '[:upper:]' '[:lower:]')" in
  true|1|yes)
    case "$(printf '%s' "$GSI_VNDK_LITE" | tr '[:upper:]' '[:lower:]')" in
      true|1|yes) ;;
      *) warn "Target vendor advertises VNDKLite but the GSI does not; select a VNDKLite GSI variant." ;;
    esac
    ;;
esac

warn "This comparison cannot validate the target kernel, DTB, boot ramdisk, AVB chain, recovery, or proprietary HAL behavior."

{
  printf '%s\n' 'GSI/vendor compatibility comparison'
  printf '%s\n' '====================================='
  printf 'Status: %s\n' "$STATUS"
  printf 'GSI build.prop: %s\n' "$(basename "$GSI_PROP")"
  printf 'Target vendor build.prop: %s\n' "$(basename "$VENDOR_PROP")"
  printf 'GSI SDK: %s\n' "$GSI_SDK"
  printf 'Vendor SDK: %s\n' "$VENDOR_SDK"
  printf 'GSI VNDK: %s\n' "$GSI_VNDK"
  printf 'Vendor VNDK: %s\n' "$VENDOR_VNDK"
  printf 'GSI VNDKLite: %s\n' "$GSI_VNDK_LITE"
  printf 'Vendor VNDKLite: %s\n' "$VENDOR_VNDK_LITE"
  printf 'GSI ABI list: %s\n' "$GSI_ABI_LIST"
  printf 'GSI ABI64 list: %s\n' "$GSI_ABI64_LIST"
  printf 'GSI ABI: %s\n' "$GSI_ABI"
  printf 'Vendor ABI list: %s\n' "$VENDOR_ABI_LIST"
  printf 'Vendor ABI64 list: %s\n' "$VENDOR_ABI64_LIST"
  printf 'Vendor ABI: %s\n' "$VENDOR_ABI"
  printf '\nHard failures:\n'
  if [ "${#FAILURES[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
  else
    printf -- '- %s\n' "${FAILURES[@]}"
  fi
  printf '\nWarnings:\n'
  if [ "${#WARNINGS[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
  else
    printf -- '- %s\n' "${WARNINGS[@]}"
  fi
} | tee "$REPORT_PATH"

if [ "$STATUS" = "FAIL" ]; then
  echo "[-] GSI/vendor compatibility comparison failed." >&2
  exit 1
fi

echo "==> GSI/vendor compatibility comparison passed with status: $STATUS"
