#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

APP="build/Nook.app"
XPC="$APP/Contents/XPCServices/NookHelper.xpc"

plutil -lint "$APP/Contents/Info.plist" "$XPC/Contents/Info.plist"

id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$XPC/Contents/Info.plist")"
case "$id" in
    com.apple.*) ;;
    *) echo "helper bundle id must start with com.apple. (got $id)" >&2; exit 1 ;;
esac
grep -q "\"$id\"" Sources/NookXPC/NookXPC.swift || {
    echo "helper bundle id $id doesn't match nookHelperServiceName" >&2; exit 1
}

for key in NSAudioCaptureUsageDescription NSBluetoothAlwaysUsageDescription NSCameraUsageDescription \
           NSCalendarsFullAccessUsageDescription NSLocationUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null
done

test -x "$APP/Contents/MacOS/Nook"
test -x "$XPC/Contents/MacOS/NookHelper"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Bundle OK"
