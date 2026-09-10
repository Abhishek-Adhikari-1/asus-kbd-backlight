# ASUS Keyboard Backlight Idle Timeout for Omarchy

A lightweight Omarchy user plugin that turns off the ASUS keyboard backlight after a configurable period of inactivity and restores the exact previous brightness level when activity resumes.

## Features

* Automatically turns off the ASUS keyboard backlight after inactivity.
* Restores the exact brightness level that was active before idle.
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
* `brightnessctl`
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

The configuration file is watched for changes. If a configuration change does not take effect immediately, restart the Omarchy shell:

```bash
omarchy restart shell
```

## How it works

The plugin monitors user idle state through Quickshell's native Wayland idle monitoring.

When the configured idle timeout is reached:

1. The current keyboard backlight brightness is read.
2. That brightness is stored in memory.
3. The keyboard backlight is set to `0`.

When user activity resumes:

1. The stored brightness is restored.
2. The saved state is cleared.

The plugin does not assume a particular brightness range. It reads the hardware's available brightness values through the Linux LED interface.

If the keyboard backlight was already at `0` when the idle timeout occurred, it remains `0` when activity resumes.

## Safety and limitations

* Brightness state is stored only in memory.
* Restarting the Omarchy shell or plugin clears the pending restore state.
* After a restart, the plugin does not attempt to restore a stale brightness value.
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
cat /sys/class/leds/asus::kbd_backlight/brightness
```

Check the maximum brightness supported by the hardware:

```bash
cat /sys/class/leds/asus::kbd_backlight/max_brightness
```

Check whether `brightnessctl` is installed:

```bash
command -v brightnessctl
```

Check whether Omarchy has loaded the plugin:

```bash
omarchy-shell shell listPlugins
```

If the ASUS keyboard LED is not present under `/sys/class/leds/`, this plugin cannot control the keyboard backlight on that system.

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
