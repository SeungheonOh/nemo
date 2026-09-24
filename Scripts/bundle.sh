#!/bin/sh
# Development build: the C runtime as a static library, the app in release mode, build/Nemo.app.
# The model is read from the Hugging Face cache; Scripts/release.sh puts it inside the app.
#   VERSION=1.2   sets CFBundleShortVersionString (default: whatever Info.plist says)
#   SKIP_SIGN=1   leave the bundle unsigned (release.sh signs after adding the model)
set -eu
cd "$(dirname "$0")/.."
make -C ../nemoasr-c lib
swift build -c release --product NemoDictate
APP="build/Nemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NemoDictate "$APP/Contents/MacOS/NemoDictate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then
  swift Scripts/make_icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[ "${SKIP_SIGN:-0}" = "1" ] || Scripts/sign.sh "$APP"
echo "built $APP"
echo "run:   open $APP"
