#!/usr/bin/env bash
# AltTab build + package + codesign. Pipeline = `swift build` + this script. No npm/Python/JS.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AltTab"
BUNDLE_ID="dev.fusy.alttab"
APP="build/${APP_NAME}.app"

# Signing identity. Precedence: env var > local .signing-identity file (gitignored) > ad-hoc "-".
# Pin a STABLE identity so the macOS Accessibility/TCC grant survives rebuilds — ad-hoc "-" changes the
# code hash every build and DROPS the grant (you'd have to re-grant Accessibility each time). Pin it via:
#   echo 'Apple Development: Your Name (TEAMID)' > .signing-identity
# or per-build:  SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
# For release:   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
if [[ -z "${SIGN_IDENTITY:-}" && -f .signing-identity ]]; then
  SIGN_IDENTITY="$(tr -d '\r\n' < .signing-identity)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# A secure (network) timestamp is only needed for a notarized Developer ID *release*. Ad-hoc and local
# dev identities (Apple Development, self-signed) skip it — faster and works offline.
if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  TIMESTAMP_FLAG="--timestamp"
else
  TIMESTAMP_FLAG="--timestamp=none"
fi

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
# Copy any other bundled resources (icons, etc.) if present.
if compgen -G "Resources/*.icns" > /dev/null; then cp Resources/*.icns "$APP/Contents/Resources/"; fi

echo "==> Codesign (identity: $SIGN_IDENTITY)"
# Hardened runtime (--options runtime) + entitlements. No --deep: nothing is nested.
codesign --force \
  --options runtime \
  $TIMESTAMP_FLAG \
  --entitlements "AltTab.entitlements" \
  --sign "$SIGN_IDENTITY" \
  "$APP"

echo "==> Verify"
codesign --verify --strict --verbose=2 "$APP"
echo "Built and signed: $APP"

# ---------------------------------------------------------------------------
# RELEASE-ONLY: notarize + staple (run only with a real Developer ID identity).
# Requires a one-time stored credential profile:
#   xcrun notarytool store-credentials AltTabNotary \
#     --apple-id "you@example.com" --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
# ZIP="build/${APP_NAME}.zip"
# ditto -c -k --keepParent "$APP" "$ZIP"
# xcrun notarytool submit "$ZIP" --keychain-profile AltTabNotary --wait
# xcrun stapler staple "$APP"
# ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip the stapled app for distribution
# ---------------------------------------------------------------------------
