import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
  id: root

  readonly property int defaultIdleTimeoutSeconds: 30
  readonly property int minimumIdleTimeoutSeconds: 1
  readonly property int maximumIdleTimeoutSeconds: 86400
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/asus-kbd-backlight/config.json"
  property int idleTimeoutSeconds: defaultIdleTimeoutSeconds
  property string device: ""
  property string brightnessPath: ""
  property int maximumBrightness: -1
  property int savedBrightness: -1
  property bool readPending: false
  property bool restoreAfterOff: false
  property bool unavailableLogged: false

  function log(message) { console.log("omarchy asus-kbd-backlight: " + message) }
  function validInteger(value) { return typeof value === "number" && isFinite(value) && Math.floor(value) === value }
  function parseBrightness(text) {
    var value = String(text).trim()
    if (!/^[0-9]+$/.test(value)) return -1
    var level = Number(value)
    return validInteger(level) && level >= 0 && level <= maximumBrightness ? level : -1
  }
  function loadConfig() {
    var timeout = defaultIdleTimeoutSeconds
    try {
      var value = JSON.parse(configFile.text()).idleTimeoutSeconds
      if (!validInteger(value) || value < minimumIdleTimeoutSeconds || value > maximumIdleTimeoutSeconds)
        throw new Error("out of range")
      timeout = value
    } catch (error) {
      log("invalid configuration; using default timeout " + defaultIdleTimeoutSeconds + "s")
    }
    idleTimeoutSeconds = timeout
  }
  function clearSavedState() { savedBrightness = -1; restoreAfterOff = false }
  function onIdleChanged() {
    if (idleMonitor.isIdle) {
      if (!device || maximumBrightness < 1 || savedBrightness >= 0 || readPending || brightnessReader.running) return
      readPending = true
      brightnessReader.running = true
    } else {
      restore()
    }
  }
  function readBrightness(line) {
    if (!readPending) return
    readPending = false
    var level = parseBrightness(line)
    if (level < 0) { log("failed to read a valid keyboard brightness"); return }
    if (!idleMonitor.isIdle || level === 0) return
    savedBrightness = level
    log("idle timeout reached; saved brightness " + level)
    keyboardOff.running = true
  }
  function restore() {
    if (savedBrightness < 0) return
    if (keyboardOff.running) { restoreAfterOff = true; return }
    if (keyboardRestore.running) return
    keyboardRestore.command = ["brightnessctl", "--device", device, "set", String(savedBrightness)]
    keyboardRestore.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig()
    onLoadFailed: root.loadConfig()
    onFileChanged: reload()
  }
  IdleMonitor {
    id: idleMonitor
    enabled: root.device.length > 0 && root.maximumBrightness >= 1
    timeout: root.idleTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: root.onIdleChanged()
  }
  Process {
    id: detectDevice
    command: ["bash", "-c", "for p in /sys/class/leds/asus::*kbd*backlight*; do [ -r \"$p/brightness\" ] && [ -r \"$p/max_brightness\" ] || continue; basename \"$p\"; exit 0; done; exit 1"]
    stdout: SplitParser { onRead: function(line) { root.device = String(line).trim(); root.brightnessPath = "/sys/class/leds/" + root.device + "/brightness"; maximumReader.command = ["cat", "/sys/class/leds/" + root.device + "/max_brightness"]; maximumReader.running = true } }
    onExited: function(code) { if (code !== 0 && !root.device && !root.unavailableLogged) { root.unavailableLogged = true; root.log("keyboard backlight device unavailable; service disabled") } }
  }
  Process {
    id: maximumReader
    stdout: SplitParser { onRead: function(line) { var value = String(line).trim(); if (/^[1-9][0-9]*$/.test(value)) { root.maximumBrightness = Number(value); root.log("using " + root.device + " (max brightness " + value + ")") } else root.log("invalid keyboard max brightness; service disabled") } }
  }
  Process {
    id: brightnessReader
    command: ["cat", root.brightnessPath]
    stdout: SplitParser { onRead: function(line) { root.readBrightness(line) } }
    onExited: function(code) { if (root.readPending) { root.readPending = false; root.log("failed to read keyboard brightness") } }
  }
  Process {
    id: keyboardOff
    command: ["brightnessctl", "--device", root.device, "set", "0"]
    onExited: function(code) { if (code !== 0) { root.log("failed to disable keyboard backlight"); root.clearSavedState() } else if (!idleMonitor.isIdle || root.restoreAfterOff) Qt.callLater(root.restore) }
  }
  Process {
    id: keyboardRestore
    onExited: function(code) { if (code !== 0) log("failed to restore keyboard backlight"); else log("activity resumed; restored brightness " + savedBrightness); root.clearSavedState() }
  }
  Component.onCompleted: { configFile.reload(); detectDevice.running = true }
}
