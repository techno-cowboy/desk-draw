#!/usr/bin/env bash
# Sign Sparkle's nested executables from the inside out, then the app itself.
set -euo pipefail

APP="${1:?Usage: sign-app.sh /path/to/Desk Draw.app}"
IDENTITY="${DESKDRAW_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp --options runtime)
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/Current"
for component in \
  "$SPARKLE_VERSION/Autoupdate" \
  "$SPARKLE_VERSION/Updater.app" \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE" \
  "$APP"; do
  codesign "${SIGN_ARGS[@]}" "$component"
done
codesign --verify --deep --strict "$APP"
