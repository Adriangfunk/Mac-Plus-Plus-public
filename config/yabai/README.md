# yabai integration

Mac++ works with yabai, but yabai is optional. The Shell uses read-only yabai
queries for workspace/window awareness and uses bounded commands for explicit
window actions. It falls back to ordinary macOS surfaces when yabai is absent.

After installing yabai separately, source the shipped rules from the user's
yabairc:

```sh
source "${MACPP_ROOT:?Set MACPP_ROOT to the Mac++ checkout}/config/yabai/macpp-shell.yabairc"
```

The rules only mark Mac++ surfaces as unmanaged and above/below the normal tile
layer. They do not install yabai, load its scripting addition, change SIP, or
start any Mac++ process. Re-source the file only when the user deliberately
wants to refresh those rules.

Window queries and moves may require yabai's scripting addition plus macOS
Accessibility permission. Mac++ cannot grant either permission; the user must
approve them in System Settings. If a scripting addition is not desired, the
Shell's connectivity, audio, Bluetooth, Wi-Fi, palette, and ordinary Search
features remain available.
