#!/bin/sh
# Prepends a release <item> to a Sparkle appcast.
#
# Usage: update-appcast.sh <appcast.xml> <version> <download-url> <sign_update output> <min-macos>
#
# <sign_update output> is the attribute string printed by Sparkle's `sign_update`, e.g.
#   sparkle:edSignature="..." length="12345"
#
# The item goes directly under the `<!-- items:` marker comment so the newest release is
# listed first. Re-running for a version that is already present is a no-op.

set -eu

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <appcast.xml> <version> <download-url> <sign_update output> <min-macos>" >&2
  exit 64
fi

APPCAST="$1"
VERSION="$2"
URL="$3"
SIGNATURE_ATTRS="$4"
MIN_OS="$5"

if ! grep -q '<!-- items:' "$APPCAST"; then
  echo "error: $APPCAST has no '<!-- items:' marker" >&2
  exit 1
fi

if grep -q "<sparkle:version>${VERSION}</sparkle:version>" "$APPCAST"; then
  echo "$APPCAST already lists ${VERSION}; leaving it alone"
  exit 0
fi

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NOTES_URL="https://github.com/armcknight/claude-squad/releases/tag/${VERSION}"

ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE" "$APPCAST.tmp"' EXIT
cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
      <enclosure url="${URL}" type="application/octet-stream" ${SIGNATURE_ATTRS} />
    </item>
ITEM

awk -v item_file="$ITEM_FILE" '
  { print }
  /<!-- items:/ { while ((getline line < item_file) > 0) print line }
' "$APPCAST" > "$APPCAST.tmp"
mv "$APPCAST.tmp" "$APPCAST"
echo "Added ${VERSION} to $APPCAST"
