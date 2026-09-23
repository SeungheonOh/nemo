#!/bin/sh
# Release build: the app with the model inside, signed, optionally notarised, packed as DMG and zip.
#
#   Scripts/release.sh [VERSION] [--publish]
#
#   VERSION          defaults to the git tag (git describe, leading "v" stripped)
#   MODEL_DIR        directory with config.json and model.safetensors (default: the Hugging Face
#                    snapshot of mlx-community/nemotron-3.5-asr-streaming-0.6b)
#   CODESIGN_ID      signing identity (see Scripts/sign.sh); a Developer ID gets the hardened runtime
#   NOTARY_PROFILE   notarytool keychain profile (xcrun notarytool store-credentials); when set, the
#                    app is notarised and stapled, which needs a Developer ID signature
#   --publish        create a GitHub release "vVERSION" with gh and upload the artefacts
set -eu
cd "$(dirname "$0")/.."
VERSION=""
PUBLISH=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    *) VERSION="$a" ;;
  esac
done
[ -n "$VERSION" ] || VERSION="$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')"

if [ -z "${MODEL_DIR:-}" ]; then
  for d in "$HOME"/.cache/huggingface/hub/models--mlx-community--nemotron-3.5-asr-streaming-0.6b/snapshots/*/; do
    [ -f "$d/model.safetensors" ] && MODEL_DIR="$d" && break
  done
fi
[ -n "${MODEL_DIR:-}" ] && [ -f "$MODEL_DIR/model.safetensors" ] || { echo "model not found; set MODEL_DIR" >&2; exit 1; }

echo "== NemoDictate $VERSION"
VERSION="$VERSION" SKIP_SIGN=1 Scripts/bundle.sh >/dev/null
APP="build/NemoDictate.app"

echo "== adding the model from $MODEL_DIR"
mkdir -p "$APP/Contents/Resources/model"
cp -L "$MODEL_DIR/config.json" "$MODEL_DIR/model.safetensors" "$APP/Contents/Resources/model/"
[ -f "$MODEL_DIR/README.md" ] && cp -L "$MODEL_DIR/README.md" "$APP/Contents/Resources/model/README.md"

echo "== signing"
Scripts/sign.sh "$APP"
codesign --verify --strict "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "== notarising"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "== packaging"
mkdir -p dist
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/NemoDictate-$VERSION.dmg"
ZIP="dist/NemoDictate-$VERSION.zip"
rm -f "$DMG" "$ZIP"
hdiutil create -volname "NemoDictate" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "NemoDictate-$VERSION.dmg" "NemoDictate-$VERSION.zip" > "NemoDictate-$VERSION.sha256")
ls -la dist/NemoDictate-"$VERSION".*

if [ "$PUBLISH" = "1" ]; then
  git remote get-url origin >/dev/null 2>&1 || { echo "no git remote 'origin': push this repository to GitHub first" >&2; exit 1; }
  echo "== publishing v$VERSION"
  gh release create "v$VERSION" "$DMG" "$ZIP" "dist/NemoDictate-$VERSION.sha256" --title "NemoDictate $VERSION" --generate-notes
fi
