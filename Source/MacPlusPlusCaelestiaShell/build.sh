#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
BUILD_ROOT="${ROOT:h:h}/build"
production_profile=0
if [[ "${MACPP_CAELESTIA_PRODUCTION:-0}" == 1 ]]; then
  production_profile=1
  app_name="Mac++ Shell.app"
  executable_name="Mac++ Shell"
else
  app_name="Mac++ Caelestia Shell.app"
  executable_name="Mac++ Caelestia Shell"
fi
APP="$BUILD_ROOT/$app_name"
# Accessibility/Input Monitoring grants are attached to the signed client, not
# merely to the bundle path. Never silently fall back to ad-hoc signing for the
# managed Shell: every rebuild would create a new TCC identity and macOS would
# deny the old grant again. Public builds must provide their own release
# identity; private builds may use the first local Apple Development identity.
IDENTITY="${MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY:-${MACPP_SHELL_SIGNING_IDENTITY:-${MACPP_SIGNING_IDENTITY:-}}}"
if [[ -z "$IDENTITY" ]]; then
  if [[ "${MACPP_PUBLIC_RELEASE:-0}" == 1 ]]; then
    print -u2 -- "Mac++ Shell public build requires MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY (or MACPP_SHELL_SIGNING_IDENTITY)."
    exit 1
  fi
  IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '\"' '/Apple Development:/{print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  if [[ "${MACPP_ALLOW_ADHOC:-0}" == 1 ]]; then
    IDENTITY="-"
  else
    print -u2 -- "No stable Apple Development signing identity is available; refusing an unstable Mac++ Shell replacement. Set MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY or use MACPP_ALLOW_ADHOC=1 only for disposable previews."
    exit 1
  fi
fi
if [[ "$IDENTITY" == "-" && "${MACPP_ALLOW_ADHOC:-0}" != 1 ]]; then
  print -u2 -- "Refusing ad-hoc Mac++ Shell signing because it resets the macOS privacy client identity. Set MACPP_ALLOW_ADHOC=1 only for a disposable preview."
  exit 1
fi

# Swift refuses to compile an input that changes while whole-module
# optimization is running. That is easy to hit here because Shell is also
# edited/rebuilt by the development UI. Serialize generated output and compile
# one point-in-time source snapshot so an editor save cannot produce a false
# build failure or mix source generations into one app.
mkdir -p "$BUILD_ROOT"
BUILD_LOCK="$BUILD_ROOT/.caelestia-build.lock"
if [[ -L "$BUILD_LOCK" ]]; then
  print -u2 -- "Mac++ Shell build: refusing symlinked build lock"
  exit 1
fi
exec 9>>"$BUILD_LOCK"
/usr/bin/lockf -s -t 600 9
SOURCE_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/macpp-caelestia-shell-sources.XXXXXX")"
BUILD_STAGING_ROOT=""
cleanup() {
  /bin/rm -rf -- "$SOURCE_SNAPSHOT"
  [[ -z "$BUILD_STAGING_ROOT" || ! -e "$BUILD_STAGING_ROOT" ]] ||
    /bin/rm -rf -- "$BUILD_STAGING_ROOT"
}
trap cleanup EXIT

source_inputs=(
  "$ROOT/../MacPlusPlusCore/MacPlusPlusPureLogic.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusRuntimeBoundaries.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusPaletteCatalog.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusSoftLockConfiguration.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusWallpaperFraming.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusSetupPlan.swift"
  "$ROOT/../MacPlusPlusCore/MacPlusPlusYabaiConfiguration.swift"
  "$ROOT/Sources/MacPlusPlusAudioSharedMemory.swift"
  "$ROOT/Sources/MacPlusPlusAudioSharedMemoryShim.c"
  "$ROOT/Sources/MacPlusPlusShellRuntimeIdentity.swift"
  "$ROOT/Sources/MacPlusPlusPublicDisabledServices.swift"
  "$ROOT/Sources/MacPlusPlusPublicSetupManager.swift"
  "$ROOT/Sources/MacPlusPlusWallpaperSourceModel.swift"
  "$ROOT/Sources/MacPlusPlusShellCommand.swift"
  "$ROOT/Sources/MacPlusPlusMediaControl.swift"
  "$ROOT/Sources/CaelestiaBlobMotion.swift"
  "$ROOT/Sources/CaelestiaParityTokens.swift"
  "$ROOT/Sources/CaelestiaParityGeometry.swift"
  "$ROOT/Sources/MacPlusPlusShell.swift"
  "$ROOT/Tools/macpp-wifi-scan.py"
  "$ROOT/../MacPlusPlusCast/Sources/MacPlusPlusPickerCatalog.swift"
  "$ROOT/../MacPlusPlusCast/Sources/MacPlusPlusCast.swift"
)
for input in "${source_inputs[@]}"; do
  cp "$input" "$SOURCE_SNAPSHOT/${input##*/}"
done

SHIM_OBJECT="$SOURCE_SNAPSHOT/MacPlusPlusAudioSharedMemoryShim.o"
BUILD_STAGING_ROOT="$(mktemp -d "$BUILD_ROOT/.macpp-caelestia-shell-build.XXXXXX")"
STAGED_APP="$BUILD_STAGING_ROOT/$app_name"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
xcrun clang -O2 -c -isysroot "$(xcrun --show-sdk-path)" \
  "$SOURCE_SNAPSHOT/MacPlusPlusAudioSharedMemoryShim.c" -o "$SHIM_OBJECT"
swift_defines=(-D MACPPCAST_EMBEDDED -D MACPP_CAELESTIA_SHELL)
if [[ "${MACPP_PUBLIC_RELEASE:-0}" == 1 ]]; then
  swift_defines+=(-D MACPP_PUBLIC_RELEASE)
fi
if (( production_profile )); then
  swift_defines+=(-D MACPP_CAELESTIA_PRODUCTION)
fi
swiftc_warning_flags=()
if [[ "${MACPP_ALLOW_WARNINGS:-0}" != 1 ]]; then
  swiftc_warning_flags=(-warnings-as-errors)
fi
xcrun swiftc -O -whole-module-optimization -parse-as-library "${swiftc_warning_flags[@]}" "${swift_defines[@]}" \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework AuthenticationServices -framework Security -framework CoreGraphics -framework CoreAudio -framework AudioToolbox -framework QuartzCore -framework CoreWLAN -framework CoreLocation -framework IOBluetooth -framework Carbon -framework ImageIO -framework UniformTypeIdentifiers \
  "$SOURCE_SNAPSHOT/MacPlusPlusPureLogic.swift" "$SOURCE_SNAPSHOT/MacPlusPlusRuntimeBoundaries.swift" "$SOURCE_SNAPSHOT/MacPlusPlusPaletteCatalog.swift" "$SOURCE_SNAPSHOT/MacPlusPlusSoftLockConfiguration.swift" "$SOURCE_SNAPSHOT/MacPlusPlusWallpaperFraming.swift" "$SOURCE_SNAPSHOT/MacPlusPlusAudioSharedMemory.swift" "$SOURCE_SNAPSHOT/MacPlusPlusShellRuntimeIdentity.swift" "$SOURCE_SNAPSHOT/MacPlusPlusPublicDisabledServices.swift" "$SOURCE_SNAPSHOT/MacPlusPlusWallpaperSourceModel.swift" "$SOURCE_SNAPSHOT/MacPlusPlusShellCommand.swift" "$SOURCE_SNAPSHOT/MacPlusPlusMediaControl.swift" "$SOURCE_SNAPSHOT/CaelestiaBlobMotion.swift" "$SOURCE_SNAPSHOT/CaelestiaParityTokens.swift" "$SOURCE_SNAPSHOT/CaelestiaParityGeometry.swift" "$SOURCE_SNAPSHOT/MacPlusPlusSetupPlan.swift" "$SOURCE_SNAPSHOT/MacPlusPlusYabaiConfiguration.swift" "$SOURCE_SNAPSHOT/MacPlusPlusPublicSetupManager.swift" "$SOURCE_SNAPSHOT/MacPlusPlusShell.swift" "$SOURCE_SNAPSHOT/MacPlusPlusPickerCatalog.swift" "$SOURCE_SNAPSHOT/MacPlusPlusCast.swift" "$SHIM_OBJECT" -o "$STAGED_APP/Contents/MacOS/$executable_name"
cp "$ROOT/Tools/macpp-wifi-scan.py" "$STAGED_APP/Contents/Resources/macpp-wifi-scan.py"
cp "$ROOT/../../bin/macpp-wallpaper-source" "$STAGED_APP/Contents/Resources/macpp-wallpaper-source"
chmod 755 "$STAGED_APP/Contents/Resources/macpp-wallpaper-source"
chmod 755 "$STAGED_APP/Contents/Resources/macpp-wifi-scan.py"
cp "$ROOT/../../bin/macpp-media-control" "$STAGED_APP/Contents/Resources/macpp-media-control"
chmod 755 "$STAGED_APP/Contents/Resources/macpp-media-control"
"$ROOT/../../apps/MacPlusPlusScreen/build-color-picker.sh" \
  --output "$STAGED_APP/Contents/Resources/macpp-color-picker"
cp "$ROOT/Info.plist" "$STAGED_APP/Contents/Info.plist"
if (( production_profile )); then
  legacy_domain_parts=(org macplusplus shell)
  legacy_domain="${(j:.:)legacy_domain_parts}"
  plutil -replace CFBundleExecutable -string "$executable_name" "$STAGED_APP/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$legacy_domain" "$STAGED_APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "$executable_name" "$STAGED_APP/Contents/Info.plist"
fi
if ! plutil -extract NSBluetoothAlwaysUsageDescription raw -o - \
  "$STAGED_APP/Contents/Info.plist" >/dev/null 2>&1; then
  print -u2 "Mac++ Caelestia Shell build: NSBluetoothAlwaysUsageDescription is missing"
  exit 1
fi
cp "$ROOT/../../config/palettes.json" "$STAGED_APP/Contents/Resources/palettes.json"
cp "$ROOT/../MacPlusPlusCast/Resources/MacPlusPlusPickerCatalog.json" "$STAGED_APP/Contents/Resources/MacPlusPlusPickerCatalog.json"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
# macpp:silent-ok the staged bundle has been published; a leftover empty build parent is harmless cleanup debt.
rmdir "$BUILD_STAGING_ROOT" 2>/dev/null || true
BUILD_STAGING_ROOT=""
echo "$APP"
