#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
MACPP_ROOT="${ROOT:h:h}"
OUTPUT="$MACPP_ROOT/build/macpp-color-picker"
if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--output" ]]; then
    print -u2 -- "usage: build-color-picker.sh [--output ABSOLUTE_PATH]"
    exit 2
  fi
  OUTPUT="$2"
fi
[[ "$OUTPUT" == /* ]] || { print -u2 -- "error: output must be absolute"; exit 2; }
[[ ! -L "$OUTPUT" ]] || { print -u2 -- "error: refusing to replace symbolic-link output"; exit 2; }
mkdir -p "${OUTPUT:h}"
TEMP="${OUTPUT:h}/.${OUTPUT:t}.new.$$"
trap '/bin/rm -f -- "$TEMP"' EXIT INT TERM
# SCScreenshotManager is selected behind an availability guard so this helper
# can still build and report a clear unsupported result on macOS 13.
TARGET_TRIPLE="$(/usr/bin/uname -m)-apple-macos13.0"
xcrun swiftc -O -warnings-as-errors -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -framework AppKit -framework CoreGraphics -framework Foundation -framework ScreenCaptureKit \
  "$ROOT/macpp-color-picker.swift" -o "$TEMP"
SIGN_IDENTITY="${MACPP_SCREEN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
codesign --force --sign "$SIGN_IDENTITY" --identifier org.macplusplus.macpp-color-picker "$TEMP" >/dev/null
codesign --verify --strict "$TEMP"
mv -f "$TEMP" "$OUTPUT"
chmod 755 "$OUTPUT"
trap - EXIT INT TERM
print -- "Built $OUTPUT"
