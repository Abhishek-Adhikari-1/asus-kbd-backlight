# ASUS Keyboard Backlight Idle Timeout for Omarchy

A lightweight Omarchy user plugin that turns off the ASUS keyboard backlight after a configurable period of inactivity and restores the exact previous brightness level when activity resumes.

## Features

* Automatically turns off the ASUS keyboard backlight after inactivity.
* Restores the exact brightness level that was active before idle.
* Survives a shell restart or a resume: a pending restore is recorded and recovered at startup, so the keyboard is never left dark with nothing to restore it from.
* Supports any brightness level exposed by the hardware; it does not assume brightness `1` or a maximum of `3`.
* Configurable idle timeout.
* Default timeout: **30 seconds**.
* Uses Quickshell's native Wayland idle monitoring.
* Respects Quickshell idle inhibitors.
* Independent of Omarchy's screensaver and lock timers.
* No `hypridle`, `swayidle`, systemd service, cron job, or external daemon required.
* Gracefully does nothing when a supported ASUS keyboard LED is unavailable.

### Example behavior

```text
1 → 0 → 1
2 → 0 → 2
3 → 0 → 3
0 → 0 → 0
```

The plugin saves the current brightness when the idle timeout is reached, sets the keyboard backlight to `0`, and restores the saved value when user activity resumes.

## Requirements

* [Omarchy](https://omarchy.org/)
* Quickshell
* `brightnessctl` at `/usr/bin/brightnessctl`
* An ASUS keyboard backlight exposed through the Linux LED subsystem

The plugin looks for an LED matching:

```text
asus::*kbd*backlight*
```

under:

```text
/sys/class/leds/
```

Hardware support therefore depends on the ASUS keyboard backlight being exposed by the Linux kernel/driver through the LED subsystem.

## Installation

Clone or copy the repository to:

```text
~/.config/omarchy/plugins/asus-kbd-backlight
```

Then rescan Omarchy plugins:

```bash
omarchy-shell shell rescanPlugins
```

Enable the plugin:

```bash
omarchy plugin enable asus-kbd-backlight
```

Restart the Omarchy shell:

```bash
omarchy restart shell
```

Verify that the plugin is loaded:

```bash
omarchy-shell shell listPlugins
```

## Configuration

The default configuration is:

```json
{
  "idleTimeoutSeconds": 30
}
```

Create or edit:

```text
~/.config/omarchy/plugins/asus-kbd-backlight/config.json
```

For example, to turn the keyboard backlight off after 60 seconds:

```json
{
  "idleTimeoutSeconds": 60
}
```

### Timeout limits

The following values are accepted:

* Minimum: `1` second
* Maximum: `86400` seconds (24 hours)
* Default: `30` seconds

Missing, malformed, non-integer, zero, negative, or out-of-range values fall back to the 30-second default.

### Recovery after a restart

While a restore is pending, the level is also written to:

```text
$XDG_RUNTIME_DIR/omarchy-asus-kbd-backlight.json
```

A shell restart — or Omarchy's hibernate hook, which turns the keyboard off without telling anyone — would otherwise leave the backlight dark forever, because the level to restore lived only in memory. At startup the plugin reads that record and restores the level when all of the following hold:

* the LED reads `0`, and
* the record is newer than `restoreGraceSeconds`.

A level already on the hardware always wins: if the LED reads anything above `0` at startup, the record is dropped untouched. The record is removed as soon as the level is back.

Add the setting to `config.json` to change the window:

```json
{
  "idleTimeoutSeconds": 30,
  "restoreGraceSeconds": 43200
}
```

* Default: `43200` (12 hours).
* Range: `0` to `604800` (7 days).
* `0` disables recovery: after a restart the plugin restores nothing.

The record is stored in the session's runtime directory, so it outlives a restart and a resume but not a logout, and it is removed on the next restore. As with any manual change made while the backlight is off, a level set by hand during that window is overridden by the recovered one.

### Configuration file safety

For safety, the plugin accepts the configuration only when it is a regular file owned by the user running the shell and is not writable by group or other users. Symlinks, inaccessible files, and files larger than 4096 bytes are rejected. Invalid or unsafe configuration always falls back to the 30-second default.

The file is read in a bounded operation before JSON is parsed. Its directory chain is opened without following symlinks, and its type, owner, permissions, and size are verified on the same retained file descriptor that is read. This prevents a configuration-file swap between validation and use. The validated timeout is applied before the native idle monitor is created, and configuration changes are re-read while the plugin is running.

If a configuration change does not take effect immediately, restart the Omarchy shell:

```bash
omarchy restart shell
```

## How it works

The plugin monitors user idle state through Quickshell's native Wayland idle monitoring.

It reads the keyboard LED's current and maximum brightness directly from sysfs, then invokes `/usr/bin/brightnessctl` only to change the keyboard backlight. Every helper process has a short deadline and is terminated, then killed if necessary.

When the configured idle timeout is reached:

1. The current keyboard backlight brightness is read.
2. That brightness is stored in memory.
3. The keyboard backlight is set to `0`.

The level is written to the runtime state file before the LED is touched, so a shell that restarts between the two steps is still covered.

When user activity resumes:

1. The stored brightness is restored.
2. The saved state is cleared.

The plugin does not assume a particular brightness range. It reads the hardware's available brightness values through the Linux LED interface.

If the keyboard backlight was already at `0` when the idle timeout occurred, it remains `0` when activity resumes.

## Safety and limitations

* A pending restore is held in memory and, until it is restored, in `$XDG_RUNTIME_DIR/omarchy-asus-kbd-backlight.json` (mode `0600`, written with `O_NOFOLLOW` and replaced atomically). It is removed as soon as the level is back or is found to be beside the point.
* That record outlives a shell restart and a resume but not a logout: after a logout there is nothing to restore from.
* Recovery never overrides the hardware: a level already on the LED wins, and the record is dropped instead.
* `restoreGraceSeconds` bounds how old a record may be and still be used; `0` disables recovery entirely.
* If the brightness is manually changed while the plugin has turned the keyboard backlight off, the saved pre-idle value is still the value restored when activity resumes.
* The plugin does not modify Omarchy's first-party idle configuration.
* The plugin does not modify files under `/usr/share/omarchy`.
* The plugin does not control Omarchy's screensaver or lock behavior.

## Troubleshooting

Check whether the ASUS keyboard LED is available:

```bash
ls /sys/class/leds/
```

Look for an entry similar to:

```text
asus::kbd_backlight
```

Check the current brightness:

```bash
/usr/bin/cat /sys/class/leds/asus::kbd_backlight/brightness
```

Check the maximum brightness supported by the hardware:

```bash
/usr/bin/cat /sys/class/leds/asus::kbd_backlight/max_brightness
```

Check whether `brightnessctl` is installed:

```bash
command -v brightnessctl
```

Check whether Omarchy has loaded the plugin:

```bash
omarchy-shell shell listPlugins
```

Check whether a restore is still owed after a restart:

```bash
/usr/bin/cat "${XDG_RUNTIME_DIR}/omarchy-asus-kbd-backlight.json"
```

The file exists only while a restore is pending: it is written when the idle timeout turns the keyboard off, and removed as soon as the level is back. A leftover record with the backlight on is dropped at the next start.

If the ASUS keyboard LED is not present under `/sys/class/leds/`, this plugin cannot control the keyboard backlight on that system.

For runtime diagnostics, inspect the Quickshell log for messages beginning with:

```text
omarchy asus-kbd-backlight:
```

Normal startup reports configuration loading, LED detection, the detected maximum brightness, and IdleMonitor activation. Idle transitions report the saved brightness, keyboard-off action, and restored brightness.

## Uninstall

Disable the plugin:

```bash
omarchy plugin disable asus-kbd-backlight
```

Remove the plugin:

```bash
rm -rf ~/.config/omarchy/plugins/asus-kbd-backlight
```

Then rescan plugins:

```bash
omarchy-shell shell rescanPlugins
```

## License

This project is licensed under the [MIT License](LICENSE).
