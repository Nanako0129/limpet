#!/bin/bash
# Print the project's MARKETING_VERSION (the version a tag must equal).
# Fails unless every build configuration agrees on one value.
#
#   scripts/release/project_version.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
V=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' limpet.xcodeproj/project.pbxproj | sort -u)
case "$V" in
  "") echo "error: no MARKETING_VERSION in project.pbxproj" >&2; exit 1 ;;
  *$'\n'*) echo "error: MARKETING_VERSION differs between configurations: $(tr "\n" " " <<<"$V")" >&2; exit 1 ;;
esac
echo "$V"
