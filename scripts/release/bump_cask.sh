#!/bin/bash
# Rewrite the `version` and `sha256` lines of a Homebrew cask in place.
#
#   bump_cask.sh <cask.rb> <version> <sha256>
#
# Used by release.yml's `tap` job on Casks/limpet.rb in Nanako0129/homebrew-tap
# (limpet-plan.md L8.2). Inputs are validated before anything is written: the
# cask's `version "..."` is a Ruby double-quoted string, so an unchecked value
# could smuggle `#{...}` interpolation into code Homebrew executes.
#
# Exit codes: 0 = rewritten, or already at this version and sha (idempotent,
# prints "already up to date", so re-running the job is safe); 1 = bad input,
# or the cask lacks exactly one `version` / `sha256` line, or the rewrite did
# not produce the expected lines.
set -euo pipefail

CASK=${1:?usage: bump_cask.sh <cask.rb> <version> <sha256>}
VERSION=${2:?usage: bump_cask.sh <cask.rb> <version> <sha256>}
SHA=${3:?usage: bump_cask.sh <cask.rb> <version> <sha256>}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version '$VERSION' is not X.Y.Z" >&2; exit 1; }
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 '$SHA' is not 64 lowercase hex chars" >&2; exit 1; }
[ -f "$CASK" ] || { echo "error: $CASK not found" >&2; exit 1; }

VERSION_RE='^  version "[^"]*"$'
SHA_RE='^  sha256 "[^"]*"$'
[ "$(grep -cE "$VERSION_RE" "$CASK")" = 1 ] || { echo "error: $CASK must have exactly one '  version \"...\"' line" >&2; exit 1; }
[ "$(grep -cE "$SHA_RE" "$CASK")" = 1 ] || { echo "error: $CASK must have exactly one '  sha256 \"...\"' line" >&2; exit 1; }

WANT_VERSION="  version \"$VERSION\""
WANT_SHA="  sha256 \"$SHA\""
if grep -qxF "$WANT_VERSION" "$CASK" && grep -qxF "$WANT_SHA" "$CASK"; then
  echo "already up to date: $CASK is $VERSION"
  exit 0
fi

TMP=$(mktemp "${CASK}.XXXXXX")
trap 'rm -f "$TMP"' EXIT
# Values are validated above (digits, dots, hex only), so they are safe in sed.
sed -E -e "s/${VERSION_RE}/${WANT_VERSION}/" -e "s/${SHA_RE}/${WANT_SHA}/" "$CASK" > "$TMP"
grep -qxF "$WANT_VERSION" "$TMP" && grep -qxF "$WANT_SHA" "$TMP" \
  || { echo "error: rewrite did not produce the expected version/sha256 lines" >&2; exit 1; }
mv "$TMP" "$CASK"
trap - EXIT
echo "bumped $CASK to $VERSION"
