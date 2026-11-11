#!/usr/bin/env bash
# Run the tools matching the Sparkle version pinned in Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.10.1"
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
TOOLS="build/Sparkle-$VERSION"

case "${1:-}" in
  generate_keys|generate_appcast|sign_update) TOOL="$1"; shift ;;
  *) echo "Usage: $0 {generate_keys|generate_appcast|sign_update} [arguments...]" >&2; exit 1 ;;
esac

if [[ ! -x "$TOOLS/bin/$TOOL" ]]; then
  mkdir -p build
  STAGING=$(mktemp -d build/.sparkle-tools.XXXXXXXX)
  trap 'rm -rf "$STAGING"' EXIT
  curl --fail --location --retry 2 --max-time 180 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    --output "$STAGING/Sparkle.tar.xz"
  printf '%s  %s\n' "$SHA256" "$STAGING/Sparkle.tar.xz" | shasum -a 256 --check >&2
  mkdir "$STAGING/unpacked"
  tar -xf "$STAGING/Sparkle.tar.xz" -C "$STAGING/unpacked"
  mv "$STAGING/unpacked" "$TOOLS"
  rm -rf "$STAGING"
  trap - EXIT
fi

if [[ "$TOOL" == "generate_keys" ]]; then
  exec "$TOOLS/bin/$TOOL" "$@"
fi

ACCOUNT="de.haga-welt.DeskDraw"
EXPECT_ACCOUNT=false
for argument in "$@"; do
  if [[ "$EXPECT_ACCOUNT" == true ]]; then ACCOUNT="$argument"; EXPECT_ACCOUNT=false; fi
  case "$argument" in
    --account) EXPECT_ACCOUNT=true ;;
    --help|-h|--ed-key-file|-f) exec "$TOOLS/bin/$TOOL" "$@" ;;
  esac
done

# generate_keys is already trusted to access this key. Give the other tools a temporary
# private file rather than granting each binary permanent access to the login Keychain.
KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/desk-draw-signing.XXXXXXXX")
trap 'rm -rf "$KEY_DIR"' EXIT
umask 077
"$TOOLS/bin/generate_keys" --account "$ACCOUNT" -p >/dev/null
"$TOOLS/bin/generate_keys" --account "$ACCOUNT" -x "$KEY_DIR/private.key" >/dev/null
chmod 600 "$KEY_DIR/private.key"
"$TOOLS/bin/$TOOL" --ed-key-file "$KEY_DIR/private.key" "$@"
