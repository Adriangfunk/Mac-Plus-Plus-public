#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
MACPP_ROOT="${ROOT:h:h}"
OUTPUT="$MACPP_ROOT/build/macpp-freeze-capture"

if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--output" ]]; then
    print -u2 "usage: build-freeze.sh [--output ABSOLUTE_PATH]"
    exit 2
  fi
  OUTPUT="$2"
fi

[[ "$OUTPUT" == /* ]] || {
  print -u2 "error: output must be an absolute path"
  exit 2
}
[[ ! -L "$OUTPUT" ]] || {
  print -u2 "error: refusing to replace symbolic-link output: $OUTPUT"
  exit 2
}

/bin/mkdir -p "${OUTPUT:h}"
TEMP="${OUTPUT:h}/.${OUTPUT:t}.new.$$"
trap '/bin/rm -f -- "$TEMP"' EXIT INT TERM
# SCScreenshotManager is selected behind an availability guard; retain the
# macOS 13 deployment target used by the ScreenCaptureKit fallback.
TARGET_TRIPLE="$(/usr/bin/uname -m)-apple-macos13.0"

/usr/bin/xcrun swiftc -O \
  -warnings-as-errors \
  -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Foundation \
  -framework ImageIO \
  -framework ScreenCaptureKit \
  -framework UniformTypeIdentifiers \
  "$ROOT/MacPlusPlusFreezeCaptureCore.swift" \
  "$ROOT/macpp-freeze-capture.swift" \
  -o "$TEMP"

SIGN_IDENTITY="${MACPP_SCREEN_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | /usr/bin/head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
  --identifier org.macplusplus.macpp-freeze-capture "$TEMP" >/dev/null
/usr/bin/codesign --verify --strict "$TEMP"

/bin/mv -f "$TEMP" "$OUTPUT"
/bin/chmod 755 "$OUTPUT"
trap - EXIT INT TERM
print "Built $OUTPUT"
print "Grant Screen Recording to this stable binary if capture is blocked:"
print "  $OUTPUT"
