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

    // ---- Restart and hibernate recovery -------------------------------------
    // The level a restore will use lives in memory, which a shell restart
    // throws away — as does Omarchy's hibernate hook, which writes 0 without
    // telling anyone. Either way the keyboard is left dark with nothing to
    // restore it from. The pending level is therefore also written to a state
    // file that outlives the shell, and read back at startup while the LED is
    // off and the record is still fresh.
    readonly property int defaultRestoreGraceSeconds: 43200
    readonly property int maximumRestoreGraceSeconds: 604800
    readonly property string runtimeDirectory: Quickshell.env("XDG_RUNTIME_DIR")
    // The runtime directory is what survives a restart and a resume but not a
    // logout: a level remembered for a machine nobody is logged into is not
    // this plugin's business.
    readonly property string statePath: runtimeDirectory !== "" ? runtimeDirectory + "/omarchy-asus-kbd-backlight.json" : ""
    property int restoreGraceSeconds: defaultRestoreGraceSeconds
    property double recoveredBrightness: 0
    property double recoveredSavedAt: 0
    property bool stateReadPending: false
    property bool startupLedReadPending: false
    property bool startupRecoveryDone: false
    property bool stateErrorLogged: false
    property bool statePersistenceLogged: false

    // ---- Coexisting with the session lock -----------------------------------
    // Omarchy's lock blanks the keyboard backlight itself, and in a way that
    // makes it the owner of the LED while locked: `omarchy-brightness-keyboard
    // off` saves the LED's current level with brightnessctl and sets 0, and
    // `omarchy-system-wake` restores that saved value on unlock. The save has
    // to see the level the person chose, not the one this service dimmed to —
    // otherwise the wake restores the dimmed 0 and the keyboard stays dark
    // after every lock. So while a lock is up this service hands the LED back
    // at the level it was holding, and keeps out of the way until the unlock.
    readonly property int lockProbeIntervalHoldingMs: 1000
    readonly property int lockProbeIntervalLockedMs: 5000
    property bool sessionLocked: false
    property bool lockProbeErrorLogged: false
    property string lockProbeAnswer: ""
    property string restoreReason: "activity resumed"

    property bool restoreAfterOff: false
    property bool unavailableLogged: false
    property bool configErrorLogged: false
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
        var parsed = null;
        try {
            parsed = JSON.parse(text);
        } catch (error) {
            parsed = null;
        }
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
            useDefaultConfig();
            return;
        }

        // The two settings are read one at a time: a value this version does
        // not know, or one that is out of range, must not drag the other back
        // to its default.
        var timeout = parsed.idleTimeoutSeconds;
        if (validInteger(timeout) && timeout >= minimumIdleTimeoutSeconds && timeout <= maximumIdleTimeoutSeconds) {
            applyIdleTimeout(timeout);
            configErrorLogged = false;
            log("configuration loaded; idle timeout " + timeout + "s");
        } else {
            useDefaultConfig();
        }

        var grace = parsed.restoreGraceSeconds;
        if (grace === undefined) {
            restoreGraceSeconds = defaultRestoreGraceSeconds;
        } else if (validInteger(grace) && grace >= 0 && grace <= maximumRestoreGraceSeconds) {
            restoreGraceSeconds = grace;
            log(grace > 0
                ? "recovery after a restart enabled for " + grace + "s"
                : "recovery after a restart disabled");
        } else {
            restoreGraceSeconds = defaultRestoreGraceSeconds;
            log("invalid restore grace period; using " + defaultRestoreGraceSeconds + "s");
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
        removeStateRecord();
    }

    // ---- The state record ---------------------------------------------------
    // Written before the backlight is turned off, so a shell that dies during
    // the call is still covered, and removed as soon as the level is back or
    // is known to be beside the point.
    function stateRecordCommand(mode, level, savedAt) {
        return ["/usr/bin/python3", "-c",
            "import json, os, sys\n" +
            "path, mode = sys.argv[1], sys.argv[2]\n" +
            "if mode == 'remove':\n" +
            "    try:\n" +
            "        os.unlink(path)\n" +
            "    except FileNotFoundError:\n" +
            "        pass\n" +
            "    sys.exit(0)\n" +
            "record = json.dumps({'brightness': int(sys.argv[3]), 'savedAt': int(sys.argv[4])}).encode()\n" +
            "flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC\n" +
            "fd = os.open(path + '.tmp', flags, 0o600)\n" +
            "try:\n" +
            "    os.write(fd, record)\n" +
            "    os.fsync(fd)\n" +
            "finally:\n" +
            "    os.close(fd)\n" +
            "os.replace(path + '.tmp', path)\n",
            statePath, mode, String(level), String(savedAt)];
    }

    function logStateError(message) {
        if (stateErrorLogged)
            return;

        stateErrorLogged = true;
        log(message);
    }

    function writeStateRecord(level) {
        if (!statePath) {
            if (!statePersistenceLogged) {
                statePersistenceLogged = true;
                log("no runtime directory; a restart may leave the keyboard backlight off");
            }
            return;
        }
        if (stateWriter.running)
            return;

        stateWriter.command = stateRecordCommand("write", level, Math.round(Date.now()));
        stateWriter.running = true;
    }

    function removeStateRecord() {
        if (!statePath || stateCleaner.running)
            return;

        stateCleaner.command = stateRecordCommand("remove", 0, 0);
        stateCleaner.running = true;
    }

    // ---- Recovery at startup ------------------------------------------------
    // Two reads, in this order: the record, then the LED itself. The LED
    // decides, because a level already on the hardware belongs to whoever put
    // it there and outranks anything this plugin remembers.
    function beginStartupRecovery() {
        if (startupRecoveryDone || startupLedReadPending || maximumBrightness < 1 || !device)
            return;

        startupRecoveryDone = true;
        if (!statePath) {
            if (keyboardIsIdle)
                handleIdleStateChange();
            return;
        }

        stateReadPending = true;
        stateFile.reload();
    }

    function readStateRecord(text) {
        if (!stateReadPending)
            return;

        stateReadPending = false;

        var record = null;
        try {
            record = JSON.parse(text);
        } catch (error) {
            record = null;
        }
        if (record === null || typeof record !== "object" || Array.isArray(record)) {
            logStateError("ignoring an unreadable saved brightness");
            removeStateRecord();
            return;
        }
        if (!validInteger(record.brightness) || record.brightness < 1 || record.brightness > maximumBrightness) {
            logStateError("ignoring a saved brightness outside the LED's range");
            removeStateRecord();
            return;
        }

        recoveredBrightness = record.brightness;
        recoveredSavedAt = typeof record.savedAt === "number" && isFinite(record.savedAt) ? record.savedAt : 0;

        startupLedReadPending = true;
        brightnessFile.reload();
    }

    function handleStartupLed(text) {
        if (!startupLedReadPending)
            return;

        startupLedReadPending = false;
        decideStartupLed(text);
        // Recovery has had its say; the ordinary idle behaviour resumes.
        if (keyboardIsIdle)
            handleIdleStateChange();
    }

    function decideStartupLed(text) {
        var level = parseBrightness(text);
        // A level that cannot be read is not a level of zero.
        if (level > 0) {
            // The hardware holds a level already, so nothing was stranded and
            // the record has been overtaken by whoever set it.
            removeStateRecord();
            return;
        }
        if (level !== 0)
            return;

        var age = Date.now() - recoveredSavedAt;
        if (restoreGraceSeconds <= 0 || recoveredSavedAt <= 0 || age > restoreGraceSeconds * 1000) {
            log("discarded a saved brightness from an earlier session");
            removeStateRecord();
            return;
        }

        log("recovering brightness " + recoveredBrightness + " after a restart");
        savedBrightness = recoveredBrightness;
        // Idle now: the ordinary restore-on-activity path brings it back.
        if (!keyboardIsIdle)
            restore("recovered after a restart");
    }

    function stopProcess(process, deadline, killGrace) {
        deadline.stop();
        killGrace.stop();
        if (process.running)
            process.signal(9);

    }

    function beginConfigLoad() {
        if (!userId || configReader.running)
            return ;

        log("checking configuration");
        configReader.command = configReaderCommand();
        configReader.running = true;
    }

    // The helper retains the descriptor it validates, avoiding a pathname check/use race.
    function configReaderCommand() {
        return ["/usr/bin/python3", "-c", "import os, stat, sys\n" + "path, uid, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])\n" + "directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC\n" + "file_flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC\n" + "directory_fd = None\n" + "file_fd = None\n" + "try:\n" + "    parts = path.split('/')\n" + "    if not path.startswith('/') or not parts[-1]: raise ValueError\n" + "    directory_fd = os.open('/', directory_flags)\n" + "    for part in parts[1:-1]:\n" + "        if not part or part in ('.', '..'): raise ValueError\n" + "        next_fd = os.open(part, directory_flags, dir_fd=directory_fd)\n" + "        os.close(directory_fd)\n" + "        directory_fd = next_fd\n" + "    file_fd = os.open(parts[-1], file_flags, dir_fd=directory_fd)\n" + "    metadata = os.fstat(file_fd)\n" + "    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid or metadata.st_mode & 0o022 or metadata.st_size > limit: raise ValueError\n" + "    content = b''\n" + "    while len(content) < limit:\n" + "        chunk = os.read(file_fd, limit - len(content))\n" + "        if not chunk: break\n" + "        content += chunk\n" + "    sys.stdout.buffer.write(content)\n" + "except (OSError, ValueError):\n" + "    sys.exit(1)\n" + "finally:\n" + "    if file_fd is not None: os.close(file_fd)\n" + "    if directory_fd is not None: os.close(directory_fd)\n", configPath, userId, String(maximumConfigBytes)];
    }

    function handleIdleStateChange() {
        log("idle event received; isIdle=" + keyboardIsIdle);
        if (keyboardIsIdle) {
            // A recovery read in flight owns the LED for this moment, and so
            // does the lock: while it is up, its blanking is the dimming.
            if (!device || maximumBrightness < 1 || savedBrightness >= 0 || readPending
                || stateReadPending || startupLedReadPending || sessionLocked)
                return;

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
        // Recorded before the LED is touched: a shell that dies between the
        // two still leaves enough behind to recover from.
        writeStateRecord(level);
        keyboardOff.running = true;
    }

    function restore(reason) {
        if (savedBrightness < 0)
            return ;

        restoreReason = reason || "activity resumed";

        if (keyboardOff.running) {
            restoreAfterOff = true;
            return;
        }
        if (keyboardRestore.running)
            return;

        log(restoreReason + "; restoring brightness " + savedBrightness);
        keyboardRestore.command = ["/usr/bin/brightnessctl", "--device", device, "set", String(savedBrightness)];
        keyboardRestore.running = true;
    }

    // ---- The session lock ---------------------------------------------------
    // Asked of the shell, which is the authority on it, and only while this
    // service is holding a level or a lock is up — nothing is polled during
    // ordinary use.
    function pollSessionLock() {
        if (lockProbe.running)
            return;

        lockProbe.command = ["/usr/bin/omarchy-shell", "lock", "isLocked"];
        lockProbe.running = true;
    }

    function lockProbeFinished(exitCode, text) {
        if (exitCode !== 0) {
            if (!lockProbeErrorLogged) {
                lockProbeErrorLogged = true;
                log("could not read the session lock state");
            }
            return;
        }

        var answer = String(text).trim();
        if (answer !== "true" && answer !== "false")
            return;

        lockProbeErrorLogged = false;

        var locked = answer === "true";
        if (locked === sessionLocked)
            return;

        sessionLocked = locked;
        if (!locked) {
            log("session unlocked");
            return;
        }

        log("session locked");
        // The lock's own blanking is about to save whatever the LED reads, so
        // the level this service was holding has to be back on the hardware
        // before that happens.
        if (savedBrightness >= 0) {
            log("handing the backlight back for the lock");
            restore("session locked");
        }
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
        onLoaded: {
            if (root.startupLedReadPending)
                root.handleStartupLed(text());
            else
                root.readBrightness(text());
        }
        onLoadFailed: {
            if (root.readPending) {
                root.readPending = false;
                root.log("failed to read keyboard brightness");
            }
            if (root.startupLedReadPending)
                root.startupLedReadPending = false;
        }
    }

    // The record of a level this plugin still owes the keyboard. Its absence is
    // the ordinary case — a first start, or a clean exit after a restore — and
    // is not an error.
    FileView {
        id: stateFile

        path: root.statePath
        preload: true
        printErrors: false
        onLoaded: root.readStateRecord(text())
        onLoadFailed: {
            // The ordinary case: a first start, or a clean exit after a
            // restore. There is nothing to recover from.
            if (root.stateReadPending) {
                root.stateReadPending = false;
                if (root.keyboardIsIdle && !root.startupLedReadPending)
                    root.handleIdleStateChange();
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
                // Before anything else: a level this plugin still owes the
                // keyboard from before the shell restarted.
                root.beginStartupRecovery();

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
        id: configReader

        command: []
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
                // Deferred, and with its reason intact: an off that is still
                // running when a lock arrives hands back the level that lock
                // was told about, not a fresh "activity resumed".
                if (!root.keyboardIsIdle || root.restoreAfterOff)
                    Qt.callLater(function() { root.restore(root.restoreReason) });

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
                root.log(root.restoreReason + "; restored brightness " + root.savedBrightness);
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

    // ---- The lock probe -----------------------------------------------------
    // Polled only while a level is being held (a lock would then strand it) or
    // while a lock is up (waiting for the unlock that ends it), so ordinary use
    // costs nothing. The shell is asked, so the answer is the same one the
    // lock's own keys off, and nothing here touches the session-lock protocol
    // the lock itself owns.
    Timer {
        id: lockProbeTimer

        // Only while this service is holding a level (a lock would then strand
        // it) or while a lock is up (waiting for the unlock that ends it).
        running: root.savedBrightness >= 0 || root.sessionLocked
        repeat: true
        interval: root.sessionLocked ? root.lockProbeIntervalLockedMs : root.lockProbeIntervalHoldingMs
        onTriggered: root.pollSessionLock()
    }

    Process {
        id: lockProbe

        // Set when the poll starts, as this service's other helper processes
        // are: a command assigned at start is the shape that reliably runs.
        command: []
        onRunningChanged: {
            if (running) {
                lockProbeDeadline.restart();
            } else {
                lockProbeDeadline.stop();
                lockProbeKillGrace.stop();
            }
        }
        onExited: function(code) { root.lockProbeFinished(code, root.lockProbeAnswer) }

        // Read out of the collector here rather than in onExited: with a
        // process that has already exited, `text` is not reliably still there.
        stdout: StdioCollector {
            id: lockProbeOutput
            waitForEnd: true
            onStreamFinished: root.lockProbeAnswer = text
        }

        stderr: StdioCollector {
            id: lockProbeError
            waitForEnd: true
        }
    }

    Timer {
        id: lockProbeDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (lockProbe.running) {
                lockProbe.signal(15);
                lockProbeKillGrace.restart();
            }
        }
    }

    Timer {
        id: lockProbeKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(lockProbe, lockProbeDeadline, lockProbeKillGrace)
    }

    // The state record itself. A failure here is not something the person at
    // the keyboard can act on, so it is reported once and the service carries
    // on with the behaviour it had before the record existed.
    Process {
        id: stateWriter

        command: []
        onRunningChanged: {
            if (running) {
                stateWriterDeadline.restart();
            } else {
                stateWriterDeadline.stop();
                stateWriterKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0)
                root.logStateError("could not record a saved brightness for a restart");
        }

    }

    Timer {
        id: stateWriterDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (stateWriter.running) {
                stateWriter.signal(15);
                stateWriterKillGrace.restart();
            }
        }
    }

    Timer {
        id: stateWriterKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(stateWriter, stateWriterDeadline, stateWriterKillGrace)
    }

    Process {
        id: stateCleaner

        command: []
        onRunningChanged: {
            if (running) {
                stateCleanerDeadline.restart();
            } else {
                stateCleanerDeadline.stop();
                stateCleanerKillGrace.stop();
            }
        }
        onExited: function(code) {
            if (code !== 0)
                root.logStateError("could not clear a saved brightness record");
        }

    }

    Timer {
        id: stateCleanerDeadline

        interval: root.processDeadlineMs
        onTriggered: {
            if (stateCleaner.running) {
                stateCleaner.signal(15);
                stateCleanerKillGrace.restart();
            }
        }
    }

    Timer {
        id: stateCleanerKillGrace

        interval: root.processKillGraceMs
        onTriggered: root.stopProcess(stateCleaner, stateCleanerDeadline, stateCleanerKillGrace)
    }

}
