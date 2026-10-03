#!/bin/bash
# Notarize a signed limpet.app or installer DMG and staple the ticket to it.
#
#   scripts/release/notarize_app.sh <limpet.app | Limpet.dmg>
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/notarize_app.sh).
#
# Credentials, one of:
#   NOTARY_PROFILE                                     a notarytool keychain profile (local)
#   NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER_ID   an App Store Connect API key (CI)
#
# `notarytool submit --wait` can exit 0 on a rejected submission, so the
# verdict is read from its JSON output: anything but "Accepted" fails, after
# printing Apple's log for that submission.
set -euo pipefail

APP="$1"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  AUTH=(--key "${NOTARY_KEY_FILE:?}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# An app (a directory) is submitted as a zip; a DMG (a file) as itself.
if [ -d "$APP" ]; then
  SUBMIT="$WORK/submit.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT"
else
  SUBMIT="$APP"
fi

# Bounded wait. A non-zero exit fails the run even if the JSON says
# Accepted, but only after the log below has been fetched.
RC=0
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --timeout 60m \
  --output-format json > "$WORK/result.json" || RC=$?
field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$WORK/result.json" "$1"; }
STATUS=$(field status)
ID=$(field id)
echo "notarization $ID: $STATUS"
if [ "$STATUS" != "Accepted" ] || [ "$RC" -ne 0 ]; then
  echo "notarytool submit exit status $RC" >&2
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  exit 1
fi

xcrun stapler staple "$APP"
