#!/usr/bin/env bash
# Sign Sparkle's nested executables from the inside out, then the app itself.
set -euo pipefail

#
# Identity: DESKDRAW_SIGN_IDENTITY if set ("-" for ad hoc), otherwise the self-signed "Desk Draw"
# certificate from scripts/create-signing-cert.sh when this Mac has it, otherwise ad hoc.
# A certificate keeps the app's identity the same across updates, so macOS keeps its
# Screen Recording permission; an ad-hoc signature changes with every build.
APP="${1:?Usage: sign-app.sh /path/to/Desk Draw.app}"
LOCAL_NAME="Desk Draw"
# By fingerprint, so a similarly named certificate can never be picked instead.
LOCAL_IDENTITY=$(security find-identity -p codesigning | awk -v name="\"$LOCAL_NAME\"" 'index($0, name) { print $2; exit }')
if [[ -n "${DESKDRAW_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$DESKDRAW_SIGN_IDENTITY"
elif [[ -n "$LOCAL_IDENTITY" ]]; then
  IDENTITY="$LOCAL_IDENTITY"
else
  IDENTITY="-"
  echo "No \"$LOCAL_NAME\" signing certificate; signing ad hoc (see docs/RELEASING.md)." >&2
fi
SIGN_ARGS=(--force --sign "$IDENTITY")
# Hardened runtime and a secure timestamp are for Developer ID builds that get notarized. The
# self-signed certificate has no Team ID, so the hardened runtime would refuse to load Sparkle.
if [[ "$IDENTITY" != "-" && "$IDENTITY" != "$LOCAL_IDENTITY" ]]; then
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
