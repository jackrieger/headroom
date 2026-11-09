#!/bin/zsh
# Builds Headroom.app into build/. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/Headroom" Sources/*.swift
# A stable identity keeps the login item registered across rebuilds; ad-hoc changes it every build
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Headroom && sleep 1 || true
  rm -rf /Applications/Headroom.app
  ditto "$APP" /Applications/Headroom.app
  open /Applications/Headroom.app
  echo "Installed and launched /Applications/Headroom.app"
fi
