#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. Scripts/model-source.sh
DEST="${1:-build/model-source}"
mkdir -p "$DEST"

download() {
  name="$1"
  url="$2"
  expected="$3"
  target="$DEST/$name"
  if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$expected" ]; then
    return
  fi
  temporary="$(mktemp "$DEST/.download.XXXXXXXX")"
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  curl --fail --location --retry 3 --retry-all-errors --output "$temporary" "$url"
  actual="$(shasum -a 256 "$temporary" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { echo "checksum mismatch for $name: $actual" >&2; exit 1; }
  mv "$temporary" "$target"
  trap - EXIT HUP INT TERM
}

base="https://huggingface.co/$MODEL_REPOSITORY/resolve/$MODEL_REVISION"
download config.json "$base/config.json" "$CONFIG_SHA256"
download model.safetensors "$base/model.safetensors" "$MODEL_SHA256"
download README.md "$base/README.md" "$MODEL_README_SHA256"
download LICENSE.pdf "$MODEL_LICENSE_URL" "$MODEL_LICENSE_SHA256"
echo "$DEST"
