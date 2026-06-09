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

# A secure (network) timestamp is only needed for a notarized release (RELEASE=1). Plain local builds
# skip it — faster, works offline, and it doesn't affect the signing identity / TCC requirement.
if [[ "${RELEASE:-0}" == "1" ]]; then
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
# RELEASE (RELEASE=1): notarize + staple the app, then build a notarized DMG below.
# Plain `./build.sh` is a fast local build (sign only, no network) — same Developer ID
# identity as releases, so the same TCC designated requirement, so the Accessibility
# grant is shared and survives rebuilds (no duplicate entries). Notarization needs a
# Developer ID identity and a stored notarytool credential profile (login keychain):
#   xcrun notarytool store-credentials AltTabNotary \
#     --apple-id "you@example.com" --team-id TEAMID --password APP_SPECIFIC_PASSWORD
# Override the profile name with NOTARY_PROFILE=... if you used a different one.
# ---------------------------------------------------------------------------
NOTARY_PROFILE="${NOTARY_PROFILE:-AltTabNotary}"
ZIP="build/${APP_NAME}.zip"

if [[ "${RELEASE:-0}" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" != Developer\ ID* ]]; then
    echo "RELEASE=1 needs a Developer ID identity, got: $SIGN_IDENTITY" >&2; exit 1
  fi
  echo "==> Notarize (profile: $NOTARY_PROFILE) — this uploads to Apple and waits"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Staple ticket into the bundle"
  xcrun stapler staple "$APP"            # fails (and aborts) if notarization didn't actually succeed
  ditto -c -k --keepParent "$APP" "$ZIP" # re-zip the stapled app for distribution
  echo "==> Gatekeeper assessment"
  spctl --assess --type execute -vvv "$APP" || true
  echo "Notarized + stapled + zipped for distribution: $ZIP"
else
  echo "(local build — sign only; use RELEASE=1 for a notarized DMG release)"
fi

# ---------------------------------------------------------------------------
# DMG: build a distributable disk image from the (now stapled) app, then sign +
# notarize + staple the DMG itself. The ticket travels with the .dmg, so a
# downloaded image passes Gatekeeper even offline — the gold-standard artifact
# for a GitHub Release. Runs only for a release (RELEASE=1); set DMG=0 to skip
# and ship just the .zip. Uses `create-dmg` (brew) for the nice
# drag-to-Applications layout when present, else a plain hdiutil image.
# ---------------------------------------------------------------------------
DMG_PATH="build/${APP_NAME}.dmg"

if [[ "${RELEASE:-0}" == "1" && "${DMG:-1}" != "0" ]]; then
  echo "==> Build DMG ($DMG_PATH)"
  rm -f "$DMG_PATH"
  if command -v create-dmg > /dev/null 2>&1; then
    # create-dmg can return non-zero on cosmetic AppleScript hiccups even when the
    # image is fine, so don't let set -e abort — verify the file exists instead.
    create-dmg \
      --volname "$APP_NAME" \
      --window-size 540 380 \
      --icon-size 110 \
      --icon "${APP_NAME}.app" 150 190 \
      --app-drop-link 390 190 \
      --hdiutil-quiet \
      --codesign "$SIGN_IDENTITY" \
      "$DMG_PATH" "$APP" || true
    [[ -f "$DMG_PATH" ]] || { echo "create-dmg failed to produce $DMG_PATH" >&2; exit 1; }
  else
    echo "    (create-dmg not installed — plain image; 'brew install create-dmg' for the drag-to-Applications layout)"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG_PATH"
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  fi
  echo "==> Notarize DMG (profile: $NOTARY_PROFILE) — uploads to Apple and waits"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo "==> Gatekeeper assessment (DMG)"
  spctl --assess --type open --context context:primary-signature -vvv "$DMG_PATH" || true
  echo "Distributable disk image: $DMG_PATH"
fi
