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
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "built $APP"
echo "run:   open $APP"
