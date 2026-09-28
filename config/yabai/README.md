# yabai integration

yabai is an optional, separately installed window manager. Mac++ uses it for
space and window queries, drag-to-move, and saved per-app workspace rules. If
yabai is absent or not enabled in Setup Manager, the rest of the Shell remains
available and workspace actions stay out of the plan.

Recent yabai releases support moving windows between spaces with SIP enabled.
Mac++ sends numeric space selectors, so the five workspace actions do not
depend on custom yabai labels. Older yabai versions or macOS releases may have
different limits; check the [current yabai changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md)
and [command reference](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc#rule).

After installing yabai separately, source the optional Mac++ rules from the
user's yabairc:

```sh
source "${MACPP_ROOT:?Set MACPP_ROOT to the repository path}/config/yabai/macpp-shell.yabairc"
```

These rules only keep Mac++ windows out of yabai's tiling layout. They do not
install or start yabai, change SIP, configure sudoers, or load a scripting
addition. Window rows can be dragged to move one window; secondary-click a row
to create a persistent rule that sends future windows from that app to the
chosen space. Mac++ saves that preference in the current user's local
preferences and reapplies it when the Shell starts or first detects yabai spaces.

The scripting addition unlocks some extra privileged window and space
operations. It requires a manual partial startup-security change from
RecoveryOS on supported systems. That reduces protections for those
operations. Mac++ does not make the change; review the current [yabai
installation guide](https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release))
and [Apple startup security guidance](https://support.apple.com/en-ca/guide/security/sec7d92dc49f/web)
before choosing it. Basic Mac++ workspace moves do not ask you to disable SIP.
