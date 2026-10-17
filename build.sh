#!/bin/zsh
# Build Cubby.app with SwiftPM (no Xcode). Usage: ./build.sh [run]
set -euo pipefail
cd "${0:A:h}"

# ponytail: the default swift-build backend needs full Xcode; native works with Command Line Tools only.
swift build -c release --build-system native 2> >(grep -v "has been deprecated" >&2)
APP=build/Cubby.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cubby "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# A stable signing identity keeps the Accessibility grant (needed for direct paste) across rebuilds.
# `release` signs with Developer ID + hardened runtime instead, which notarization requires.
KIND="Apple Development"; [[ "${1:-}" == release ]] && KIND="Developer ID Application"
IDENTITY="${CUBBY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -v k="$KIND" 'index($0, k) {print $2; exit}')}"
if [[ "${1:-}" == release ]]; then
  [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == run ]]; then
  pkill -x Cubby || true
  open "$APP"
fi

# ./build.sh release → build/Cubby-<version>.dmg, notarized and stapled.
# Locally it uses the notarytool keychain profile "notary" (xcrun notarytool store-credentials notary --key … --key-id … --issuer …);
# in CI it uses the App Store Connect API key from NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID.
if [[ "${1:-}" == release ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
  DMG="build/Cubby-$VERSION.dmg"
  rm -rf build/dmg "$DMG"
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  hdiutil create -volname Cubby -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null 2>&1
  rm -rf build/dmg
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    AUTH=(--keychain-profile "${NOTARY_PROFILE:-notary}")
  fi
  echo "Submitting $DMG to Apple's notary service (usually 1–5 minutes)…"
  RESULT=$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json)
  STATUS=$(print -r -- "$RESULT" | plutil -extract status raw -)
  if [[ "$STATUS" != Accepted ]]; then
    echo "Notarization $STATUS:" >&2
    xcrun notarytool log "$(print -r -- "$RESULT" | plutil -extract id raw -)" "${AUTH[@]}" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Notarized $DMG"
fi
