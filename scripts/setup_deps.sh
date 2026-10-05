
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
# Older package names:
#
#   liblz4-tool  -> lz4
#   p7zip-full   -> 7zip
#   p7zip-rar    -> 7zip
#
# We intentionally do not request the obsolete package names.
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
# JAVA
# ==============================================================================

echo
echo "==> [SETUP] Checking Java..."

JAVA_BIN=""

# ------------------------------------------------------------------------------
# First: check normal PATH.
# ------------------------------------------------------------------------------

if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(command -v java)"
fi

# ------------------------------------------------------------------------------
# Second: search standard JVM installation directories.
#
# This handles cases where apt installed OpenJDK successfully but the current
# shell does not have /usr/lib/jvm/.../bin in PATH.
# ------------------------------------------------------------------------------

if [ -z "$JAVA_BIN" ]; then

  for candidate in \
    /usr/lib/jvm/*/bin/java \
    /usr/lib/jvm/*/jre/bin/java
  do

    if [ -x "$candidate" ]; then
      JAVA_BIN="$candidate"
      break
    fi

  done

fi

# ------------------------------------------------------------------------------
# Third: install OpenJDK if it truly isn't present.
# ------------------------------------------------------------------------------

if [ -z "$JAVA_BIN" ]; then

  echo "  -> Java not found."
  echo "  -> Installing OpenJDK..."

  JAVA_INSTALLED=0

  # Prefer Java 17.
  if apt-cache show openjdk-17-jdk >/dev/null 2>&1; then

    echo "  -> Installing openjdk-17-jdk..."

    if sudo apt-get install \
      -y \
      -qq \
      --no-install-recommends \
      openjdk-17-jdk; then

      JAVA_INSTALLED=1

    fi

  fi

  # Fall back to Java 21.
  if [ "$JAVA_INSTALLED" != "1" ] \
    && apt-cache show openjdk-21-jdk >/dev/null 2>&1; then

    echo "  -> Installing openjdk-21-jdk..."

    if sudo apt-get install \
      -y \
      -qq \
      --no-install-recommends \
      openjdk-21-jdk; then

      JAVA_INSTALLED=1

    fi

  fi

  if [ "$JAVA_INSTALLED" != "1" ]; then

    echo
    echo "ERROR: Could not install OpenJDK 17 or 21."
    echo
    echo "Available OpenJDK packages:"
    apt-cache search '^openjdk-[0-9]+-jdk$' || true

    exit 1

  fi

  # Refresh Bash's command cache after apt installation.
  hash -r 2>/dev/null || true

fi

# ------------------------------------------------------------------------------
# Locate Java again after installation.
# ------------------------------------------------------------------------------

JAVA_BIN=""

if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(command -v java)"
fi

if [ -z "$JAVA_BIN" ]; then

  for candidate in \
    /usr/lib/jvm/*/bin/java \
    /usr/lib/jvm/*/jre/bin/java
  do

    if [ -x "$candidate" ]; then
      JAVA_BIN="$candidate"
      break
    fi

  done

fi

# ------------------------------------------------------------------------------
# Hard failure if Java installation apparently succeeded but no binary exists.
# ------------------------------------------------------------------------------

if [ -z "$JAVA_BIN" ]; then

  echo
  echo "ERROR: OpenJDK installation completed, but java could not be located."
  echo
  echo "JVM directories:"
  ls -la /usr/lib/jvm/ 2>/dev/null || true

  echo
  echo "Java binaries:"
  find /usr/lib/jvm \
    -type f \
    -name java \
    -perm -111 \
    -print \
    2>/dev/null \
    || true

  exit 1

fi

# ------------------------------------------------------------------------------
# Resolve the real Java binary.
# ------------------------------------------------------------------------------

JAVA_BIN_REAL="$(realpath "$JAVA_BIN")"

# /usr/lib/jvm/java-17-openjdk-amd64/bin/java
#                         ^^^^^^^^^^^^^^^^^^^^^
# JAVA_HOME should therefore be two directories above java.
JAVA_HOME="$(dirname "$(dirname "$JAVA_BIN_REAL")")"

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

# ------------------------------------------------------------------------------
# Make Java available to later GitHub Actions steps.
# ------------------------------------------------------------------------------

if [ -n "${GITHUB_ENV:-}" ]; then

  {
    echo "JAVA_HOME=$JAVA_HOME"
    echo "PATH=$JAVA_HOME/bin:$PATH"
  } >> "$GITHUB_ENV"

fi

# Refresh Bash command lookup again.
hash -r 2>/dev/null || true

echo
echo "Java:"
echo "  JAVA_HOME=$JAVA_HOME"
echo "  JAVA_BIN=$JAVA_BIN_REAL"

"$JAVA_HOME/bin/java" -version 2>&1 | head -n 3

echo
echo "  [+] Java configured successfully."

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

# Explicit Java verification.
if command -v java >/dev/null 2>&1; then

  echo "  [OK] java"
  java -version 2>&1 | head -n 3

else

  echo "  [MISSING] java"
  MISSING=1

fi

echo

if [ "$MISSING" != "0" ]; then

  echo "ERROR: One or more required tools are missing."
  exit 1

fi

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
echo"============================================================"
