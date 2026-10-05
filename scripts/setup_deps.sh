#!/usr/bin/env bash
# ==============================================================================
# setup_deps.sh - Install dependencies for GSI Porting & Source Building
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOOLS_DIR="$SCRIPT_DIR/../tools"
BIN_DIR="/usr/local/bin"

# Keep downloaded Java inside the repository/tool tree.
JAVA_DIR="$TOOLS_DIR/jdk17"
JAVA_HOME="$JAVA_DIR"

# Temurin OpenJDK 17 Linux x64.
# This is downloaded directly instead of relying on Ubuntu's Java packages.
JAVA_VERSION="17.0.16+8"
JAVA_ARCHIVE="OpenJDK17U-jdk_x64_linux_hotspot_17.0.16_8.tar.gz"
JAVA_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.16%2B8/$JAVA_ARCHIVE"

# SHA256 for the pinned Temurin archive.
JAVA_SHA256=""

echo
echo "============================================================"
echo "GSI PORTING DEPENDENCY SETUP"
echo "============================================================"

# ==============================================================================
# OPERATING SYSTEM
# ==============================================================================

echo
echo "==> [SETUP] Detecting operating system..."

if [ -f /etc/os-release ]; then
  . /etc/os-release

  echo "  OS:      ${PRETTY_NAME:-unknown}"
  echo "  Version: ${VERSION_ID:-unknown}"
else
  echo "  WARNING: /etc/os-release not found."
fi

echo
echo "Architecture:"
uname -m

case "$(uname -m)" in
  x86_64|amd64)
    echo "  [+] x86_64 runner detected."
    ;;
  *)
    echo
    echo "ERROR: This Java download is for x86_64 Linux."
    echo "Detected architecture: $(uname -m)"
    exit 1
    ;;
esac

# ==============================================================================
# APT
# ==============================================================================

echo
echo "==> [SETUP] Updating package indices..."

sudo apt-get update -qq

echo
echo "==> [SETUP] Installing required system utilities & build packages..."

# ------------------------------------------------------------------------------
# Ubuntu package compatibility
#
# Old packages:
#
#   liblz4-tool -> lz4
#   p7zip-full  -> 7zip
#   p7zip-rar   -> 7zip
#
# ------------------------------------------------------------------------------

APT_PACKAGES=(
  aria2
  bc
  bison
  brotli
  build-essential
  ccache
  curl
  e2fsprogs
  erofs-utils
  flex
  git
  gnupg
  gperf
  imagemagick
  libncurses6
  libncurses-dev
  libssl-dev
  libxml2-utils
  lz4
  lzop
  python3
  python3-pip
  rsync
  schedtool
  squashfs-tools
  tar
  unzip
  wget
  xsltproc
  zip
  zlib1g-dev
  zstd
  android-sdk-libsparse-utils
  android-libbase-dev
  7zip
)

echo
echo "Required packages:"
printf '  - %s\n' "${APT_PACKAGES[@]}"

sudo apt-get install \
  -y \
  -qq \
  --no-install-recommends \
  "${APT_PACKAGES[@]}"

# ==============================================================================
# OPTIONAL MULTILIB
# ==============================================================================

OPTIONAL_PACKAGES=(
  g++-multilib
  gcc-multilib
  lib32readline-dev
  lib32z1-dev
)

echo
echo "Optional multilib packages:"

for package in "${OPTIONAL_PACKAGES[@]}"; do

  if apt-cache show "$package" >/dev/null 2>&1; then

    echo "  -> Installing $package"

    sudo apt-get install \
      -y \
      -qq \
      --no-install-recommends \
      "$package" \
      || echo "  [!] Could not install optional package: $package"

  else

    echo "  [!] Package unavailable: $package"

  fi

done

# ==============================================================================
# SELF-CONTAINED JAVA
# ==============================================================================

echo
echo "============================================================"
echo "JAVA SETUP"
echo "============================================================"

echo
echo "==> [SETUP] Checking self-contained Java..."

mkdir -p "$TOOLS_DIR"

# ------------------------------------------------------------------------------
# Reuse our own JDK if it already exists.
# ------------------------------------------------------------------------------

if [ -x "$JAVA_DIR/bin/java" ]; then

  echo "  [+] Existing self-contained JDK detected:"
  echo "      $JAVA_DIR"

else

  echo "  -> Self-contained JDK not found."
  echo "  -> Downloading Temurin OpenJDK 17 with wget..."
  echo
  echo "     Version: $JAVA_VERSION"
  echo "     URL:"
  echo "     $JAVA_URL"

  JAVA_TMP="/tmp/$JAVA_ARCHIVE"

  rm -f "$JAVA_TMP"

  wget \
    --https-only \
    --tries=5 \
    --timeout=30 \
    --waitretry=5 \
    --continue \
    --show-progress \
    "$JAVA_URL" \
    -O "$JAVA_TMP"

  if [ ! -s "$JAVA_TMP" ]; then
    echo
    echo "ERROR: Java download failed or produced an empty file."
    exit 1
  fi

  echo
  echo "  [+] Java archive downloaded:"
  ls -lh "$JAVA_TMP"

  echo
  echo "  -> Checking archive..."

  if ! tar -tzf "$JAVA_TMP" >/dev/null 2>&1; then

    echo
    echo "ERROR: Downloaded Java archive is invalid."
    file "$JAVA_TMP" || true
    exit 1

  fi

  echo "  [+] Java archive is valid."

  # --------------------------------------------------------------------------
  # Extract to a temporary location first.
  # --------------------------------------------------------------------------

  JAVA_EXTRACT="/tmp/gsi-jdk17"

  rm -rf "$JAVA_EXTRACT"
  mkdir -p "$JAVA_EXTRACT"

  echo
  echo "  -> Extracting Java..."

  tar \
    -xzf "$JAVA_TMP" \
    -C "$JAVA_EXTRACT"

  EXTRACTED_JAVA_DIR="$(find "$JAVA_EXTRACT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -print \
    | head -n 1)"

  if [ -z "$EXTRACTED_JAVA_DIR" ]; then

    echo
    echo "ERROR: Could not locate extracted JDK directory."
    find "$JAVA_EXTRACT" -maxdepth 3 -print || true
    exit 1

  fi

  rm -rf "$JAVA_DIR"

  mv \
    "$EXTRACTED_JAVA_DIR" \
    "$JAVA_DIR"

  rm -rf "$JAVA_EXTRACT"
  rm -f "$JAVA_TMP"

  echo
  echo "  [+] Java installed at:"
  echo "      $JAVA_DIR"

fi

# ------------------------------------------------------------------------------
# Verify our downloaded Java.
# ------------------------------------------------------------------------------

if [ ! -x "$JAVA_DIR/bin/java" ]; then

  echo
  echo "ERROR: Downloaded Java installation is missing:"
  echo "$JAVA_DIR/bin/java"

  find "$JAVA_DIR" \
    -maxdepth 3 \
    -type f \
    -name java \
    -print \
    2>/dev/null \
    || true

  exit 1

fi

# ------------------------------------------------------------------------------
# Force the workflow to use our downloaded JDK.
# ------------------------------------------------------------------------------

export JAVA_HOME="$JAVA_DIR"
export PATH="$JAVA_HOME/bin:$PATH"

hash -r 2>/dev/null || true

echo
echo "Java configuration:"
echo "  JAVA_HOME=$JAVA_HOME"
echo "  JAVA_BIN=$JAVA_HOME/bin/java"

echo
echo "Java version:"

"$JAVA_HOME/bin/java" -version 2>&1 | head -n 4

# ------------------------------------------------------------------------------
# Export to later GitHub Actions steps.
# ------------------------------------------------------------------------------

if [ -n "${GITHUB_ENV:-}" ]; then

  {
    echo "JAVA_HOME=$JAVA_HOME"
    echo "PATH=$JAVA_HOME/bin:$PATH"
  } >> "$GITHUB_ENV"

  echo
  echo "  [+] JAVA_HOME exported through GITHUB_ENV."

fi

# ==============================================================================
# PYTHON
# ==============================================================================

echo
echo "==> [SETUP] Installing Python helper packages..."

python3 -m pip install \
  --break-system-packages \
  --upgrade \
  pip \
  setuptools \
  wheel \
  2>/dev/null \
  || \
python3 -m pip install \
  --upgrade \
  pip \
  setuptools \
  wheel

python3 -m pip install \
  --break-system-packages \
  "protobuf==3.20.*" \
  requests \
  gdown \
  2>/dev/null \
  || \
python3 -m pip install \
  "protobuf==3.20.*" \
  requests \
  gdown

echo "  [+] protobuf 3.20.x installed."
echo "  [+] requests installed."
echo "  [+] gdown installed."

# ==============================================================================
# PAYLOAD-DUMPER-GO
# ==============================================================================

echo
echo "==> [SETUP] Installing payload-dumper-go..."

if ! command -v payload-dumper-go >/dev/null 2>&1; then

  PDGO_VERSION="2.1.0"

  PDGO_SHA256="bbbb53a71955c69272afdef7bc7e83a1bb1770f453d0c21dcaf61a3ba0463c11"

  PDGO_URL="https://github.com/ssut/payload-dumper-go/releases/download/${PDGO_VERSION}/payload-dumper-go_${PDGO_VERSION}_linux_amd64.tar.gz"

  echo "  -> Downloading payload-dumper-go v${PDGO_VERSION}..."

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 5 \
    --connect-timeout 30 \
    --max-time 180 \
    "$PDGO_URL" \
    -o /tmp/payload-dumper-go.tar.gz

  echo
  echo "  -> Verifying SHA256..."

  printf '%s  %s\n' \
    "$PDGO_SHA256" \
    /tmp/payload-dumper-go.tar.gz \
    | sha256sum --check --status

  echo "  [+] SHA256 verification passed."

  tar \
    -xzf \
    /tmp/payload-dumper-go.tar.gz \
    -C /tmp/

  sudo mv \
    /tmp/payload-dumper-go \
    "$BIN_DIR/"

  sudo chmod \
    +x \
    "$BIN_DIR/payload-dumper-go"

  rm -f \
    /tmp/payload-dumper-go.tar.gz \
    /tmp/payload-dumper-go

  echo "  [+] payload-dumper-go installed."

else

  echo "  [+] payload-dumper-go already present."

fi

# ==============================================================================
# LPUNPACK
# ==============================================================================

echo
echo "==> [SETUP] Ensuring lpunpack.py is available..."

mkdir -p "$TOOLS_DIR"

if [ ! -f "$TOOLS_DIR/lpunpack.py" ]; then

  LPUNPACK_COMMIT="c59b8f3b069c5a8aa438a049fa4a091177172434"

  LPUNPACK_GIT_BLOB_SHA="9671d1d731d28f04f0d65dad0dacb2110da87029"

  LPUNPACK_URL="https://raw.githubusercontent.com/unix3dgforce/lpunpack/$LPUNPACK_COMMIT/lpunpack.py"

  echo "  -> Downloading pinned lpunpack.py..."

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 5 \
    --connect-timeout 30 \
    --max-time 60 \
    "$LPUNPACK_URL" \
    -o "$TOOLS_DIR/lpunpack.py"

  ACTUAL_HASH="$(git hash-object "$TOOLS_DIR/lpunpack.py")"

  if [ "$ACTUAL_HASH" != "$LPUNPACK_GIT_BLOB_SHA" ]; then

    echo
    echo "ERROR: lpunpack.py checksum mismatch."
    echo
    echo "Expected:"
    echo "$LPUNPACK_GIT_BLOB_SHA"
    echo
    echo "Actual:"
    echo "$ACTUAL_HASH"

    rm -f "$TOOLS_DIR/lpunpack.py"

    exit 1

  fi

  chmod +x "$TOOLS_DIR/lpunpack.py"

  echo "  [+] lpunpack.py checksum verified."

else

  echo "  [+] lpunpack.py already present in tools/."

fi

# ==============================================================================
# ANDROID FILESYSTEM TOOLS
# ==============================================================================

echo
echo "==> [SETUP] Installing verified Android filesystem tools..."

E2FSDROID_SCRIPT="$SCRIPT_DIR/install_e2fsdroid.sh"

if [ ! -f "$E2FSDROID_SCRIPT" ]; then

  echo
  echo "ERROR: Missing:"
  echo "$E2FSDROID_SCRIPT"

  exit 1

fi

chmod +x "$E2FSDROID_SCRIPT"

bash "$E2FSDROID_SCRIPT"

# ==============================================================================
# FINAL TOOL VERIFICATION
# ==============================================================================

echo
echo "============================================================"
echo "VERIFYING INSTALLED TOOLS"
echo "============================================================"

REQUIRED_COMMANDS=(
  aria2c
  bc
  curl
  e2fsck
  lz4
  7z
  rsync
  unzip
  zip
  zstd
  python3
  gdown
  payload-dumper-go
)

MISSING=0

for command_name in "${REQUIRED_COMMANDS[@]}"; do

  if command -v "$command_name" >/dev/null 2>&1; then

    echo "  [OK] $command_name"

  else

    echo "  [MISSING] $command_name"
    MISSING=1

  fi

done

echo

# ------------------------------------------------------------------------------
# Explicit Java verification.
# ------------------------------------------------------------------------------

if [ -x "$JAVA_HOME/bin/java" ]; then

  echo "  [OK] java"
  echo "  JAVA_HOME=$JAVA_HOME"

  "$JAVA_HOME/bin/java" -version 2>&1 | head -n 3

else

  echo "  [MISSING] java"
  MISSING=1

fi

echo

if [ "$MISSING" != "0" ]; then

  echo "ERROR: One or more required tools are missing."
  exit 1

fi

# ==============================================================================
# COMPLETE
# ==============================================================================

echo
echo "============================================================"
echo "DEPENDENCY SETUP COMPLETE"
echo "============================================================"

echo
echo "Environment:"
echo "  JAVA_HOME=$JAVA_HOME"
echo "  Java:"
"$JAVA_HOME/bin/java" -version 2>&1 | head -n 3

echo
echo "All required GSI porting dependencies are ready."
echo "============================================================"
