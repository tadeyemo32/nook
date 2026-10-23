#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

sh scripts/bundle.sh
sh scripts/verify-bundle.sh

pkill -x Nook || true
while pgrep -x Nook >/dev/null; do sleep 0.2; done
sleep 1
rm -rf /Applications/Nook.app
ditto build/Nook.app /Applications/Nook.app
open /Applications/Nook.app

echo "Installed Nook $(cat VERSION) to /Applications"
