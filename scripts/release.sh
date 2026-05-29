#!/usr/bin/env bash
#
# Build, Developer-ID sign, notarize, and staple Odin for distribution.
# Produces build/Odin.dmg (recommended) and build/Odin.zip — a notarized .app
# that runs on any Mac. Prefer the .dmg: a bare .app's internal symlinks get
# corrupted by cloud/zip round-trips (e.g. Google Drive), breaking the
# signature in transit; a disk image carries the bundle intact.
#
# One-time notarization credential setup (stored in your login keychain):
#
#   xcrun notarytool store-credentials odin-notary \
#       --apple-id mikael@lovholm.se \
#       --team-id <your-team-id> \
#       --password <app-specific-password>
#
#   App-specific password: appleid.apple.com → Sign-In and Security →
#   App-Specific Passwords. (Override the profile name with NOTARY_PROFILE.)
#
# Then just run:  ./scripts/release.sh
#
set -euo pipefail

PROJECT="Odin.xcodeproj"
SCHEME="Odin_macOS"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/Odin.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
NOTARY_PROFILE="${NOTARY_PROFILE:-odin-notary}"

# Full Xcode is required (Command Line Tools alone can't archive). Honour an
# explicit DEVELOPER_DIR if set, else fall back to the standard install.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Auto-detect the Developer ID Application identity and its team ID, so no
# team ID is hardcoded in the repo (matches the CLAUDE.md signing rule).
identity_line=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [[ -z "$identity_line" ]]; then
  echo "error: no 'Developer ID Application' certificate found in keychain." >&2
  echo "       Create one in Xcode → Settings → Accounts → Manage Certificates → + ." >&2
  exit 1
fi
team_id=$(printf '%s' "$identity_line" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')
devid_sha=$(printf '%s' "$identity_line" | grep -oE '[0-9A-F]{40}' | head -1)
echo "==> Signing with Developer ID team: $team_id"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$team_id" \
  -allowProvisioningUpdates \
  archive

# ExportOptions written at runtime under build/ (gitignored) — keeps the team
# ID out of version control.
export_opts="$BUILD_DIR/ExportOptions.plist"
cat > "$export_opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting Developer ID-signed app…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$export_opts" \
  -allowProvisioningUpdates

app="$EXPORT_DIR/Odin.app"
zip="$BUILD_DIR/Odin.zip"
dmg="$BUILD_DIR/Odin.dmg"

# Notarize the app first (notarytool needs a container, so submit a zip), then
# staple the ticket onto the .app itself so it validates even offline / after
# it's been dragged out of the disk image.
echo "==> Notarizing app (this can take a few minutes)…"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"

# Re-zip the now-stapled app (zip deliverable for whoever prefers it).
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

# Build a .dmg around the stapled app — the robust delivery format. A plain
# .app bundle is full of symlinks that cloud/zip round-trips (e.g. Google
# Drive "download folder as zip") silently corrupt, which breaks the code
# signature in transit; a disk image carries the bundle byte-for-byte. Stage
# the app next to an /Applications symlink so the user can drag to install.
echo "==> Building disk image…"
staging=$(mktemp -d)
ditto "$app" "$staging/Odin.app"            # ditto preserves the signed bundle exactly
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Odin" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging"

# Developer ID-sign the dmg before notarizing — without a code signature on
# the image itself, `spctl --type open` reports "no usable signature" even
# though the contents are notarized.
echo "==> Signing disk image…"
codesign --force --timestamp --sign "$devid_sha" "$dmg"

# Notarize + staple the dmg too, so the disk image itself passes Gatekeeper on
# download (the stapled app inside covers the drag-out case).
echo "==> Notarizing disk image…"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"

echo
echo "✅ Notarized deliverables ready to send:"
echo "   • $dmg   (recommended — survives Drive/email/Slack)"
echo "   • $zip   (alternative; send the file as-is, don't re-zip the folder)"
echo "   Gatekeeper check: spctl -a -vvv -t install \"$app\""
