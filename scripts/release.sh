#!/bin/bash
# Makes a release anyone can install: signed with your Developer ID, notarized by Apple, stapled,
# as a .dmg (for people) and a .zip (for in-app updates). With --publish it uploads both to your
# share server and makes it the latest version, so every Shapr offers the update.
#
# One-time setup (needs an Apple Developer account, $99/year):
#   1. In Xcode → Settings → Accounts, add your Apple ID and create a "Developer ID Application" certificate.
#   2. xcrun notarytool store-credentials shapr-notary --apple-id you@example.com --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com; it's kept in your Keychain)
#
# Usage:
#   SHAPR_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   SHAPR_SHARE_SERVER="https://shapr-share.you.workers.dev" \
#   scripts/release.sh [--publish]
#   (--publish also needs SHAPR_ADMIN_TOKEN, the secret you gave the server)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SHAPR_DEVELOPER_ID:?Set SHAPR_DEVELOPER_ID to your \"Developer ID Application: Name (TEAMID)\" identity (security find-identity -v -p codesigning)}"
: "${SHAPR_SHARE_SERVER:?Set SHAPR_SHARE_SERVER to your deployed share server, e.g. https://shapr-share.you.workers.dev}"
PROFILE="${SHAPR_NOTARY_PROFILE:-shapr-notary}"
PUBLISH=0; [[ "${1:-}" == "--publish" ]] && PUBLISH=1

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw Resources/Info.plist)
ZIP="build/Shapr-$VERSION.zip"
DMG="build/Shapr-$VERSION.dmg"
echo "Releasing Shapr $VERSION ($BUILD)"

SHAPR_SIGN_IDENTITY="$SHAPR_DEVELOPER_ID" SHAPR_HARDENED=1 SHAPR_SHARE_SERVER="$SHAPR_SHARE_SERVER" scripts/build-app.sh
codesign --verify --strict --deep build/Shapr.app

echo "Notarizing the app (this takes a few minutes)…"
rm -f "$ZIP"
ditto -c -k --keepParent build/Shapr.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Shapr.app
rm -f "$ZIP"
ditto -c -k --keepParent build/Shapr.app "$ZIP"   # the stapled app, for in-app updates

echo "Making the disk image…"
STAGE=$(mktemp -d)
cp -R build/Shapr.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Shapr" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SHAPR_DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v build/Shapr.app

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Built $DMG and $ZIP (sha256 $SHA)"

if [[ $PUBLISH == 1 ]]; then
  : "${SHAPR_ADMIN_TOKEN:?Set SHAPR_ADMIN_TOKEN (the secret you gave the server) to publish}"
  for f in "$ZIP" "$DMG"; do
    curl -fsS -X PUT -H "Authorization: Bearer $SHAPR_ADMIN_TOKEN" --data-binary "@$f" \
      "$SHAPR_SHARE_SERVER/api/app/files/$(basename "$f")" >/dev/null
  done
  NOTES="${SHAPR_RELEASE_NOTES:-}"
  printf '{"version":"%s","build":"%s","file":"%s","dmg":"%s","sha256":"%s","notes":%s}' \
    "$VERSION" "$BUILD" "$(basename "$ZIP")" "$(basename "$DMG")" "$SHA" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTES")" |
    curl -fsS -X PUT -H "Authorization: Bearer $SHAPR_ADMIN_TOKEN" -H "Content-Type: application/json" --data-binary @- \
      "$SHAPR_SHARE_SERVER/api/app/latest" >/dev/null
  echo "Published: $SHAPR_SHARE_SERVER/download now serves Shapr $VERSION, and installed copies will offer the update."
fi
