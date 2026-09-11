import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: root

    readonly property int defaultIdleTimeoutSeconds: 30
    readonly property int minimumIdleTimeoutSeconds: 1
    readonly property int maximumIdleTimeoutSeconds: 86400
    readonly property int maximumConfigBytes: 4096
    readonly property int processDeadlineMs: 2000
    readonly property int processKillGraceMs: 500
    readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/asus-kbd-backlight/config.json"
    property int idleTimeoutSeconds: defaultIdleTimeoutSeconds
    property string userId: ""
    property string device: ""
    property string ledPath: ""
    property string brightnessPath: ""
    property string maximumBrightnessPath: ""
    property int maximumBrightness: -1
    property int savedBrightness: -1
    property bool readPending: false
    property bool restoreAfterOff: false
    property bool unavailableLogged: false
    property bool configErrorLogged: false
    property bool configMetadataValid: false
    property bool idleMonitorReady: false
    property bool idleMonitorRecreating: false
    property QtObject idleMonitorObject: null
    property bool keyboardIsIdle: idleMonitorObject !== null && idleMonitorObject.isIdle

    function log(message) {
        console.log("omarchy asus-kbd-backlight: " + message);
    }

    function validInteger(value) {
        return typeof value === "number" && isFinite(value) && Math.floor(value) === value;
    }

    function parseBrightness(text) {
        var value = String(text).trim();
        if (!/^[0-9]+$/.test(value))
            return -1;

        var level = Number(value);
        return validInteger(level) && level >= 0 && level <= maximumBrightness ? level : -1;
    }

    function useDefaultConfig() {
        applyIdleTimeout(defaultIdleTimeoutSeconds);
        if (!configErrorLogged) {
            configErrorLogged = true;
            log("invalid configuration; using default timeout " + defaultIdleTimeoutSeconds + "s");
        }
    }

    function loadConfig(text) {
        try {
            var value = JSON.parse(text).idleTimeoutSeconds;
            if (!validInteger(value) || value < minimumIdleTimeoutSeconds || value > maximumIdleTimeoutSeconds)
                throw new Error("out of range");

            applyIdleTimeout(value);
            configErrorLogged = false;
            log("configuration loaded; idle timeout " + value + "s");
        } catch (error) {
            useDefaultConfig();
        }
    }

    function applyIdleTimeout(value) {
        var changed = idleTimeoutSeconds !== value;
        idleTimeoutSeconds = value;
        if (!idleMonitorReady) {
            idleMonitorReady = true;
        } else if (changed) {
            idleMonitorRecreating = true;
            idleMonitorReady = false;
            idleMonitorObject = null;
            Qt.callLater(function() {
                idleMonitorReady = true;
            });
        }
    }

    function clearSavedState() {
        savedBrightness = -1;
        restoreAfterOff = false;
    }

    function stopProcess(process, deadline, killGrace) {
        deadline.stop();
        killGrace.stop();
        if (process.running)
            process.signal(9);

    }

    function beginConfigLoad() {
        configMetadataValid = false;
        if (!userId || configStat.running || configReader.running)
            return ;

        log("checking configuration");
        configStat.running = true;
    }

    function configMetadataIsSafe(line) {
        var fields = String(line).trim().split("|");
        if (fields.length !== 4 || fields[0] !== "regular file" || fields[1] !== userId || !/^[0-7]{3,4}$/.test(fields[2]) || !/^[0-9]+$/.test(fields[3]))
            return false;

        var mode = parseInt(fields[2], 8);
        var size = Number(fields[3]);
        return (mode & 18) === 0 && validInteger(size) && size >= 0 && size <= maximumConfigBytes;
    }

    function handleIdleStateChange() {
        log("idle event received; isIdle=" + keyboardIsIdle);
        if (keyboardIsIdle) {
            if (!device || maximumBrightness < 1 || savedBrightness >= 0 || readPending)
                return ;

            readPending = true;
            brightnessFile.reload();
        } else {
            restore();
        }
    }

    function readBrightness(text) {
        if (!readPending)
            return ;

        readPending = false;
        var level = parseBrightness(text);
        if (level < 0) {
            log("failed to read a valid keyboard brightness");
            return ;
        }
        if (!keyboardIsIdle || level === 0)
            return ;

        savedBrightness = level;
        log("idle timeout reached; saved brightness " + level);
        keyboardOff.running = true;
    }

    function restore() {
        if (savedBrightness < 0)
            return ;

        if (keyboardOff.running) {
            restoreAfterOff = true;
            return ;
        }
        if (keyboardRestore.running)
            return ;

        log("activity resumed; restoring brightness " + savedBrightness);
        keyboardRestore.command = ["/usr/bin/brightnessctl", "--device", device, "set", String(savedBrightness)];
        keyboardRestore.running = true;
    }

    onKeyboardIsIdleChanged: {
        if (!idleMonitorRecreating)
            handleIdleStateChange();

    }
    Component.onCompleted: {
        log("service initialized");
        userIdReader.running = true;
        detectDevice.running = true;
    }

    FileView {
        id: configWatcher

        path: root.configPath
        blockAllReads: true
        watchChanges: true
        printErrors: false
        onFileChanged: root.beginConfigLoad()
    }

    FileView {
        id: brightnessFile

        path: root.brightnessPath
        preload: true
        printErrors: false
        onLoaded: root.readBrightness(text())
        onLoadFailed: {
            if (root.readPending) {
                root.readPending = false;
                root.log("failed to read keyboard brightness");
            }
        }
    }

    FileView {
        id: maximumBrightnessFile

        path: root.maximumBrightnessPath
        preload: true
        printErrors: false
        onLoaded: {
            var value = String(text()).trim();
            if (/^[1-9][0-9]*$/.test(value)) {
                root.maximumBrightness = Number(value);
                root.log("using " + root.ledPath + " (max brightness " + value + ")");
                if (root.keyboardIsIdle)
                    root.handleIdleStateChange();

            } else {
                root.log("invalid keyboard max brightness; service disabled");
            }
        }
        onLoadFailed: root.log("failed to read keyboard max brightness; service disabled")
    }

    Loader {
        id: idleMonitorLoader

        active: root.idleMonitorReady
        sourceComponent: idleMonitorComponent
        onLoaded: {
            root.idleMonitorObject = item;
            root.idleMonitorRecreating = false;
            root.log("IdleMonitor enabled; timeout " + root.idleTimeoutSeconds + "s");
            if (root.keyboardIsIdle)
                root.handleIdleStateChange();

        }
    }

    Component {
        id: idleMonitorComponent

        IdleMonitor {
            enabled: true
            timeout: root.idleTimeoutSeconds
            respectInhibitors: true
        }

    }

    Process {
        id: userIdReader

        command: ["/usr/bin/id", "-u"]
        onRunningChanged: {
            if (running) {
                userIdDeadline.restart();
            } else {
                userIdDeadline.stop();
                userIdKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0 || !root.userId)
                root.useDefaultConfig();
            else
                root.beginConfigLoad();
        }

        stdout: SplitParser {
            onRead: function(line) {
                var value = String(line).trim();
                if (/^[0-9]+$/.test(value))
                    root.userId = value;

            }
        }

    }

    Timer {
        id: userIdDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (userIdReader.running) {
                userIdReader.signal(15);
                userIdKillGrace.restart();
            }
        }
    }

    Timer {
        id: userIdKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(userIdReader, userIdDeadline, userIdKillGrace)
    }

    Process {
        id: configStat

        command: ["/usr/bin/stat", "--format=%F|%u|%a|%s", "--", root.configPath]
        onRunningChanged: {
            if (running) {
                configStatDeadline.restart();
            } else {
                configStatDeadline.stop();
                configStatKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0 || !root.configMetadataValid)
                root.useDefaultConfig();
            else
                configReader.running = true;
        }

        stdout: SplitParser {
            onRead: function(line) {
                root.configMetadataValid = root.configMetadataIsSafe(line);
            }
        }

    }

    Timer {
        id: configStatDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (configStat.running) {
                configStat.signal(15);
                configStatKillGrace.restart();
            }
        }
    }

    Timer {
        id: configStatKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(configStat, configStatDeadline, configStatKillGrace)
    }

    Process {
        id: configReader

        command: ["/usr/bin/dd", "if=" + root.configPath, "iflag=nofollow", "bs=1", "count=" + root.maximumConfigBytes, "status=none"]
        onRunningChanged: {
            if (running) {
                configReaderDeadline.restart();
            } else {
                configReaderDeadline.stop();
                configReaderKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0)
                root.useDefaultConfig();
            else
                root.loadConfig(configOutput.text);
        }

        stdout: StdioCollector {
            id: configOutput

            waitForEnd: true
        }

    }

    Timer {
        id: configReaderDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (configReader.running) {
                configReader.signal(15);
                configReaderKillGrace.restart();
            }
        }
    }

    Timer {
        id: configReaderKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(configReader, configReaderDeadline, configReaderKillGrace)
    }

    Process {
        id: detectDevice

        command: ["/usr/bin/find", "/sys/class/leds", "-maxdepth", "1", "-name", "asus::*kbd*backlight*", "-print", "-quit"]
        onStarted: root.log("device detection started")
        onRunningChanged: {
            if (running) {
                detectDeviceDeadline.restart();
            } else {
                detectDeviceDeadline.stop();
                detectDeviceKillGrace.stop();
            }
        }
        onExited: function(code) {
            if ((code !== 0 || !root.device) && !root.unavailableLogged) {
                root.unavailableLogged = true;
                root.log("keyboard backlight device unavailable; service disabled");
            }
        }

        stdout: SplitParser {
            onRead: function(line) {
                var path = String(line).trim();
                if (path) {
                    root.ledPath = path;
                    root.device = path.substring(path.lastIndexOf("/") + 1);
                    root.brightnessPath = path + "/brightness";
                    root.maximumBrightnessPath = path + "/max_brightness";
                    root.log("device detected: " + path + "; reading max brightness");
                }
            }
        }

    }

    Timer {
        id: detectDeviceDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (detectDevice.running) {
                detectDevice.signal(15);
                detectDeviceKillGrace.restart();
            }
        }
    }

    Timer {
        id: detectDeviceKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(detectDevice, detectDeviceDeadline, detectDeviceKillGrace)
    }

    Process {
        id: keyboardOff

        command: ["/usr/bin/brightnessctl", "--device", root.device, "set", "0"]
        onRunningChanged: {
            if (running) {
                keyboardOffDeadline.restart();
            } else {
                keyboardOffDeadline.stop();
                keyboardOffKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0) {
                root.log("failed to disable keyboard backlight");
                root.clearSavedState();
            } else {
                root.log("keyboard turned off");
                if (!root.keyboardIsIdle || root.restoreAfterOff)
                    Qt.callLater(root.restore);

            }
        }
    }

    Timer {
        id: keyboardOffDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (keyboardOff.running) {
                keyboardOff.signal(15);
                keyboardOffKillGrace.restart();
            }
        }
    }

    Timer {
        id: keyboardOffKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(keyboardOff, keyboardOffDeadline, keyboardOffKillGrace)
    }

    Process {
        id: keyboardRestore

        onRunningChanged: {
            if (running) {
                keyboardRestoreDeadline.restart();
            } else {
                keyboardRestoreDeadline.stop();
                keyboardRestoreKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0)
                root.log("failed to restore keyboard backlight");
            else
                root.log("activity resumed; restored brightness " + root.savedBrightness);
            root.clearSavedState();
        }
    }

    Timer {
        id: keyboardRestoreDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (keyboardRestore.running) {
                keyboardRestore.signal(15);
                keyboardRestoreKillGrace.restart();
            }
        }
    }

    Timer {
        id: keyboardRestoreKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(keyboardRestore, keyboardRestoreDeadline, keyboardRestoreKillGrace)
    }

}
