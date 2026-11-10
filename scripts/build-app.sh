#!/usr/bin/env bash
# Builds "build/Desk Draw.app". With --install, also copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Desk Draw.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DeskDraw "$APP/Contents/MacOS/DeskDraw"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: render once, cache in build/.
if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. macOS ties the Screen Recording permission to it, so after
# a rebuild you may need to re-enable Desk Draw in System Settings.
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x DeskDraw 2>/dev/null || true
  rm -rf "$HOME/Applications/Desk Draw.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Desk Draw.app"
  echo "Installed to ~/Applications/Desk Draw.app and launched it"
fi
