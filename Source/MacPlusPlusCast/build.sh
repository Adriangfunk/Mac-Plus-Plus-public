#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="${ROOT:h:h}/build/MacPlusPlusSearch.app"
IDENTITY="${MACPPCAST_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  print -u2 -- "Set MACPPCAST_SIGNING_IDENTITY to a signing identity for a staged public Search build."
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -whole-module-optimization -parse-as-library -warnings-as-errors -D MACPP_PUBLIC_RELEASE \
  -framework SwiftUI -framework AppKit -framework Carbon \
  -framework ImageIO -framework UniformTypeIdentifiers \
  "$ROOT/../MacPlusPlusCore/MacPlusPlusPaletteCatalog.swift" \
  "$ROOT/../MacPlusPlusCore/MacPlusPlusYabaiConfiguration.swift" \
  "$ROOT/../MacPlusPlusCaelestiaShell/Sources/MacPlusPlusPublicDisabledServices.swift" \
  "$ROOT/../MacPlusPlusCaelestiaShell/Sources/MacPlusPlusMediaControl.swift" \
  "$ROOT/Sources/MacPlusPlusPickerCatalog.swift" \
  "$ROOT/Sources/MacPlusPlusCast.swift" -o "$APP/Contents/MacOS/MacPlusPlusSearch"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/../../config/palettes.json" "$APP/Contents/Resources/palettes.json"
cp "$ROOT/Resources/MacPlusPlusPickerCatalog.json" "$APP/Contents/Resources/MacPlusPlusPickerCatalog.json"
cp "$ROOT/../../bin/macpp-media-control" "$APP/Contents/Resources/macpp-media-control"
chmod 755 "$APP/Contents/Resources/macpp-media-control"
"$ROOT/../../apps/MacPlusPlusScreen/build-color-picker.sh" \
  --output "$APP/Contents/Resources/macpp-color-picker"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "$APP"
