# Public profile

The public branch is a curated source release of Mac++ Shell and Search. It keeps the core interface, palette and wallpaper controls, media and system status, Wi-Fi and Bluetooth controls, one-shot capture tools, generic audio visualization, and optional yabai rules.

The repository contains source and review tooling only. It has no machine-specific configuration, user history, account credentials, notification database reader, clipboard-history store, vendor checkout, external wallpaper-engine checkout, or generated application binary. Builds remain in the ignored `build/` directory.

## Setup choices

The setup manager stores local selections and shows a plan. It does not install packages, start helpers, load LaunchAgents, request privacy permissions, or modify system security.

| Capability | If enabled | If left off |
| --- | --- | --- |
| Wi-Fi | Adds Wi-Fi status and user-invoked controls. Nearby-network scans have a separate opt-in and may require Location Services; saved passwords remain in macOS. | The Shell remains usable; Wi-Fi status, scans, and controls are omitted from the plan. |
| Bluetooth | Adds paired-device status and user-invoked device actions. macOS may ask for Bluetooth access when those controls are first used. | Other Shell features continue; Bluetooth controls are omitted. |
| Location-aware features | Allows optional location-based functions. macOS controls the grant. | Location-based functions are excluded from the plan. |
| Notification settings | Adds a shortcut to macOS Notification settings. Mac++ never reads notification contents, mirrors notifications, or suppresses native banners. | macOS notifications continue as usual; only the Mac++ settings shortcut is omitted. |
| One-shot screen capture | Adds explicit capture tools; macOS asks when a capture is invoked. | Capture tools are omitted; no continuous recording is included in either plan. |
| Audio visualization | Adds the generic local visualizer. macOS audio-capture consent is needed when the helper is started. | No audio helper is included. |
| Accessibility actions | Adds selected window and input actions that can request Accessibility or Input Monitoring access when used. | Panels, Search, and non-Accessibility controls remain available. |
| yabai | Adds optional window and workspace integration. | Mac++ uses normal macOS window behavior. |

## yabai tiers and SIP

The manager offers four presets: Core, System controls, Window management, and Advanced. Each preset fills a plan that can be reviewed before any future installer is used.

- **No yabai:** no yabai package, service, or rules.
- **Standard yabai:** install and configure yabai separately; approve Accessibility as needed. Keep SIP enabled. Scripting-addition features remain unavailable.
- **Advanced scripting addition:** selected only through the Advanced preset. yabai requires a manual security-policy change from RecoveryOS for its scripting addition on supported setups. That weakens macOS protections and enables additional privileged window and space operations. Mac++ does not disable SIP, configure sudoers, or load the scripting addition.

Apple requires RecoveryOS for changes that reduce Apple silicon startup security. Review [Apple’s startup security policy guidance](https://support.apple.com/en-ca/guide/security/sec7d92dc49f/web) and [yabai’s installation notes](https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release)) before choosing the advanced tier.

The included yabai rules are opt-in and do not install or launch yabai:

```sh
source "${MACPP_ROOT:?Set MACPP_ROOT to the repository path}/config/yabai/macpp-shell.yabairc"
```

## Optional app integrations

Spotify transport controls and Discord app/media recognition are optional and are not prerequisites for using the Shell. The public source does not include Spotify account authorization or authenticated queue access, and it contains no Spotify or Discord credentials.

## Review build

Run the static release checks:

```sh
./tests/run-public
```

To stage the public Shell app without opening or installing it:

```sh
MACPP_PUBLIC_RELEASE=1 MACPP_CAELESTIA_PRODUCTION=1 MACPP_ALLOW_ADHOC=1 MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY=- ./Source/MacPlusPlusCaelestiaShell/build.sh
```

The staged app is written under the ignored repository-level `build/` directory. Do not load it or enable an optional feature until you have reviewed the plan and the requested macOS access.
