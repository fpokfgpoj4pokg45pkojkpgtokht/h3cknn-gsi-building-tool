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
TEMP_FILE="$TEMP_DIR/lpmake"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "==> [SETUP] Installing verified AOSP lpmake..."
LPMake_READY=0
for i in "${!LPMake_URLS[@]}"; do
  rm -f -- "$TEMP_DIR/lpmake.b64" "$TEMP_FILE"
  echo "  -> Trying pinned AOSP lpmake source $((i + 1))/${#LPMake_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LPMake_URLS[$i]}" -o "$TEMP_DIR/lpmake.b64"; then
    echo "  [!] lpmake source unavailable; trying the next pinned source" >&2
    continue
  fi
  if [[ "${LPMake_URLS[$i]}" == *"format=TEXT"* ]]; then
    if ! base64 --decode "$TEMP_DIR/lpmake.b64" > "$TEMP_FILE"; then
      echo "  [!] lpmake source could not be decoded; trying the next pinned source" >&2
      continue
    fi
  else
    # GitHub's raw fallback is already an ELF binary, not AOSP's base64
    # transport representation.
    cp -- "$TEMP_DIR/lpmake.b64" "$TEMP_FILE"
  fi
  if [ ! -s "$TEMP_FILE" ]; then
    echo "  [!] lpmake source was empty; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LPMake_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LPMake_SHAS[$i]}" "$TEMP_FILE" | sha256sum --check --status; then
    echo "  [!] lpmake checksum mismatch; refusing this source" >&2
    continue
  fi
  LPMake_READY=1
  LPMake_SOURCE_INDEX="$i"
  break
done
if [ "$LPMake_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake source could be downloaded." >&2
  exit 1
fi

ANDROID_LIB_DIR="$(dirname "$(find -L /usr/lib -type f -path '*/android/libbase.so' -print -quit)")"
if [ -z "$ANDROID_LIB_DIR" ] || [ "$ANDROID_LIB_DIR" = "." ]; then
  echo "[-] ERROR: Ubuntu Android library directory was not found." >&2
  exit 1
fi
echo "==> [SETUP] Installing matching AOSP lpmake libraries..."
LIB_READY=0
if [ "${#LIB_ARCHIVE_URLS[@]}" -eq 1 ]; then
  LIB_INDICES=(0)
elif [ "${LPMake_SOURCE_INDEX:-0}" = "1" ]; then
  LIB_INDICES=(1 0)
else
  LIB_INDICES=(0 1)
fi
for i in "${LIB_INDICES[@]}"; do
  rm -f -- "$TEMP_DIR/lib64.tar.gz"
  rm -rf -- "$TEMP_DIR/lib64"
  echo "  -> Trying matching AOSP library source $((i + 1))/${#LIB_ARCHIVE_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LIB_ARCHIVE_URLS[$i]}" -o "$TEMP_DIR/lib64.tar.gz"; then
    echo "  [!] AOSP library source unavailable; trying the next pinned source" >&2
    continue
  fi
  mkdir -p "$TEMP_DIR/lib64"
  if ! tar -xzf "$TEMP_DIR/lib64.tar.gz" -C "$TEMP_DIR/lib64" \
    || [ ! -f "$TEMP_DIR/lib64/liblp.so" ]; then
    echo "  [!] AOSP library archive is invalid; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LIB_LP_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LIB_LP_SHAS[$i]}" "$TEMP_DIR/lib64/liblp.so" | sha256sum --check --status; then
    echo "  [!] liblp.so checksum mismatch; refusing this source" >&2
    continue
  fi
  LIB_READY=1
  break
done
if [ "$LIB_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake library archive could be downloaded." >&2
  exit 1
fi

echo "==> [SETUP] Installing verified AOSP e2fsdroid..."
E2FSDROID_READY=0
E2FSDROID_INDICES=()
if [ "${LPMake_SOURCE_INDEX:-0}" = "1" ] && [ "${#E2FSDROID_URLS[@]}" -gt 1 ]; then
  E2FSDROID_INDICES=(1 0)
else
  for i in "${!E2FSDROID_URLS[@]}"; do
    E2FSDROID_INDICES+=("$i")
  done
fi
for i in "${E2FSDROID_INDICES[@]}"; do
  rm -f -- "$TEMP_DIR/e2fsdroid.b64" "$TEMP_DIR/e2fsdroid"
  echo "  -> Trying pinned AOSP e2fsdroid source $((i + 1))/${#E2FSDROID_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${E2FSDROID_URLS[$i]}" -o "$TEMP_DIR/e2fsdroid.b64"; then
    echo "  [!] e2fsdroid source unavailable; trying the next pinned source" >&2
    continue
  fi
  if ! base64 --decode "$TEMP_DIR/e2fsdroid.b64" > "$TEMP_DIR/e2fsdroid"; then
    echo "  [!] e2fsdroid source could not be decoded; trying the next pinned source" >&2
    continue
  fi
  if [ ! -s "$TEMP_DIR/e2fsdroid" ]; then
    echo "  [!] e2fsdroid source was empty; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${E2FSDROID_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${E2FSDROID_SHAS[$i]}" "$TEMP_DIR/e2fsdroid" \
      | sha256sum --check --status; then
    echo "  [!] e2fsdroid checksum mismatch; refusing this source" >&2
    continue
  fi
  E2FSDROID_READY=1
  break
done
if [ "$E2FSDROID_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP e2fsdroid source could be downloaded." >&2
  exit 1
fi

AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
sudo install -m 0755 "$TEMP_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
sudo install -m 0755 "$TEMP_FILE" "$AOSP_LIB_DIR/lpmake.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/lpmake_wrapper.sh" /usr/local/bin/lpmake
sudo install -m 0755 "$TEMP_DIR/e2fsdroid" "$AOSP_LIB_DIR/e2fsdroid.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/e2fsdroid_wrapper.sh" /usr/local/bin/e2fsdroid
echo "  [+] lpmake installed at /usr/local/bin/lpmake"
echo "  [+] e2fsdroid installed at /usr/local/bin/e2fsdroid"
