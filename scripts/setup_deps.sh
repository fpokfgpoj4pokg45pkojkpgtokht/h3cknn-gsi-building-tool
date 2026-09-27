#!/usr/bin/env bash
# ==============================================================================
# setup_deps.sh - Install dependencies for GSI Porting & Source Building
# ==============================================================================

set -eo pipefail

echo "==> [SETUP] Updating package indices..."
sudo apt-get update -qq

echo "==> [SETUP] Installing required system utilities & build packages..."
sudo apt-get install -y -qq --no-install-recommends \
  aria2 \
  bc \
  bison \
  brotli \
  build-essential \
  ccache \
  curl \
  e2fsprogs \
  erofs-utils \
  flex \
  g++-multilib \
  gcc-multilib \
  git \
  gnupg \
  gperf \
  imagemagick \
  lib32readline-dev \
  lib32z1-dev \
  liblz4-tool \
  libncurses6 \
  libncurses-dev \
  libssl-dev \
  libxml2 \
  libxml2-utils \
  lzop \
  openjdk-11-jdk \
  p7zip-full \
  p7zip-rar \
  python3 \
  python3-pip \
  rsync \
  schedtool \
  squashfs-tools \
  tar \
  unzip \
  wget \
  xsltproc \
  zip \
  zlib1g-dev \
  zstd \
  android-sdk-libsparse-utils \
  android-libbase-dev

echo "==> [SETUP] Installing Python helper packages..."
python3 -m pip install --break-system-packages --upgrade pip setuptools wheel 2>/dev/null \
  || python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install --break-system-packages "protobuf==3.20.*" requests gdown 2>/dev/null \
  || python3 -m pip install "protobuf==3.20.*" requests gdown
echo "  [+] gdown (Google Drive downloader) installed."

BIN_DIR="/usr/local/bin"
TOOLS_DIR="$(dirname "$(realpath "$0")")/../tools"

echo "==> [SETUP] Installing payload-dumper-go..."
if ! command -v payload-dumper-go &>/dev/null; then
  # Pin the extractor so a changed upstream release cannot silently alter
  # payload parsing or produce a different system image on a later build.
  # The checksum is the GitHub release asset digest for this exact archive.
  PDGO_VERSION="2.1.0"
  PDGO_SHA256="bbbb53a71955c69272afdef7bc7e83a1bb1770f453d0c21dcaf61a3ba0463c11"
  PDGO_URL="https://github.com/ssut/payload-dumper-go/releases/download/${PDGO_VERSION}/payload-dumper-go_${PDGO_VERSION}_linux_amd64.tar.gz"
  echo "  -> Downloading payload-dumper-go v${PDGO_VERSION}..."
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "$PDGO_URL" -o /tmp/payload-dumper-go.tar.gz
  printf '%s  %s\n' "$PDGO_SHA256" /tmp/payload-dumper-go.tar.gz \
    | sha256sum --check --status
  tar -xzf /tmp/payload-dumper-go.tar.gz -C /tmp/
  sudo mv /tmp/payload-dumper-go "$BIN_DIR/"
  sudo chmod +x "$BIN_DIR/payload-dumper-go"
  rm -f /tmp/payload-dumper-go*
  echo "  [+] payload-dumper-go installed."
else
  echo "  [+] payload-dumper-go already present."
fi

echo "==> [SETUP] Ensuring lpunpack.py is available..."
# BUG FIX: Previous version fetched from ErfanGSIs which is 404.
# Now uses the repository's checked-in copy, avoiding a moving remote script.
if [ ! -f "$TOOLS_DIR/lpunpack.py" ]; then
  LPUNPACK_COMMIT="c59b8f3b069c5a8aa438a049fa4a091177172434"
  LPUNPACK_GIT_BLOB_SHA="9671d1d731d28f04f0d65dad0dacb2110da87029"
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 60 \
    "https://raw.githubusercontent.com/unix3dgforce/lpunpack/$LPUNPACK_COMMIT/lpunpack.py" \
    -o "$TOOLS_DIR/lpunpack.py"
  [ "$(git hash-object "$TOOLS_DIR/lpunpack.py")" = "$LPUNPACK_GIT_BLOB_SHA" ]
  echo "  [+] lpunpack.py downloaded to tools/."
else
  echo "  [+] lpunpack.py already present in tools/."
fi

echo "==> [SETUP] Installing verified Android filesystem tools..."
bash "$(dirname "$(realpath "$0")")/install_e2fsdroid.sh"

echo "==> [SETUP] Environment configured successfully."
