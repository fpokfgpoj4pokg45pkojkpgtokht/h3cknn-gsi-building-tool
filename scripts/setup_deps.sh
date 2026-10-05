
#!/usr/bin/env bash
# ==============================================================================
# setup_deps.sh - Install dependencies for GSI Porting & Source Building
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOOLS_DIR="$SCRIPT_DIR/../tools"
BIN_DIR="/usr/local/bin"

echo
echo "============================================================"
echo "GSI PORTING DEPENDENCY SETUP"
echo "============================================================"

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
echo "==> [SETUP] Updating package indices..."

sudo apt-get update -qq

echo
echo "==> [SETUP] Installing required system utilities & build packages..."

# --------------------------------------------------------------------------
# Ubuntu package compatibility
#
# Ubuntu 26.x no longer provides some older package names:
#
#   liblz4-tool  -> lz4
#   p7zip-full   -> 7zip
#   p7zip-rar    -> 7zip
#
# libxml2 is also no longer used as a direct runtime package dependency by
# this script. The current Ubuntu XML runtime package is selected below.
# --------------------------------------------------------------------------

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

# --------------------------------------------------------------------------
# Optional/multilib packages
#
# These are useful on source-building environments but can be unavailable
# on some Ubuntu installations/architectures. Install them separately so
# one missing optional package does not make the entire dependency stage
# fail before the actual GSI tools are available.
# --------------------------------------------------------------------------

OPTIONAL_PACKAGES=(
  g++-multilib
  gcc-multilib
  lib32readline-dev
  lib32z1-dev
)

echo
echo "Required packages:"
printf '  - %s\n' "${APT_PACKAGES[@]}"

sudo apt-get install \
  -y \
  -qq \
  --no-install-recommends \
  "${APT_PACKAGES[@]}"

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

# --------------------------------------------------------------------------
# Java
# --------------------------------------------------------------------------

echo
echo "==> [SETUP] Checking Java..."

if command -v java >/dev/null 2>&1; then
  echo "  [+] Java already installed:"
  java -version 2>&1 | head -n 2
else

  echo "  -> Java not found."

  JAVA_PACKAGES=(
    openjdk-17-jdk
    openjdk-21-jdk
  )

  JAVA_INSTALLED=0

  for java_package in "${JAVA_PACKAGES[@]}"; do

    if apt-cache show "$java_package" >/dev/null 2>&1; then

      echo "  -> Installing $java_package..."

      if sudo apt-get install \
        -y \
        -qq \
        --no-install-recommends \
        "$java_package"; then

        JAVA_INSTALLED=1
        break

      fi

    fi

  done

  if [ "$JAVA_INSTALLED" != "1" ]; then
    echo
    echo "ERROR: Could not install a supported Java JDK."
    exit 1
  fi

fi

echo
echo "Java:"
java -version 2>&1 | head -n 3

# --------------------------------------------------------------------------
# Python
# --------------------------------------------------------------------------

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

# --------------------------------------------------------------------------
# payload-dumper-go
# --------------------------------------------------------------------------

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

# --------------------------------------------------------------------------
# lpunpack.py
# --------------------------------------------------------------------------

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

# --------------------------------------------------------------------------
# Android filesystem tools
# --------------------------------------------------------------------------

echo
echo "==> [SETUP] Installing verified Android filesystem tools..."

E2FSDROID_SCRIPT="$SCRIPT_DIR/install_e2fsdroid.sh"

if [ ! -f "$E2FSDROID_SCRIPT" ]; then
  echo "ERROR: Missing:"
  echo "$E2FSDROID_SCRIPT"
  exit 1
fi

chmod +x "$E2FSDROID_SCRIPT"

bash "$E2FSDROID_SCRIPT"

# --------------------------------------------------------------------------
# Verify important tools
# --------------------------------------------------------------------------

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

if [ "$MISSING" != "0" ]; then
  echo "ERROR: One or more required tools are missing."
  exit 1
fi

echo "============================================================"
echo "DEPENDENCY SETUP COMPLETE"
echo "============================================================"
