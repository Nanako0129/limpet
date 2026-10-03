#!/bin/bash
# Assert that a limpet.app is what a release must ship: Developer ID signed by
# the expected team, hardened runtime, no entitlements, notarized with the
# ticket stapled, and accepted by Gatekeeper. Run it on the app as extracted
# from the final archive, not on the folder that was signed.
#
#   scripts/release/verify_signed_app.sh <limpet.app> <team-id>
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/verify_signed_app.sh).
set -euo pipefail

APP="$1"
TEAM="$2"
fail() { echo "error: $*" >&2; exit 1; }

[ -n "$TEAM" ] || fail "no team id given"
codesign --verify --deep --strict "$APP" || fail "codesign --verify --deep --strict failed"

INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
grep -q '^Authority=Developer ID Application: ' <<<"$INFO" || fail "not signed with a Developer ID Application certificate"
grep -qx "TeamIdentifier=$TEAM" <<<"$INFO" || fail "team identifier is not $TEAM"
grep -q 'flags=.*(runtime)' <<<"$INFO" || fail "hardened runtime flag missing"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$APP" "$SPARKLE" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
  # A path that is gone would read as "no entitlements"; a changed Sparkle
  # layout has to fail here, not be skipped.
  [ -e "$code" ] || fail "$code is missing; update this list to Sparkle's current layout"
  ENT=$(codesign -d --entitlements - --xml "$code" 2>/dev/null || true)
  [ -z "$ENT" ] || fail "$code carries entitlements; adding any needs the maintainer's sign-off"
done
[ ! -e "$SPARKLE/Versions/B/XPCServices" ] && [ ! -e "$SPARKLE/XPCServices" ] || fail "Sparkle XPCServices present"

xcrun stapler validate "$APP" >/dev/null || fail "no stapled notarization ticket"
# Captured first: `spctl | grep -q` under pipefail can fail a passing check
# when grep exits early and spctl dies of SIGPIPE.
GATEKEEPER=$(spctl -a -vv -t exec "$APP" 2>&1 || true)
grep -qx 'source=Notarized Developer ID' <<<"$GATEKEEPER" || fail "Gatekeeper does not report Notarized Developer ID: $GATEKEEPER"
echo "verified: $APP"
