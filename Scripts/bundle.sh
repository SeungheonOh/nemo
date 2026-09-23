#!/bin/sh
# Build the C runtime as a static library, the Swift app in release mode, and assemble NemoDictate.app.
set -eu
cd "$(dirname "$0")/.."
make -C ../nemoasr-c lib
swift build -c release --product NemoDictate
APP="build/NemoDictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NemoDictate "$APP/Contents/MacOS/NemoDictate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a real identity when one is available: macOS ties the Accessibility permission to the
# code signature, and an ad-hoc signature changes on every build, so the permission would be lost
# each time. Override with CODESIGN_ID="Developer ID Application: ..." or CODESIGN_ID=- for ad hoc.
IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" && echo "signed as: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
  echo "warning: ad-hoc signature; Accessibility access will have to be re-granted after every rebuild"
fi
echo "built $APP"
echo "run:   open $APP"
