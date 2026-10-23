#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi
swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

APP="build/Nook.app"
XPC="$APP/Contents/XPCServices/NookHelper.xpc"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS"

cp "$BIN/Nook" "$APP/Contents/MacOS/Nook"
cp Support/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat VERSION)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 0)" "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/NookHelper" "$XPC/Contents/MacOS/NookHelper"
cp Support/NookHelper-Info.plist "$XPC/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $IDENTITY"

codesign --force --sign "$IDENTITY" "$XPC"
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Nook")) — run: open $APP"
