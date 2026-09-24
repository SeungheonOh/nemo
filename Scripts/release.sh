#!/bin/sh
# Release build: the app with a compressed model inside, signed, optionally notarised, packed as DMG and zip.
#
#   Scripts/release.sh [VERSION] [--publish]
#
#   VERSION          defaults to the git tag (git describe, leading "v" stripped)
#   MODEL_DIR        directory with config.json and model.safetensors (default: the Hugging Face
#                    snapshot of mlx-community/nemotron-3.5-asr-streaming-0.6b)
#   CODESIGN_ID      signing identity (see Scripts/sign.sh); a Developer ID gets the hardened runtime
#   NOTARY_PROFILE   notarytool keychain profile (xcrun notarytool store-credentials); when set, the
#                    app is notarised and stapled, which needs a Developer ID signature
#   NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER_ID  App Store Connect API key alternative
#   --publish        create a GitHub release "vVERSION" with gh and upload the artefacts
set -eu
cd "$(dirname "$0")/.."
. Scripts/model-source.sh
VERSION=""
PUBLISH=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    *) VERSION="$a" ;;
  esac
done
[ -n "$VERSION" ] || VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//')"
case "$VERSION" in
  *[!0-9.]*|.*|*..*|*.) echo "version must be numeric, such as 1.2.3" >&2; exit 1 ;;
esac
[ "$(printf '%s' "$VERSION" | awk -F. '{print NF}')" = 3 ] || { echo "version must have three components" >&2; exit 1; }
if [ "$PUBLISH" = "1" ]; then
  git remote get-url origin >/dev/null 2>&1 || { echo "no git remote 'origin'" >&2; exit 1; }
  TAG_COMMIT="$(git rev-list -n 1 "v$VERSION" 2>/dev/null || true)"
  [ -n "$TAG_COMMIT" ] && [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ] || { echo "v$VERSION must tag the current commit" >&2; exit 1; }
fi
NOTARIZE=0
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARIZE=1
elif [ -n "${NOTARY_KEY_FILE:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-}" ]; then
  [ -n "${NOTARY_KEY_FILE:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] || { echo "all three NOTARY_KEY variables are required" >&2; exit 1; }
  NOTARIZE=1
fi
if [ "$NOTARIZE" = "1" ]; then
  case "${CODESIGN_ID:-}" in
    "Developer ID Application:"*) ;;
    "") security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application:' || { echo "Developer ID Application certificate required for notarization" >&2; exit 1; } ;;
    *) echo "Developer ID Application certificate required for notarization" >&2; exit 1 ;;
  esac
fi
if [ "$PUBLISH" = "1" ] && [ "$NOTARIZE" != "1" ]; then
  echo "public releases require Developer ID signing and notarization credentials" >&2
  exit 1
fi

if [ -z "${MODEL_DIR:-}" ]; then
  for d in "$HOME"/.cache/huggingface/hub/models--mlx-community--nemotron-3.5-asr-streaming-0.6b/snapshots/*/; do
    [ -f "$d/model.safetensors" ] && MODEL_DIR="$d" && break
  done
fi
[ -n "${MODEL_DIR:-}" ] && [ -f "$MODEL_DIR/model.safetensors" ] || { echo "model not found; set MODEL_DIR or run Scripts/fetch-model.sh" >&2; exit 1; }
[ "$(shasum -a 256 "$MODEL_DIR/model.safetensors" | awk '{print $1}')" = "$MODEL_SHA256" ] || { echo "model checksum mismatch" >&2; exit 1; }
[ "$(shasum -a 256 "$MODEL_DIR/config.json" | awk '{print $1}')" = "$CONFIG_SHA256" ] || { echo "config checksum mismatch" >&2; exit 1; }

LICENSE="build/model-license.pdf"
mkdir -p build
if [ -f "$MODEL_DIR/LICENSE.pdf" ]; then
  cp -L "$MODEL_DIR/LICENSE.pdf" "$LICENSE"
elif [ ! -f "$LICENSE" ]; then
  curl --fail --location --retry 3 --retry-all-errors --output "$LICENSE" "$MODEL_LICENSE_URL"
fi
[ "$(shasum -a 256 "$LICENSE" | awk '{print $1}')" = "$MODEL_LICENSE_SHA256" ] || { echo "model license checksum mismatch" >&2; exit 1; }

echo "== Nemo $VERSION"
VERSION="$VERSION" SKIP_SIGN=1 Scripts/bundle.sh >/dev/null
APP="build/Nemo.app"

echo "== adding the model from $MODEL_DIR"
mkdir -p "$APP/Contents/Resources/model"
cp -L "$MODEL_DIR/config.json" "$APP/Contents/Resources/model/"
[ -f "$MODEL_DIR/README.md" ] && cp -L "$MODEL_DIR/README.md" "$APP/Contents/Resources/model/README.md"
cp "$LICENSE" "$APP/Contents/Resources/model/LICENSE.pdf"
cp Resources/ModelNOTICE.txt "$APP/Contents/Resources/model/NOTICE.txt"
cat > "$APP/Contents/Resources/model/manifest.json" <<EOF
{"modelSHA256":"$MODEL_SHA256","modelBytes":$MODEL_BYTES,"configSHA256":"$CONFIG_SHA256","revision":"$MODEL_REVISION"}
EOF
compression_tool -encode -a lzma -i "$MODEL_DIR/model.safetensors" -o "$APP/Contents/Resources/model/model.safetensors.xz"
[ "$(compression_tool -decode -a lzma -i "$APP/Contents/Resources/model/model.safetensors.xz" | shasum -a 256 | awk '{print $1}')" = "$MODEL_SHA256" ] || { echo "compressed model round-trip failed" >&2; exit 1; }

echo "== signing"
Scripts/sign.sh "$APP"
codesign --verify --strict "$APP"

notarize() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${NOTARY_KEY_FILE:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  fi
}

if [ "$NOTARIZE" = "1" ]; then
  echo "== notarising"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  notarize build/notarize.zip
  xcrun stapler staple "$APP"
fi

echo "== packaging"
mkdir -p dist
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Nemo-$VERSION.dmg"
ZIP="dist/Nemo-$VERSION.zip"
rm -f "$DMG" "$ZIP"
hdiutil create -volname "Nemo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ "$NOTARIZE" = "1" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "Nemo-$VERSION.dmg" "Nemo-$VERSION.zip" > "Nemo-$VERSION.sha256")
ls -la dist/Nemo-"$VERSION".*

if [ "$PUBLISH" = "1" ]; then
  echo "== publishing v$VERSION"
  gh release create "v$VERSION" "$DMG" "$ZIP" "dist/Nemo-$VERSION.sha256" --verify-tag --title "Nemo $VERSION" --generate-notes
fi
