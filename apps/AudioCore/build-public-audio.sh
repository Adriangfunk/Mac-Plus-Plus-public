#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
STAGE_ONLY="${MACPP_BUILD_STAGE_ONLY:-1}"
BUILD_DIR="${MACPP_PUBLIC_AUDIO_BUILD_DIR:-$ROOT/../../build/AudioCore}"
APP="$BUILD_DIR/Mac++ Audio Puller.app"
OUTPUT="$APP/Contents/MacOS/Mac++ Audio Puller"
SIGN_IDENTITY="${MACPP_AUDIO_SIGNING_IDENTITY:-${MACPP_SIGNING_IDENTITY:--}}"

/bin/rm -rf -- "$BUILD_DIR"
/bin/mkdir -p "$APP/Contents/MacOS"

/usr/bin/clang -std=c11 -O2 -Wall -Wextra \
  -I"$ROOT" \
  -c "$ROOT/macpp_audio_dsp.c" \
  -o "$BUILD_DIR/macpp_audio_dsp.o"

/usr/bin/clang -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -Wno-deprecated-declarations \
  -I"$ROOT" \
  "$ROOT/public-audio-reactive.m" \
  "$ROOT/macpp_audio_engine.m" \
  "$BUILD_DIR/macpp_audio_dsp.o" \
  -framework AppKit \
  -framework Foundation \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework Accelerate \
  -o "$OUTPUT"

/bin/cp -p "$ROOT/PublicAudioInfo.plist" "$APP/Contents/Info.plist"
/bin/chmod +x "$OUTPUT"

if [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --deep "$APP" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$APP"
fi

print -r -- "Staged generic audio helper: $APP"
print -r -- "No LaunchAgent was written or loaded."
if [[ "$STAGE_ONLY" == "0" ]]; then
  print -r -- "Set MACPP_BUILD_STAGE_ONLY=1 for the review-safe default."
fi
