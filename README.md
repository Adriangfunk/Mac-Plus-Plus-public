# Mac++

Mac++ is a customizable macOS shell with Search, system controls, wallpaper and palette tools, and optional window-management integrations.

This repository is the curated public source release. It contains no machine-specific settings, account credentials, local history, external project checkouts, or generated app bundles. The default setup is a plan preview: building this source does not install or launch Mac++ or change macOS privacy or startup settings.

## Setup manager

The Shell includes a setup manager for choosing a capability set and reviewing the resulting plan. It covers Wi-Fi scans, Bluetooth, location-aware features, native notification settings, one-shot screen capture, audio visualization, Accessibility actions, and yabai tiers.

Notifications remain native macOS notifications. Mac++ does not read their contents or suppress banners. Each optional capability explains what is omitted when it is off and when macOS may ask for access. The advanced yabai scripting-addition tier explains its RecoveryOS and SIP tradeoff; the manager never changes SIP.

## Optional app integrations

Spotify media transport remains optional and works without account linking. Spotify queue access that requires account authorization is not included in this public profile. Discord is optionally recognized in the app and media surfaces; it does not require a bot, webhook, or bundled account data. Mac++ remains usable without either app.

## Build for review

Requirements: macOS 14 or newer and Xcode Command Line Tools.

```sh
./bin/macpp-public-release-check
MACPP_PUBLIC_RELEASE=1 MACPP_CAELESTIA_PRODUCTION=1 MACPP_ALLOW_ADHOC=1 MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY=- ./Source/MacPlusPlusCaelestiaShell/build.sh
```

The build stages the app under `build/Mac++ Shell.app`. The commands above do not open the app, install it, load a LaunchAgent, grant permissions, or change startup security. Use a stable signing identity for a release that you intend to install later.

See [the public profile and capability notes](docs/public-shell.md) before enabling optional integrations.
