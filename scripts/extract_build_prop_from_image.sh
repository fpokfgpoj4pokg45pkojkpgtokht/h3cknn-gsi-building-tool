#!/usr/bin/env bash
# Extract a build.prop from a raw or sparse ext4/EROFS partition image.

set -Eeuo pipefail

INPUT_IMAGE="${1:-}"
OUTPUT_PROP="${2:-}"
WORK_DIR="${3:-$(pwd)}"

if [ -z "$INPUT_IMAGE" ] || [ ! -f "$INPUT_IMAGE" ] || [ -z "$OUTPUT_PROP" ]; then
  echo "Usage: extract_build_prop_from_image.sh <raw-or-sparse-image> <output-prop> [work-dir]" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT_PROP")" "$WORK_DIR"
RAW_IMAGE="$WORK_DIR/.prop.raw.img"
UNSPARSE_IMAGE="$WORK_DIR/.prop.unsparse.img"
EXTRACT_DIR="$WORK_DIR/.prop.erofs"
cleanup() {
  rm -f -- "$RAW_IMAGE" "$UNSPARSE_IMAGE"
  rm -rf -- "$EXTRACT_DIR"
}
trap cleanup EXIT

cp -- "$INPUT_IMAGE" "$RAW_IMAGE"
IMAGE_MAGIC=$(od -An -tx1 -N4 "$RAW_IMAGE" 2>/dev/null | tr -d '[:space:]')
if [ "$IMAGE_MAGIC" = "3aff26ed" ]; then
  command -v simg2img >/dev/null 2>&1 || exit 1
  simg2img "$RAW_IMAGE" "$UNSPARSE_IMAGE"
  IMAGE="$UNSPARSE_IMAGE"
else
  IMAGE="$RAW_IMAGE"
fi

IMAGE_TYPE=$(file -b "$IMAGE" | tr '[:upper:]' '[:lower:]')
case "$IMAGE_TYPE" in
  *ext[234]*filesystem*)
    for path in \
      /build.prop \
      /etc/build.prop \
      /vendor/build.prop \
      /vendor/etc/build.prop \
      /system/build.prop \
      /system/system/build.prop; do
      if debugfs -R "dump -p $path $OUTPUT_PROP" "$IMAGE" >/dev/null 2>&1 \
        && [ -s "$OUTPUT_PROP" ]; then
        chmod 644 "$OUTPUT_PROP"
        echo "==> Extracted build.prop from $path"
        exit 0
      fi
      rm -f -- "$OUTPUT_PROP"
    done
    ;;
  *erofs*)
    command -v fsck.erofs >/dev/null 2>&1 || exit 1
    mkdir -p "$EXTRACT_DIR"
    fsck.erofs --extract="$EXTRACT_DIR" "$IMAGE" >/dev/null
    for path in \
      build.prop \
      etc/build.prop \
      vendor/build.prop \
      vendor/etc/build.prop \
      system/build.prop \
      system/system/build.prop; do
      if [ -s "$EXTRACT_DIR/$path" ]; then
        cp -- "$EXTRACT_DIR/$path" "$OUTPUT_PROP"
        chmod 644 "$OUTPUT_PROP"
        echo "==> Extracted build.prop from /$path"
        exit 0
      fi
    done
    ;;
esac

rm -f -- "$OUTPUT_PROP"
exit 1
