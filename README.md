# ASUS Keyboard Backlight Idle

A lightweight Omarchy user plugin that turns off the ASUS keyboard backlight after a configurable period of inactivity and restores the exact previous brightness level when activity resumes.

## Requirements

Omarchy with Quickshell, `brightnessctl`, and an ASUS keyboard LED exposed by Linux as an entry matching `asus::*kbd*backlight*` under `/sys/class/leds/`.

## Install and enable

Place this repository at `~/.config/omarchy/plugins/asus-kbd-backlight`, then run:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable asus-kbd-backlight
omarchy restart shell
```

## Configuration

Edit `config.json`:

```json
{ "idleTimeoutSeconds": 60 }
```

The default is 30 seconds. Only integer values from 1 through 86400 are accepted; absent, malformed, or invalid configuration safely uses 30 seconds. The file is watched. If a change does not apply immediately, run `omarchy restart shell`.

## Safety and limitations

The plugin respects Quickshell idle inhibitors and is independent of Omarchy screensaver and lock timers. It stores a pending restore only in memory: after a shell/plugin restart, it leaves hardware untouched rather than restoring a stale value. If brightness is manually changed while the keyboard is idle-off, the saved pre-idle value remains the value restored on activity.

## Troubleshooting and uninstall

```bash
ls /sys/class/leds/
cat /sys/class/leds/asus::kbd_backlight/brightness
cat /sys/class/leds/asus::kbd_backlight/max_brightness
omarchy-shell shell listPlugins
```

```bash
omarchy plugin disable asus-kbd-backlight
rm -rf ~/.config/omarchy/plugins/asus-kbd-backlight
omarchy-shell shell rescanPlugins
```
