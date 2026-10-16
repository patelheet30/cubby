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
IDENTITY="${CUBBY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == run ]]; then
  pkill -x Cubby || true
  open "$APP"
fi
