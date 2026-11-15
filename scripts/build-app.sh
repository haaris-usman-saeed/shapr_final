#!/bin/bash
# Builds build/Shapr.app (release). Usage: scripts/build-app.sh [--install]
#   --install   also copies it to /Applications
# Signing: SHAPR_SIGN_IDENTITY, else the identity named in .signing-identity (kept
# out of git), else ad-hoc. A fixed identity lets macOS remember Accessibility and
# Screen Recording across rebuilds; ad-hoc signing makes it forget them every time.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Shapr"

APP=build/Shapr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shapr"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$BIN" --make-icon "$ICONSET" >/dev/null 2>&1
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Which share server this build uses for live links and updates (default: http://localhost:8787).
if [[ -n "${SHAPR_SHARE_SERVER:-}" ]]; then
  plutil -replace ShaprShareServer -string "$SHAPR_SHARE_SERVER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SHAPR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then IDENTITY="$(head -n1 .signing-identity)"; fi
if [[ "${SHAPR_HARDENED:-}" == "1" ]]; then
  # For Developer ID releases: hardened runtime, secure timestamp, and the one entitlement Shapr needs.
  codesign --force --options runtime --timestamp --entitlements Resources/Shapr.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Shapr.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Shapr.app"
fi
