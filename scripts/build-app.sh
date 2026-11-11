#!/usr/bin/env bash
# Builds "build/Desk Draw.app". With --install, also copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Desk Draw.app"

if [[ -n "${1:-}" && "$1" != "--install" ]]; then
  echo "Usage: $0 [--install]" >&2
  exit 1
fi
if [[ -n "${DESKDRAW_NOTARY_PROFILE:-}" && "${DESKDRAW_SIGN_IDENTITY:--}" == "-" ]]; then
  echo "Notarization requires DESKDRAW_SIGN_IDENTITY (Developer ID Application)." >&2
  exit 1
fi

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/DeskDraw" "$APP/Contents/MacOS/DeskDraw"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
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

# Defaults to ad-hoc signing; set DESKDRAW_SIGN_IDENTITY for Developer ID releases.
./scripts/sign-app.sh "$APP"

if [[ -n "${DESKDRAW_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARCHIVE=$(mktemp build/.notarize.XXXXXXXX.zip)
  trap 'rm -f "$NOTARY_ARCHIVE"' EXIT
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ARCHIVE"
  xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$DESKDRAW_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x DeskDraw 2>/dev/null || true
  rm -rf "$HOME/Applications/Desk Draw.app"
  ditto "$APP" "$HOME/Applications/Desk Draw.app"
  open "$HOME/Applications/Desk Draw.app"
  echo "Installed to ~/Applications/Desk Draw.app and launched it"
fi
