#!/bin/bash
# Sign an assembled limpet.app with a Developer ID, inside-out, in Sparkle's
# documented order, with the hardened runtime and a secure timestamp (both
# required for notarization).
#
#   scripts/release/codesign_app.sh <limpet.app> <identity> [keychain]
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/codesign_app.sh).
#
# No entitlements are passed: limpet is not sandboxed and loads nothing at
# runtime that needs one. verify_signed_app.sh fails a release whose code
# carries any.
set -euo pipefail

APP="$1"
IDENTITY="$2"
KEYCHAIN="${3:-}"

SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
[ -n "$KEYCHAIN" ] && SIGN+=(--keychain "$KEYCHAIN")

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# The Xcode build phase removes Sparkle's XPC services and
# verify_signed_app.sh fails a bundle that still has them.
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
