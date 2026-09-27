#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
MACPP_ROOT="${ROOT:h:h}"
OUTPUT="$MACPP_ROOT/build/macpp-screen"

if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--output" ]]; then
    print -u2 -- "usage: build.sh [--output ABSOLUTE_PATH]"
    exit 2
  fi
  OUTPUT="$2"
fi

[[ "$OUTPUT" == /* ]] || {
  print -u2 -- "error: output must be an absolute path"
  exit 2
}
[[ ! -L "$OUTPUT" ]] || {
  print -u2 -- "error: refusing to replace symbolic-link output: $OUTPUT"
  exit 2
}

mkdir -p "${OUTPUT:h}"
TEMP="${OUTPUT:h}/.${OUTPUT:t}.new.$$"
trap '/bin/rm -f -- "$TEMP"' EXIT INT TERM
# Keep the helper launchable on the macOS 13 ScreenCaptureKit fallback. The
# one-shot SCScreenshotManager path is guarded at runtime below; the persistent
# SCStream path remains available on the older deployment target.
TARGET_TRIPLE="$(/usr/bin/uname -m)-apple-macos13.0"

/usr/bin/xcrun swiftc -O \
  -warnings-as-errors \
  -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Foundation \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "$ROOT/macpp-screen.swift" \
  -o "$TEMP"

SIGN_IDENTITY="${MACPP_SCREEN_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*\"\(Apple Development:.*\)\".*/\1/p' | /usr/bin/head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
  --identifier org.macplusplus.macpp-screen "$TEMP" >/dev/null
/usr/bin/codesign --verify --strict "$TEMP"

/bin/mv -f "$TEMP" "$OUTPUT"
/bin/chmod 755 "$OUTPUT"
trap - EXIT INT TERM
echo "Built $OUTPUT"
echo "Grant Screen Recording to this binary if capture is blocked:"
echo "  $OUTPUT"
