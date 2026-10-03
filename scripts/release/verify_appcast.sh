#!/bin/bash
# Check a generated appcast.xml against the app it describes, before anything
# is published.
#
#   scripts/release/verify_appcast.sh <limpet.app> <archive.tar.gz> <appcast.xml> \
#       <sparkle-bin-dir> <ed-key-file>
#
# 1. The item for this archive has sparkle:version == the app's CFBundleVersion.
# 2. Its sparkle:edSignature verifies with sign_update --verify.
# 3. Its signature also verifies against the app's own SUPublicEDKey, with an
#    OpenSSL that supports Ed25519 (not macOS's LibreSSL 3.3). sign_update
#    cannot take a public key, and generate_appcast only warns on a mismatch,
#    so this is the check that the key in the shipped Info.plist matches the
#    private key that signed the update. A mismatch would ship an update no
#    installed copy accepts.
# 4. The feed's own signature (the trailing sparkle-signatures block) verifies
#    the same way. Sparkle does not document the covered bytes; measured on
#    2.10.0, the signature covers exactly the bytes before the block and
#    `length:` is that byte count. If a Sparkle upgrade changes this, this
#    check fails loudly and needs updating, it does not pass silently.
set -euo pipefail

APP="$1"; ARCHIVE="$2"; APPCAST="$3"; BIN="$4"; KEY_FILE="$5"
fail() { echo "error: $*" >&2; exit 1; }
# An openssl that can do Ed25519: PATH's first, then Homebrew's openssl@3.
OPENSSL=""
CANDIDATES=(openssl)
if BREW_SSL=$(brew --prefix openssl@3 2>/dev/null); then CANDIDATES+=("$BREW_SSL/bin/openssl"); fi
for c in "${CANDIDATES[@]}"; do
  if "$c" genpkey -algorithm ed25519 >/dev/null 2>&1; then OPENSSL="$c"; break; fi
done
[ -n "$OPENSSL" ] || fail "no openssl with Ed25519 support on PATH or in Homebrew's openssl@3"
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
# Feed signature: the bytes before the trailing block, and its length field.
python3 - "$APPCAST" "$WORK" <<'PY'
import re, base64, sys
b = open(sys.argv[1], "rb").read()
i = b.rfind(b"<!-- sparkle-signatures:")
m = re.fullmatch(rb"<!-- sparkle-signatures:\s*edSignature: (\S+)\s*length: (\d+)\s*-->\s*", b[i:]) if i >= 0 else None
if not m:
    sys.exit("appcast.xml has no well-formed trailing sparkle-signatures block")
if int(m.group(2)) != i:
    sys.exit("feed signature length %s != %d bytes before the block" % (m.group(2), i))
open(sys.argv[2] + "/feed.body", "wb").write(b[:i])
open(sys.argv[2] + "/feed.sig", "wb").write(base64.b64decode(m.group(1)))
PY
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.der" -keyform DER -rawin \
  -in "$ARCHIVE" -sigfile "$WORK/sig.bin" >/dev/null \
  || fail "the signature does not verify with the app's SUPublicEDKey: the signing key and Info.plist disagree"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.der" -keyform DER -rawin \
  -in "$WORK/feed.body" -sigfile "$WORK/feed.sig" >/dev/null \
  || fail "the feed signature does not verify with the app's SUPublicEDKey"
echo "appcast ok: sparkle:version $BUILD, item and feed signatures verify with SUPublicEDKey"
