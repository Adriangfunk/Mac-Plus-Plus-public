#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
MACPP_ROOT="${ROOT:h:h}"
OUTPUT="$MACPP_ROOT/build/macpp-screen-luminance"
if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--output" ]]; then
    print -u2 -- "usage: build-luminance.sh [--output ABSOLUTE_PATH]"
    exit 2
  fi
  OUTPUT="$2"
fi
[[ "$OUTPUT" == /* ]] || { print -u2 -- "error: output must be absolute"; exit 2; }
[[ ! -L "$OUTPUT" ]] || { print -u2 -- "error: refusing to replace symbolic-link output"; exit 2; }
mkdir -p "${OUTPUT:h}"
TEMP="${OUTPUT:h}/.${OUTPUT:t}.new.$$"
trap '/bin/rm -f -- "$TEMP"' EXIT INT TERM
# The one-shot capture is availability-guarded, so the helper can report a
# controlled unsupported result instead of failing to launch on macOS 13.
TARGET_TRIPLE="$(/usr/bin/uname -m)-apple-macos13.0"
xcrun swiftc -O -warnings-as-errors -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -framework AppKit -framework CoreGraphics -framework Foundation -framework ScreenCaptureKit \
  "$ROOT/macpp-screen-luminance.swift" -o "$TEMP"
SIGN_IDENTITY="${MACPP_SCREEN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY="-"
codesign --force --sign "$SIGN_IDENTITY" --identifier org.macplusplus.macpp-screen-luminance "$TEMP" >/dev/null
codesign --verify --strict "$TEMP"
mv -f "$TEMP" "$OUTPUT"
chmod 755 "$OUTPUT"
trap - EXIT INT TERM
print -- "Built $OUTPUT"
