# Public release notes

Mac++ combines a macOS shell, Search, and the Nexus dashboard. The public
source includes system and media surfaces, Wi-Fi and Bluetooth controls,
palette and wallpaper tools, one-shot capture, generic audio visualization,
and optional yabai support. This is a source release: it contains no generated
app bundle, machine-specific configuration, account credentials, local
history, private telemetry, vendor-device agent, or external project
checkout.

## Setup Manager

Setup Manager lets people choose capabilities and review a setup plan. The
current public build does not install packages, load LaunchAgents, grant macOS
permissions, or change startup security. Each capability describes its macOS
access needs and what is left out when it is not selected.

| Capability | When enabled | When left off |
| --- | --- | --- |
| Wi-Fi | Shows status and offers user-invoked controls. Nearby scans may require Location Services. | Wi-Fi controls and scans are omitted. |
| Bluetooth | Shows paired devices and offers explicit device actions; macOS may request access on first use. | Bluetooth controls are omitted. |
| Location-aware features | Allows selected features to use location through macOS privacy controls. | Location access is not requested by those features. |
| Notification settings | Adds a shortcut to macOS Notification settings. | Native macOS delivery is unchanged; only the shortcut is omitted. |
| One-shot screen capture | Adds explicit capture actions; macOS asks when capture is invoked. | Capture actions are omitted. Continuous recording is not included. |
| Audio visualization | Allows the optional local visualizer; macOS asks for audio-capture consent when it starts. | The audio helper is omitted. |
| Accessibility actions | Allows selected window and input actions; macOS may request Accessibility or Input Monitoring. | Panels, Search, and non-Accessibility controls remain available. |
| yabai | Adds optional workspace queries, window moves, and saved per-app workspace rules. | Mac++ uses ordinary macOS window behavior. |

Notifications stay in macOS. Mac++ does not read their contents, mirror them,
or suppress banners.

## Wallpapers and companion tools

Static image selection works without a separate renderer: Mac++ calls Apple's
native [NSWorkspace desktop-image API](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29)
for connected displays. Video cards can be previewed in the carousel; when no
animated wallpaper companion is installed, Mac++ extracts a still poster frame
and applies it as the desktop image. The poster is cached under the current
user's `~/Library/Application Support/MacPlusPlus/NativePosters` directory.

The animated desktop renderer and the lock-screen wallpaper helper are
separate programs and are not bundled in this public source release. The Shell
continues to send the companion palette and catalog notifications when an
external renderer is installed in `~/Applications` or `/Applications`. Without
that renderer, still switching remains available and video falls back to a
poster. Lock-screen changes are not made by this release; Wallhaven imports
report when the optional lock-screen helper is unavailable.

The bundled Wallhaven helper downloads user-selected images over HTTPS and
checks media hosts, file type, dimensions, and size before importing to the
managed wallpaper library. Wallhaven requires network access only when its
search/import flow is used. Weather uses the Open-Meteo public API when weather
is requested. No private API token is bundled.

## yabai and startup security

Install yabai separately. Mac++ does not install or start it. In current
yabai, space focus and window moves work with SIP enabled; the yabai v7.1.25
changelog specifically records window moves between spaces working with SIP
enabled again. Older yabai/macOS combinations may behave differently. See the
[current changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md)
and [rule/command reference](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc#rule).

The standard tier keeps SIP enabled and supports Mac++'s basic space actions
with a compatible yabai release. The separate scripting addition enables some
additional privileged controls and requires a manual partial security-policy
change from RecoveryOS on supported systems. That reduces protections for the
privileged operations it enables. Mac++ never disables or changes SIP,
configures sudoers, or loads the scripting addition. Read [Apple's startup
security guidance](https://support.apple.com/en-ca/guide/security/sec7d92dc49f/web)
and yabai's current installation guide before choosing the advanced tier.

The optional rules in `config/yabai/macpp-shell.yabairc` only mark Mac++
windows as unmanaged so yabai does not tile them. Window rows support a
one-time drag to a workspace. Secondary-clicking a row can save a named-app
assignment; Mac++ saves it in local macOS preferences and reapplies the rule
when the Shell starts or first detects yabai spaces. These rules do not change SIP
or run privileged commands.

## Optional app integrations

Spotify transport and Discord app/media recognition are optional. Spotify
queue features that require account authorization are not included in this
public profile. Discord needs no bot, webhook, or account data. Homebrew is
only queried for Nexus update status; Mac++ does not install or update its
packages.

## Review build

Requirements: macOS 14 or newer and Xcode Command Line Tools.

Run the public-source checks:

```sh
./tests/run-public
```

Build a review copy without opening or installing it:

```sh
MACPP_PUBLIC_RELEASE=1 MACPP_CAELESTIA_PRODUCTION=1 MACPP_ALLOW_ADHOC=1 MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY=- ./Source/MacPlusPlusCaelestiaShell/build.sh
```

The app is staged under the ignored `build/` directory. Ad-hoc signing is for
disposable review only; regular use and stable macOS privacy permissions need
a stable signing identity.
