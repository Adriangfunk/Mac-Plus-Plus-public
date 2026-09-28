# Mac++

Mac++ brings a customizable shell to macOS: a quick app and file search, the
Nexus system dashboard, workspace controls, media, connectivity, and wallpaper
tools share one consistent desktop surface. Pick the capabilities you want in
Setup Manager, review what each choice changes, and keep the rest of macOS in
charge of its own permissions and security settings.

## What you can do

- **Search from your desktop.** Find apps, files, open windows, and built-in
  actions without keeping a separate launcher open.
- **Check the whole system in Nexus.** See live system and battery status,
  storage, network controls, media, and desktop tools in one dashboard.
- **Shape the desktop.** Switch color palettes, import ultrawide still images,
  preview local videos, and choose a wallpaper. Still images are applied with
  macOS directly. Without the separate wallpaper companion, a selected video
  uses its poster frame as the desktop image.
- **Arrange workspaces.** With optional yabai, drag a window to another space
  for a one-time move. Secondary-click a window row to assign its app to a
  workspace for future windows. Mac++ stores those rules locally for the
  current user.
- **Choose how far to configure.** Setup Manager describes Wi-Fi, Bluetooth,
  location, notification settings, one-shot screen capture, audio
  visualization, Accessibility, and yabai before you enable a capability.

## Optional integrations and dependencies

| Integration | What it does | If it is not installed or enabled |
| --- | --- | --- |
| yabai | Reads spaces, moves windows, and applies app-to-space rules. | Mac++ keeps working with normal macOS window behavior. yabai is installed separately. |
| blueutil | Adds nearby Bluetooth discovery and a paired-device fallback when available. | Native paired/recent-device and connection controls remain available; nearby discovery may be limited. |
| Spotify | Offers optional media transport; account authorization is only used for queue features. | Other media sources and the rest of Mac++ continue to work. |
| Discord | Recognizes the app in app and media surfaces. | No Discord-specific surface is shown. No bot, webhook, or account data is used. |
| Wallpaper companion | Provides animated desktop playback when separately installed. | Stills switch natively; videos fall back to a still poster. The companion app is not part of this source release. |
| Lock-screen wallpaper helper | Updates lock-screen wallpaper when separately installed. | Lock-screen changes are not included in this source release; the importer reports when the helper is unavailable. |
| Homebrew | Nexus can show whether installed formulae and casks have updates. | Package status is omitted; Mac++ does not install or update packages. |

Mac++ also uses macOS tools and frameworks already on the system. Weather and
Wallhaven wallpaper search use their public network services when those
features are opened. Mac++ has no telemetry service, bundled account
credentials, or external project checkout in this release.

## Privacy and security

The dashboard uses a generic system icon; it does not display the local
account name or search the user's photo/download folders for a profile image.
The default setup is a reviewable plan. It does not install packages, load
LaunchAgents, request privacy access, or change startup security. Notifications
remain native macOS notifications: Mac++ does not read their contents, mirror
them, or suppress banners.

Current yabai releases can move windows between spaces while SIP stays enabled.
Some additional yabai features use a scripting addition and require a manual
partial security-policy change from RecoveryOS. That lowers protection for the
privileged operations it enables. Mac++ never changes SIP or configures
sudoers. Read the [public capability notes](docs/public-shell.md) before
choosing an optional integration.

## Build a review copy

Requirements: macOS 14 or newer and Xcode Command Line Tools.

Run the source-release checks:

```sh
./tests/run-public
```

Build a disposable, ad-hoc signed copy for review:

```sh
MACPP_PUBLIC_RELEASE=1 MACPP_CAELESTIA_PRODUCTION=1 MACPP_ALLOW_ADHOC=1 MACPP_CAELESTIA_SHELL_SIGNING_IDENTITY=- ./Source/MacPlusPlusCaelestiaShell/build.sh
```

The app is staged at `build/Mac++ Shell.app`; the build command does not open
or install it. Ad-hoc signatures are for review only and are not suitable for
retaining macOS privacy permissions across updates. A release intended for
regular use needs a stable signing identity.
