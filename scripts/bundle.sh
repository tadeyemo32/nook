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

# Shortcuts finds App Intents through metadata that only Xcode's build writes, so extract it here
# (needs full Xcode; without it the app just has no Shortcuts actions).
if xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    META="$(mktemp -d)"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    printf '%s\n' "$PWD"/Sources/Nook/*.swift > "$META/sources.txt"
    echo "$META/Nook.swiftconstvalues" > "$META/constvalues.txt"
    xcrun swiftc -typecheck -wmo -parse-as-library -module-name Nook -target arm64-apple-macos14.0 -sdk "$SDK" \
        -I "$BIN" -I "$BIN/Modules" "$PWD"/Sources/Nook/*.swift \
        -emit-const-values-path "$META/Nook.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$PWD/scripts/appintents-protocols.json"
    xcrun appintentsmetadataprocessor --quiet-warnings --output "$APP/Contents/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" --module-name Nook \
        --sdk-root "$SDK" --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
        --binary-file "$APP/Contents/MacOS/Nook" --source-file-list "$META/sources.txt" \
        --swift-const-vals-list "$META/constvalues.txt" >/dev/null
    rm -rf "$META"
fi
cp Support/NookHelper-Info.plist "$XPC/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $IDENTITY"

codesign --force --sign "$IDENTITY" "$XPC"
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Nook")) — run: open $APP"
