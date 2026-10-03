#!/bin/bash
# Generate (or extend) the Sparkle feed for a release archive.
#
#   scripts/release/make_appcast.sh <sparkle-bin-dir> <archive.tar.gz> <tag> \
#       <ed-key-file> <out-appcast.xml> [notes.md] [previous-appcast.xml]
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/make_appcast.sh).
#
# <sparkle-bin-dir> is PASSED IN, never derived from the build artifact: the
# sign job resolves Sparkle itself from the checked-out Package.resolved, so
# no binary produced by the unprivileged build job runs next to the signing key.
#
# Delegates to Sparkle's generate_appcast so the feed is a proper multi-item
# appcast. The previous release's appcast.xml (when given) seeds the working
# directory: generate_appcast reads it back, keeps prior items verbatim (URLs,
# EdDSA signatures, notes survive without the old archives), appends the new
# item, signs it, and prunes to --maximum-versions.
#
# Feed signing: the app sets SURequireSignedFeed=YES. generate_appcast 2.10
# signs the feed on its own when an archive's Info.plist requires it (checked
# by running it on a Release build), and the check at the end makes that
# explicit: the script fails unless the output carries a sparkle:edSignature
# for the feed itself, instead of trusting a default.
set -euo pipefail

BIN="$1"
ARCHIVE="$2"
TAG="$3"
KEY_FILE="$4"
OUT="$5"
NOTES_FILE="${6:-}"
PREVIOUS="${7:-}"

GENERATE_APPCAST="$BIN/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || { echo "error: $GENERATE_APPCAST is not executable" >&2; exit 1; }

ARCHIVE_BASENAME=$(basename "$ARCHIVE")                  # limpet.app.tar.gz
NOTES_BASENAME="${ARCHIVE_BASENAME%.tar.gz}.md"          # limpet.app.md

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -n "$PREVIOUS" ] && [ -f "$PREVIOUS" ] && cp "$PREVIOUS" "$WORK/appcast.xml"
cp "$ARCHIVE" "$WORK/$ARCHIVE_BASENAME"

# A same-base-name sidecar becomes the new item's description; an empty one
# would become an empty description, so only a non-empty file is used.
EMBED=()
if [ -n "$NOTES_FILE" ] && [ -s "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$WORK/$NOTES_BASENAME"
  EMBED=(--embed-release-notes)
fi

# generate_appcast only WARNS when the app's SUPublicEDKey does not match the
# signing key (measured with 2.10.0: exit 0, feed written). Capture its output
# and turn that warning into a failure.
LOG="$WORK/generate_appcast.log"
"$GENERATE_APPCAST" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/Nanako0129/limpet/releases/download/$TAG/" \
  --link "https://github.com/Nanako0129/limpet/releases/tag/$TAG" \
  ${EMBED[@]+"${EMBED[@]}"} \
  --maximum-versions 5 \
  "$WORK" 2>&1 | tee "$LOG"
if grep -q 'does not match' "$LOG"; then
  echo "error: the app's SUPublicEDKey does not match the Sparkle signing key" >&2
  exit 1
fi

[ -s "$WORK/appcast.xml" ] || { echo "error: generate_appcast produced no appcast.xml" >&2; exit 1; }
# The signed-feed requirement is only met if the feed itself is signed.
grep -q '<!-- sparkle-signatures:' "$WORK/appcast.xml" || { echo "error: appcast.xml carries no feed signature (sparkle-signatures block)" >&2; exit 1; }

cp "$WORK/appcast.xml" "$OUT"
echo "appcast written to $OUT: $(grep -c '<item>' "$OUT") item(s)"
