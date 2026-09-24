#!/bin/sh
# Sign an app bundle. macOS ties the Accessibility permission to the code signature, and an ad-hoc
# signature changes on every build, so a real identity is used whenever one is available:
#   Developer ID Application  -> hardened runtime + timestamp (notarisable, for distribution)
#   Apple Development         -> plain signature (stable across rebuilds on this Mac)
# Override with CODESIGN_ID="..." (or CODESIGN_ID=- for ad hoc).
set -eu
APP="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$HERE/../Resources/NemoDictate.entitlements"
IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; found=1; exit } /Apple Development/ { if (development == "") development=$2 } END { if (!found) print development }')}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
  echo "warning: ad-hoc signature; Accessibility access will have to be re-granted after every rebuild"
  exit 0
fi
case "$IDENTITY" in
  "Developer ID"*) codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" --timestamp "$APP" ;;
  *)               codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$APP" ;;
esac
echo "signed as: $IDENTITY"
