#!/usr/bin/env bash
# Install the AOSP dynamic-partition image builder used by the Samsung workflow.

set -Eeuo pipefail

if command -v lpmake >/dev/null 2>&1 \
  && lpmake --help >/dev/null 2>&1 \
  && command -v e2fsdroid >/dev/null 2>&1; then
  E2FSDROID_STATUS=0
  # AOSP e2fsdroid has no --help option; with no image it prints usage and
  # exits 1. That still proves the ELF and its shared libraries can execute.
  e2fsdroid >/dev/null 2>&1 || E2FSDROID_STATUS=$?
  if [ "$E2FSDROID_STATUS" -eq 0 ] || [ "$E2FSDROID_STATUS" -eq 1 ]; then
    echo "  [+] lpmake and e2fsdroid already present"
    exit 0
  fi
fi

# Ubuntu's android-sdk-libsparse-utils package contains simg2img, but not
# lpmake. These are pinned AOSP prebuilts; every candidate is verified before
# installation. The second revision is an independent fallback for transient
# android.googlesource.com 5xx outages.
PRIMARY_COMMIT="39a8ce1951d13b0f31996ae153865729e831d0f9"
FALLBACK_COMMIT="978920d8481c684fc798f9bac23e1a7605e4ab26"
PRIMARY_LP_SHA256="276c0c8a046a69e6a2780e08835077119ad7129ddc59cbd12920ecba193d2d31"
FALLBACK_LP_SHA256="5413f722b60f2971bad343a28fb4c7f83984af8e3e13b5224b9ce99840527fde"
PRIMARY_LIBLP_SHA256="af1f83237fed0c284d2c24ed6cf64381cf4e6cbe0e54f02c6299d5bb5dda0ec0"
FALLBACK_LIBLP_SHA256="95221e036a664be40d67e07e0dfd026305f12390fdfa957d4aa3a3296bd519a3"
PRIMARY_E2FSDROID_SHA256="ca8b1bd989718b62f670381b3ef245276becc9a4a919e50e96948f6c051e267e"
FALLBACK_E2FSDROID_SHA256="a56dbdb9f19a5be79f3de5914ad576d938fc497429d36dc476ed223d2049a81f"
if [ -n "${LPMake_URL:-}" ]; then
  LPMake_URLS=("$LPMake_URL")
  LPMake_SHAS=("${LPMake_SHA256_OVERRIDE:-}")
else
  LPMake_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$PRIMARY_COMMIT/linux-x86/bin/lpmake?format=TEXT"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$FALLBACK_COMMIT/linux-x86/bin/lpmake?format=TEXT"
  )
  LPMake_SHAS=("$PRIMARY_LP_SHA256" "$FALLBACK_LP_SHA256")
fi

if [ -n "${LIB_ARCHIVE_URL:-}" ]; then
  LIB_ARCHIVE_URLS=("$LIB_ARCHIVE_URL")
  LIB_LP_SHAS=("${LIBLP_SHA256_OVERRIDE:-}")
else
  LIB_ARCHIVE_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$PRIMARY_COMMIT/linux-x86/lib64.tar.gz"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$FALLBACK_COMMIT/linux-x86/lib64.tar.gz"
  )
  # The tar.gz wrapper contains variable archive timestamps. Verify the
  # extracted AOSP liblp.so instead of hashing the non-deterministic wrapper.
  LIB_LP_SHAS=("$PRIMARY_LIBLP_SHA256" "$FALLBACK_LIBLP_SHA256")
fi

if [ -n "${E2FSDROID_URL:-}" ]; then
  E2FSDROID_URLS=("$E2FSDROID_URL")
  E2FSDROID_SHAS=("${E2FSDROID_SHA256_OVERRIDE:-}")
else
  E2FSDROID_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$PRIMARY_COMMIT/linux-x86/bin/e2fsdroid?format=TEXT"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$FALLBACK_COMMIT/linux-x86/bin/e2fsdroid?format=TEXT"
  )
  E2FSDROID_SHAS=("$PRIMARY_E2FSDROID_SHA256" "$FALLBACK_E2FSDROID_SHA256")
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

ANDROID_LIB_DIR="$(dirname "$(find -L /usr/lib -type f -path '*/android/libbase.so' -print -quit)")"
if [ -z "$ANDROID_LIB_DIR" ] || [ "$ANDROID_LIB_DIR" = "." ]; then
  echo "[-] ERROR: Ubuntu Android library directory was not found." >&2
  exit 1
fi

download_aosp_blob() {
  local url="$1"
  local destination="$2"
  local sha256="$3"
  local encoded="$TEMP_DIR/download.b64"

  rm -f -- "$encoded" "$destination"
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "$url" -o "$encoded"; then
    return 1
  fi
  if [[ "$url" == *"format=TEXT"* ]]; then
    base64 --decode "$encoded" > "$destination" || return 1
  else
    cp -- "$encoded" "$destination"
  fi
  [ -s "$destination" ] || return 1
  if [ -n "$sha256" ]; then
    printf '%s  %s\n' "$sha256" "$destination" \
      | sha256sum --check --status || return 1
  fi
}

tool_responds() {
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

echo "==> [SETUP] Installing a matching verified AOSP image-tool bundle..."
BUNDLE_READY=0
BUNDLE_DIR="$TEMP_DIR/bundle"
for i in "${!LPMake_URLS[@]}"; do
  LIB_INDEX=0
  E2FSDROID_INDEX=0
  if [ "${#LIB_ARCHIVE_URLS[@]}" -gt 1 ]; then
    LIB_INDEX="$i"
  fi
  if [ "${#E2FSDROID_URLS[@]}" -gt 1 ]; then
    E2FSDROID_INDEX="$i"
  fi
  if [ "$LIB_INDEX" -ge "${#LIB_ARCHIVE_URLS[@]}" ] \
    || [ "$E2FSDROID_INDEX" -ge "${#E2FSDROID_URLS[@]}" ]; then
    continue
  fi

  rm -rf -- "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR/lib64"
  echo "  -> Trying matching AOSP tool bundle $((i + 1))/${#LPMake_URLS[@]}..."

  if ! download_aosp_blob \
    "${LPMake_URLS[$i]}" \
    "$BUNDLE_DIR/lpmake" \
    "${LPMake_SHAS[$i]}"; then
    echo "  [!] lpmake source unavailable or failed verification" >&2
    continue
  fi

  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LIB_ARCHIVE_URLS[$LIB_INDEX]}" -o "$BUNDLE_DIR/lib64.tar.gz"; then
    echo "  [!] matching AOSP library source unavailable" >&2
    continue
  fi
  if ! tar -xzf "$BUNDLE_DIR/lib64.tar.gz" -C "$BUNDLE_DIR/lib64" \
    || [ ! -f "$BUNDLE_DIR/lib64/liblp.so" ]; then
    echo "  [!] matching AOSP library archive is invalid" >&2
    continue
  fi
  if [ -n "${LIB_LP_SHAS[$LIB_INDEX]}" ] \
    && ! printf '%s  %s\n' "${LIB_LP_SHAS[$LIB_INDEX]}" "$BUNDLE_DIR/lib64/liblp.so" \
      | sha256sum --check --status; then
    echo "  [!] matching liblp.so checksum mismatch" >&2
    continue
  fi

  if ! download_aosp_blob \
    "${E2FSDROID_URLS[$E2FSDROID_INDEX]}" \
    "$BUNDLE_DIR/e2fsdroid" \
    "${E2FSDROID_SHAS[$E2FSDROID_INDEX]}"; then
    echo "  [!] matching e2fsdroid source unavailable or failed verification" >&2
    continue
  fi

  chmod 0755 "$BUNDLE_DIR/lpmake" "$BUNDLE_DIR/e2fsdroid"
  BUNDLE_LD_LIBRARY_PATH="$BUNDLE_DIR/lib64:/usr/lib/x86_64-linux-gnu/android"
  if ! env LD_LIBRARY_PATH="$BUNDLE_LD_LIBRARY_PATH" \
    "$BUNDLE_DIR/lpmake" --help >/dev/null 2>&1; then
    echo "  [!] matching lpmake/library bundle failed its execution check" >&2
    continue
  fi
  if ! tool_responds env LD_LIBRARY_PATH="$BUNDLE_LD_LIBRARY_PATH" \
    "$BUNDLE_DIR/e2fsdroid"; then
    echo "  [!] matching e2fsdroid/library bundle failed its execution check" >&2
    continue
  fi
  BUNDLE_READY=1
  break
done

if [ "$BUNDLE_READY" != "1" ]; then
  echo "[-] ERROR: No matching verified AOSP lpmake/e2fsdroid bundle could be installed." >&2
  exit 1
fi

AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
sudo install -m 0755 "$BUNDLE_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
sudo install -m 0755 "$BUNDLE_DIR/lpmake" "$AOSP_LIB_DIR/lpmake.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/lpmake_wrapper.sh" /usr/local/bin/lpmake
sudo install -m 0755 "$BUNDLE_DIR/e2fsdroid" "$AOSP_LIB_DIR/e2fsdroid.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/e2fsdroid_wrapper.sh" /usr/local/bin/e2fsdroid
echo "  [+] matching lpmake and e2fsdroid installed"
