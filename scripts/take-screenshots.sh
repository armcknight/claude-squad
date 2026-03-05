#!/bin/bash
set -uo pipefail

# Takes marketing screenshots via XCUITests and copies them to docs/screenshots/.
#
# Usage: ./scripts/take-screenshots.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCREENSHOTS_DIR="$PROJECT_DIR/docs/screenshots"

# Kill any leftover instances from previous runs.
killall -9 ClaudeSquad 2>/dev/null || true
sleep 2

echo "==> Running screenshot tests..."
xcodebuild test \
    -project "$PROJECT_DIR/ClaudeSquad.xcodeproj" \
    -scheme ClaudeSquad \
    -destination 'platform=macOS' \
    -only-testing ClaudeSquadUITests/ScreenshotTests \
    2>&1 | tail -5

# Find the most recent xcresult.
DERIVED_DATA=$(xcodebuild -project "$PROJECT_DIR/ClaudeSquad.xcodeproj" \
    -scheme ClaudeSquad -showBuildSettings 2>/dev/null \
    | grep BUILD_DIR | head -1 | awk '{print $3}' | sed 's|/Build/Products||')
RESULT_PATH=$(ls -dt "$DERIVED_DATA/Logs/Test/"*.xcresult 2>/dev/null | head -1)

if [ -z "$RESULT_PATH" ]; then
    echo "ERROR: Could not find xcresult bundle"
    exit 1
fi

echo ""
echo "==> Extracting screenshots from xcresult..."

# Export all attachments to a temp directory.
TMPDIR_EXPORT=$(mktemp -d)
xcrun xcresulttool export attachments \
    --path "$RESULT_PATH" \
    --output-path "$TMPDIR_EXPORT"

# Move PNGs to docs/screenshots/, using the attachment name from manifest.json.
mkdir -p "$SCREENSHOTS_DIR"
rm -f "$SCREENSHOTS_DIR"/*.png

if [ -f "$TMPDIR_EXPORT/manifest.json" ]; then
    python3 -c "
import json, shutil, os, sys

export_dir = sys.argv[1]
screenshots_dir = sys.argv[2]

with open(os.path.join(export_dir, 'manifest.json')) as f:
    manifest = json.load(f)

exported = 0
for test_entry in manifest:
    for att in test_entry.get('attachments', []):
        suggested = att.get('suggestedHumanReadableName', '')
        filename = att.get('exportedFileName', '')
        if not suggested or not filename:
            continue
        # Skip non-PNG files (e.g. automatic screen recordings).
        if not filename.endswith('.png'):
            continue
        src = os.path.join(export_dir, filename)
        # Extract clean name: 'foo_0_UUID.png' -> 'foo'
        import re
        clean = re.sub(r'_\d+_[0-9A-F-]+\.png$', '', suggested)
        if not clean:
            clean = os.path.splitext(suggested)[0]
        dst = os.path.join(screenshots_dir, f'{clean}.png')
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f'  {clean}.png')
            exported += 1

print(f'\n==> {exported} screenshot(s) saved to docs/screenshots/')
" "$TMPDIR_EXPORT" "$SCREENSHOTS_DIR"
else
    # Fallback: just copy all PNGs
    cp "$TMPDIR_EXPORT"/*.png "$SCREENSHOTS_DIR/" 2>/dev/null || true
    echo "==> Copied PNGs (no manifest found)"
fi

rm -rf "$TMPDIR_EXPORT"

ls -la "$SCREENSHOTS_DIR"/*.png 2>/dev/null || echo "  (no screenshots found)"
