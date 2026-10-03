#!/bin/bash
# Check a generated appcast.xml against the app it describes, before anything
# is published.
#
#   scripts/release/verify_appcast.sh <limpet.app> <archive.tar.gz> <appcast.xml> \
#       <sparkle-bin-dir> <ed-key-file>
#
# 1. The item for this archive has sparkle:version == the app's CFBundleVersion.
# 2. Its sparkle:edSignature verifies with sign_update --verify.
# 3. Its signature also verifies against the app's own SUPublicEDKey, with
#    OpenSSL (OpenSSL 3, not macOS's LibreSSL: it has no Ed25519). sign_update
#    cannot take a public key, and generate_appcast only warns on a mismatch,
#    so this is the check that the key in the shipped Info.plist matches the
#    private key that signed the update. A mismatch would ship an update no
#    installed copy accepts.
set -euo pipefail

APP="$1"; ARCHIVE="$2"; APPCAST="$3"; BIN="$4"; KEY_FILE="$5"
OPENSSL="${OPENSSL:-/opt/homebrew/bin/openssl}"
fail() { echo "error: $*" >&2; exit 1; }
[ -x "$OPENSSL" ] || fail "$OPENSSL is not executable (need OpenSSL 3 for Ed25519)"
[ -x "$BIN/sign_update" ] || fail "$BIN/sign_update is not executable"

PLIST="$APP/Contents/Info.plist"
PUB=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[ -n "$PUB" ] || fail "SUPublicEDKey is empty in $PLIST"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Item selection and signature extraction in Python (xml.etree), so the
# comparison is on parsed values, not on grep over XML.
SIG=$(python3 - "$APPCAST" "$BUILD" "$(basename "$ARCHIVE")" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
appcast, build, archive = sys.argv[1:4]
hits = []
for item in ET.parse(appcast).getroot().iter("item"):
    enc = item.find("enclosure")
    if enc is not None and enc.get("url", "").endswith("/" + archive):
        hits.append((item.findtext("s:version", namespaces=ns), enc.get("{%s}edSignature" % ns["s"])))
mine = [sig for ver, sig in hits if ver == build]
if not mine or not mine[-1]:
    sys.exit("no item with sparkle:version %s and an edSignature for %s (items: %s)" % (build, archive, hits))
print(mine[-1])
PY
) || fail "appcast check: $SIG"

"$BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$ARCHIVE" "$SIG" >/dev/null \
  || fail "sign_update --verify rejected the appcast signature"

python3 - "$PUB" "$SIG" "$WORK" <<'PY'
import base64, sys
pub, sig, work = sys.argv[1:4]
raw = base64.b64decode(pub)
if len(raw) != 32:
    sys.exit("SUPublicEDKey is not a 32-byte Ed25519 key")
# SubjectPublicKeyInfo header for Ed25519 (RFC 8410) + the raw key.
open(work + "/pub.der", "wb").write(bytes.fromhex("302a300506032b6570032100") + raw)
open(work + "/sig.bin", "wb").write(base64.b64decode(sig))
PY
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.der" -keyform DER -rawin \
  -in "$ARCHIVE" -sigfile "$WORK/sig.bin" >/dev/null \
  || fail "the signature does not verify with the app's SUPublicEDKey: the signing key and Info.plist disagree"
echo "appcast ok: sparkle:version $BUILD, signature verifies with SUPublicEDKey"
