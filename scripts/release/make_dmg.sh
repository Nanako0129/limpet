#!/bin/bash
# Assemble the installer DMG around a (signed) limpet.app: the app and an
# /Applications symlink, nothing else (no custom background or Finder layout).
#
#   scripts/release/make_dmg.sh <limpet.app> <out.dmg>
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/make_dmg.sh).
# Uses only macOS's own tools (ditto, hdiutil).
set -euo pipefail

APP="$1"
OUT="$2"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/limpet.app"
ln -s /Applications "$STAGE/Applications"
# mktemp makes the stage 0700 and CI runs under umask 077; the volume root
# must be readable by whoever mounts the image.
chmod 755 "$STAGE"

# hdiutil on hosted runners fails now and then with "Resource busy"; a
# retry here is cheaper than re-running a release after notarization.
for attempt in 1 2 3; do
  if hdiutil create -quiet -volname limpet -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"; then
    echo "==> $OUT"
    exit 0
  fi
  echo "hdiutil create failed (attempt $attempt); retrying" >&2
  sleep 10
done
echo "error: hdiutil create failed three times" >&2
exit 1
