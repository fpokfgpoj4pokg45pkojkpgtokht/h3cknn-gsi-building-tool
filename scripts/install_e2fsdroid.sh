#!/usr/bin/env bash
# Install a verified AOSP e2fsdroid for generic ext4 GSI repacks.
#
# This is deliberately separate from install_lpmake.sh: generic GSI builds need
# filesystem metadata support, but they do not need the Samsung super-image
# builder or its liblp dependency.

set -Eeuo pipefail

tool_starts() {
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  # A no-argument usage failure is expected and varies by AOSP revision. Do
  # reject missing interpreters, permission errors, and signal termination.
  [ "$status" -lt 125 ]
}

if command -v e2fsdroid >/dev/null 2>&1 && tool_starts e2fsdroid; then
  echo "  [+] e2fsdroid already present"
  exit 0
fi

# Keep each binary paired with the libraries from the same AOSP revision.
# The second revision is an independent fallback for transient source outages.
PRIMARY_COMMIT="39a8ce1951d13b0f31996ae153865729e831d0f9"
FALLBACK_COMMIT="978920d8481c684fc798f9bac23e1a7605e4ab26"
PRIMARY_LIBLP_SHA256="af1f83237fed0c284d2c24ed6cf64381cf4e6cbe0e54f02c6299d5bb5dda0ec0"
FALLBACK_LIBLP_SHA256="95221e036a664be40d67e07e0dfd026305f12390fdfa957d4aa3a3296bd519a3"
PRIMARY_E2FSDROID_SHA256="ca8b1bd989718b62f670381b3ef245276becc9a4a919e50e96948f6c051e267e"
FALLBACK_E2FSDROID_SHA256="a56dbdb9f19a5be79f3de5914ad576d938fc497429d36dc476ed223d2049a81f"
PLATFORM_TOOLS_E2FSDROID_URL="https://android.googlesource.com/platform/prebuilts/fullsdk-linux/platform-tools/+/83a183b4bced4377eb5817074db82885cfcae393/e2fsdroid?format=TEXT"
PLATFORM_TOOLS_E2FSDROID_SHA256="9c11ea7840cfd14322d750a3fa1f2c2821969466c3ac8fe67c09da6dc6937dfd"

E2FSDROID_URLS=(
  "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$PRIMARY_COMMIT/linux-x86/bin/e2fsdroid?format=TEXT"
  "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$FALLBACK_COMMIT/linux-x86/bin/e2fsdroid?format=TEXT"
)
E2FSDROID_SHAS=("$PRIMARY_E2FSDROID_SHA256" "$FALLBACK_E2FSDROID_SHA256")
LIB_ARCHIVE_URLS=(
  "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$PRIMARY_COMMIT/linux-x86/lib64.tar.gz"
  "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$FALLBACK_COMMIT/linux-x86/lib64.tar.gz"
)
LIB_LP_SHAS=("$PRIMARY_LIBLP_SHA256" "$FALLBACK_LIBLP_SHA256")

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

download_aosp_blob() {
  local url="$1"
  local destination="$2"
  local sha256="$3"
  local encoded="$TEMP_DIR/download.b64"

  rm -f -- "$encoded" "$destination"
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "$url" -o "$encoded" || return 1
  base64 --decode "$encoded" > "$destination" || return 1
  [ -s "$destination" ] || return 1
  printf '%s  %s\n' "$sha256" "$destination" \
    | sha256sum --check --status || return 1
}

echo "==> [SETUP] Installing a matching verified AOSP e2fsdroid bundle..."
BUNDLE_READY=0
BUNDLE_DIR="$TEMP_DIR/bundle"
for i in "${!E2FSDROID_URLS[@]}"; do
  rm -rf -- "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR/lib64"
  echo "  -> Trying matching AOSP filesystem bundle $((i + 1))/${#E2FSDROID_URLS[@]}..."

  if ! download_aosp_blob \
    "${E2FSDROID_URLS[$i]}" \
    "$BUNDLE_DIR/e2fsdroid" \
    "${E2FSDROID_SHAS[$i]}"; then
    echo "  [!] e2fsdroid source unavailable or failed verification" >&2
    continue
  fi

  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LIB_ARCHIVE_URLS[$i]}" -o "$BUNDLE_DIR/lib64.tar.gz"; then
    echo "  [!] matching AOSP library source unavailable" >&2
    continue
  fi
  if ! tar -xzf "$BUNDLE_DIR/lib64.tar.gz" -C "$BUNDLE_DIR/lib64" \
    || [ ! -f "$BUNDLE_DIR/lib64/liblp.so" ]; then
    echo "  [!] matching AOSP library archive is invalid" >&2
    continue
  fi
  # The tar wrapper contains variable timestamps; verify the extracted binary.
  if ! printf '%s  %s\n' "${LIB_LP_SHAS[$i]}" "$BUNDLE_DIR/lib64/liblp.so" \
    | sha256sum --check --status; then
    echo "  [!] matching liblp.so checksum mismatch" >&2
    continue
  fi

  chmod 0755 "$BUNDLE_DIR/e2fsdroid"
  BUNDLE_LD_LIBRARY_PATH="$BUNDLE_DIR/lib64:/usr/lib/x86_64-linux-gnu/android"
  if ! tool_starts env LD_LIBRARY_PATH="$BUNDLE_LD_LIBRARY_PATH" \
    "$BUNDLE_DIR/e2fsdroid"; then
    echo "  [!] matching e2fsdroid/library bundle failed its execution check" >&2
    continue
  fi
  BUNDLE_READY=1
  break
done

# The kernel-prebuilts repository can temporarily return 5xx responses even
# when the official platform-tools mirror is available. This older AOSP binary
# is a last-resort fallback; it uses the host's e2fsprogs/SELinux libraries and
# is still checksum-pinned before it can be installed.
if [ "$BUNDLE_READY" != "1" ]; then
  echo "  -> Trying official AOSP platform-tools e2fsdroid fallback..."
  rm -rf -- "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR/lib64"
  if download_aosp_blob \
    "$PLATFORM_TOOLS_E2FSDROID_URL" \
    "$BUNDLE_DIR/e2fsdroid" \
    "${PLATFORM_TOOLS_E2FSDROID_SHA256// /}"; then
    chmod 0755 "$BUNDLE_DIR/e2fsdroid"
    if tool_starts "$BUNDLE_DIR/e2fsdroid"; then
      BUNDLE_READY=1
      echo "  [+] official AOSP platform-tools fallback is executable"
    fi
  fi
fi

if [ "$BUNDLE_READY" != "1" ]; then
  echo "[-] ERROR: No matching verified AOSP e2fsdroid bundle could be installed." >&2
  exit 1
fi

AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
if compgen -G "$BUNDLE_DIR/lib64/*.so" >/dev/null; then
  sudo install -m 0755 "$BUNDLE_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
fi
sudo install -m 0755 "$BUNDLE_DIR/e2fsdroid" "$AOSP_LIB_DIR/e2fsdroid.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/e2fsdroid_wrapper.sh" /usr/local/bin/e2fsdroid
echo "  [+] verified AOSP e2fsdroid installed"
