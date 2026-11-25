#!/bin/sh
# Build Govee Screen.app (ad-hoc signed) into macos/build/.
set -eu
cd "$(dirname "$0")"

swift build -c release
APP="build/Govee Screen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GoveeScreen "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
