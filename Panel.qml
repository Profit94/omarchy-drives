import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "DriveModel.js" as DriveModel

Panel {
  id: root
  moduleName: "softwave.drives"
  ipcTarget: "softwave.drives"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  // Bound, not copied, so `omarchy font set` restyles the widget live.
  readonly property string fontFamily: Style.font.family
  readonly property string actionScript: Qt.resolvedUrl("bin/drive-action").toString().replace(/^file:\/\//, "")

  // ------------------------------------------------------------------ state

  property var drives: []
  property bool loaded: false
  // disk name -> time it was attached, while a first mount may still open it
  property var recent: ({})
  // disk name -> true while being removed, or after removal succeeded
  property var ejecting: ({})
  property bool ejectMode: false
  // Plays the busy animation without touching a drive (IPC `preview`).
  property bool previewBusy: false
  Timer { id: previewTimer; onTriggered: root.previewBusy = false }

  readonly property bool hasDrives: drives.length > 0
  readonly property bool anyBusy: Object.keys(ejecting).some(function(k) { return ejecting[k] === "busy" })
  readonly property bool wantsIcon: hasDrives || connecting || setting("alwaysShow", false) === true

  property int insertTick: 0
  property int ejectTick: 0

  property bool iconShown: false
  onWantsIconChanged: {
    if (wantsIcon) {
      hideDelay.stop()
      iconShown = true
      // Undo an eject fade that may have played before it hid.
      if (loaded && !hasDrives) insertTick++
    } else {
      ejectTick++
      hideDelay.restart()
    }
  }
  Timer {
    id: hideDelay
    interval: 450
    onTriggered: {
      // Let the last drive's launch finish before the panel goes.
      if (root.opened && Object.keys(root.departed).length > 0) { restart(); return }
      root.iconShown = false
      root.close()
    }
  }

  visible: iconShown
  implicitWidth: iconShown ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  function withKey(map, key, value) {
    var next = Object.assign({}, map)
    if (value === undefined) delete next[key]
    else next[key] = value
    return next
  }

  // ---------------------------------------------------------------- watching

  Process {
    id: lsblk
    property bool again: false
    command: ["lsblk", "-J", "-b", "-o", DriveModel.LSBLK_COLUMNS]
    stdout: StdioCollector { id: lsblkOut }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applySnapshot(String(lsblkOut.text || ""))
      if (again) {
        again = false
        running = true
      }
    }
  }

  function refresh() {
    if (lsblk.running) lsblk.again = true
    else lsblk.running = true
  }

  // Short: udisks sends a burst of signals per change, and this only has to
  // outlast the burst.
  Timer { id: debounce; interval: 120; onTriggered: root.refresh() }

  // udisks announces every attach, removal, mount and unmount.
  Process {
    id: monitor
    command: ["udisksctl", "monitor"]
    running: true
    stdout: SplitParser { onRead: function() { debounce.restart() } }
    onExited: restartMonitor.start()
  }
  Timer { id: restartMonitor; interval: 5000; onTriggered: monitor.running = true }

  // A slow safety net in case the monitor is missing or stalls.
  Timer { interval: 15000; repeat: true; running: true; onTriggered: root.refresh() }

  Component.onCompleted: {
    refresh()
    scaleProbe.running = true
    systemProbe.running = true
  }

  // ------------------------------------------------------------ system disk

  // The computer's own disk, shown above the drives in the left-click panel.
  property var system: null
  Process {
    id: systemProbe
    command: ["sh", "-c", 'df -B1 --output=size,used,avail,fstype / | tail -n1; src=$(findmnt -no SOURCE / | sed "s/\\[.*//"); lsblk -nsro TYPE,ROTA,TRAN,MODEL -- "$src" 2>/dev/null | grep "^disk " | head -n1']
    stdout: StdioCollector {
      onStreamFinished: root.system = DriveModel.parseSystem(String(text || ""))
    }
  }
  function refreshSystem() { if (!systemProbe.running) systemProbe.running = true }

  function applySnapshot(text) {
    var next = DriveModel.parseDrives(text)
    if (loaded) {
      var now = Date.now()
      var change = DriveModel.diff(drives, next)

      change.added.forEach(function(d) {
        recent = withKey(recent, d.name, now)
        notify(strings.t("attached").arg(d.title), describe(d), notifyIcon("attached", d))
        root.openAttached(d)
      })
      if (change.added.length > 0) {
        insertTick++
        connecting = false
      }

      change.removed.forEach(function(d) {
        var wasEjected = ejecting[d.name] === "done"
        ejecting = withKey(ejecting, d.name, undefined)
        recent = withKey(recent, d.name, undefined)
        if (wasEjected) return
        if (DriveModel.mountedParts(d).length > 0)
          notify(strings.t("unsafe").arg(d.title), "", notifyIcon("warning", d), "critical")
        else
          notify(strings.t("removed").arg(d.title), "", notifyIcon("removed", d))
      })

      // Fallback when the immediate open could not mount (say, an encrypted
      // drive udiskie unlocks): open it once a mount shows up.
      change.newMounts.forEach(function(m) {
        var since = recent[m.drive.name]
        if (typeof since !== "number" || now - since > 30000) return
        // One window per attached drive.
        recent = withKey(recent, m.drive.name, undefined)
        if (setting("autoOpen", true) === true)
          Quickshell.execDetached(["gio", "open", m.part.mountpoint])
      })
    }
    drives = next
    syncEjectModel()
    if (!loaded) {
      loaded = true
      if (wantsIcon) { iconShown = true; insertTick++ }
    }
  }

  // ------------------------------------------------------------ pixel grid

  // The monitor's real scale (e.g. 1.25), for SnapButton. Read from Hyprland
  // when the panel opens, since Qt only knows the rounded-up render ratio.
  property real outputScale: 0
  readonly property string screenName: bar && bar.screen ? String(bar.screen.name || "") : ""
  Process {
    id: scaleProbe
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var mons = JSON.parse(String(text || "[]"))
          var pick = mons.filter(function(m) { return m.name === root.screenName })[0]
            || mons.filter(function(m) { return m.focused })[0] || mons[0]
          var s = pick ? Number(pick.scale) : 0
          if (isFinite(s) && s > 0 && s <= 4) root.outputScale = s
        } catch (e) {}
      }
    }
  }

  // ------------------------------------------------------------- level colours

  // Green, yellow and red come from the current theme's palette, so the ring
  // follows `omarchy theme set`. Re-read whenever the panel opens.
  property color levelOk: "#81b29a"
  property color levelWarn: "#dbc074"
  property color levelFull: Commons.Color.urgent

  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var pal = DriveModel.parsePalette(text())
      root.levelOk = pal.green || "#81b29a"
      root.levelWarn = pal.yellow || "#dbc074"
      root.levelFull = pal.red || Commons.Color.urgent
    }
  }
  onOpenedChanged: {
    if (opened) { themeColors.reload(); scaleProbe.running = true; refreshSystem() }
    else if (Object.keys(departed).length > 0) { departed = ({}); syncEjectModel() }
  }

  function levelColor(fraction) {
    var level = DriveModel.usageLevel(fraction)
    return level === "full" ? levelFull : level === "warn" ? levelWarn : levelOk
  }

  // Mount and open a new drive at once rather than waiting for udiskie's
  // mount to come round. If udiskie gets there first, the script just uses
  // its mount. If this fails, the newMounts fallback above opens it later.
  function openAttached(d) {
    if (setting("autoOpen", true) !== true) return
    var part = DriveModel.primaryPart(d)
    if (!part) return
    recent = withKey(recent, d.name, "opening")
    run("open", part.path, function(ok) {
      recent = withKey(recent, d.name, ok ? undefined : Date.now())
      root.refresh()
    })
  }

  // ------------------------------------------------------------ connecting

  // A USB storage device announces itself the moment it is plugged in; a
  // hard drive then needs several seconds to spin up before its disk shows.
  // The icon appears straight away with its light blinking until it does.
  property bool connecting: false
  Timer { id: connectTimeout; interval: 20000; onTriggered: root.connecting = false }

  Process {
    id: usbMonitor
    property var event: ({})
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=usb/usb_interface", "--property"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        line = String(line)
        if (line === "") {
          var e = usbMonitor.event
          usbMonitor.event = ({})
          // Interface class 8 is mass storage (8/6/80 bulk-only, 8/6/98 UAS).
          if (e.ACTION === "add" && /^8\//.test(e.INTERFACE || "")) {
            root.connecting = true
            connectTimeout.restart()
          } else if (e.ACTION === "remove" && /^8\//.test(e.INTERFACE || "")) {
            root.connecting = false
          }
          return
        }
        var eq = line.indexOf("=")
        if (eq > 0 && eq < 32) usbMonitor.event[line.slice(0, eq)] = line.slice(eq + 1, eq + 65)
      }
    }
    onExited: restartUsbMonitor.start()
  }
  Timer { id: restartUsbMonitor; interval: 5000; onTriggered: usbMonitor.running = true }

  // ------------------------------------------------------------------ helpers

  function kindName(d) { return strings.t("kind." + (d ? d.kind : "disk")) }

  function describe(d) {
    var bits = [kindName(d)]
    if (d.model && d.model !== d.title) bits.push(d.model)
    bits.push(root.size(d.size))
    return bits.join(" · ")
  }

  function iconFor(d) {
    if (!d) return "drive-removable-media"
    if (d.kind === "usb") return "drive-removable-media-usb"
    if (d.kind === "sd") return "media-flash"
    return "drive-harddisk"
  }

  function escapeMarkup(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // ------------------------------------------------- notification icons

  // The slab, drawn per screen-pixel grid for the toast's icon slot (40
  // units), written per scale and theme colour into the runtime dir.
  readonly property string iconDir: Quickshell.env("XDG_RUNTIME_DIR") + "/softwave-drives/icons"
  readonly property int notifyIconPx: Math.round(Style.space(40) * (outputScale > 0 ? outputScale : 1))
  property string writtenIconKey: ""
  readonly property string iconInk: {
    var c = Commons.Color.notifications.text
    var hex = function(v) { var h = Math.round(v * 255).toString(16); return h.length < 2 ? "0" + h : h }
    return "#" + hex(c.r) + hex(c.g) + hex(c.b)
  }
  readonly property string iconKey: notifyIconPx + "-" + iconInk.slice(1)
  property var iconWriters: []

  function iconPath(kind, fillSteps) {
    return iconDir + "/" + kind + "-" + iconKey + (kind === "attached" ? "-" + fillSteps : "") + ".svg"
  }

  function notifyIcon(kind, d) {
    if (writtenIconKey !== iconKey) return iconFor(d)   // not written yet: theme icon
    var steps = 0
    if (kind === "attached" && d) {
      var p = DriveModel.primaryPart(d)
      if (p && p.mountpoint) steps = Math.round(DriveModel.usageFraction(p) * DriveModel.notifyFillSteps(notifyIconPx))
    }
    return iconPath(kind, steps)
  }

  Component {
    id: iconWriter
    FileView {
      atomicWrites: true
      printErrors: false
      blockLoading: false
    }
  }

  function writeIcons() {
    var n = notifyIconPx
    if (n <= 0 || iconKey === writtenIconKey) return
    var files = []
    for (var f = 0; f <= DriveModel.notifyFillSteps(n); f++)
      files.push([iconPath("attached", f), DriveModel.notifyIconSvg("attached", n, f, iconInk)])
    ;["ejected", "removed", "warning"].forEach(function(k) {
      files.push([iconPath(k, 0), DriveModel.notifyIconSvg(k, n, 0, iconInk)])
    })
    // Writers are kept until the next set replaces them, so no write is cut short.
    iconWriters.forEach(function(w) { w.destroy() })
    iconWriters = files.map(function(entry) {
      var w = iconWriter.createObject(root, { path: entry[0] })
      w.setText(entry[1])
      return w
    })
    writtenIconKey = iconKey
  }

  Process {
    id: iconDirMaker
    // Fresh set per scale and theme colour: make the folder, drop the old set.
    command: ["sh", "-c", 'mkdir -p -m 700 "$1" && rm -f -- "$1"/*.svg', "_", root.iconDir]
    onExited: function(code) { if (code === 0) root.writeIcons() }
  }
  onIconKeyChanged: if (outputScale > 0) iconDirMaker.running = true

  function notify(summary, body, icon, urgency) {
    if (setting("notify", true) !== true) return
    var args = ["notify-send", "-a", "Drives", "-i", icon || "drive-removable-media",
      "-u", urgency || "normal", escapeMarkup(summary)]
    if (body) args.push(escapeMarkup(body))
    Quickshell.execDetached(args)
  }

  // ------------------------------------------------------------------ actions

  Component {
    id: runner
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector { id: out }
      stderr: StdioCollector { id: err }
      onExited: function(exitCode) {
        if (done) done(exitCode === 0, String(out.text || "").trim(), String(err.text || "").trim())
        proc.destroy()
      }
    }
  }

  function run(action, device, done) {
    if (!DriveModel.validDevice(device)) return
    var p = runner.createObject(root, { command: [actionScript, action, device], done: done || null })
    p.running = true
  }

  // A size in the language's number format ("30,8 GB" in Danish).
  function size(bytes) { return DriveModel.formatBytes(bytes, Commons.I18n.formatNumber) }

  // A whole sentence per action ("failed.eject"), never glued from parts,
  // and the script's error code turned into a translated reason.
  function failed(action, d, reason) {
    var e = DriveModel.errorKey(reason)
    var why = e ? strings.t(e.key).arg(e.arg) : String(reason || "")
    notify(strings.t("failed." + action).arg(d.title), why, notifyIcon("warning", d), "critical")
  }

  function openDrive(d, inTerminal) {
    var part = DriveModel.primaryPart(d)
    if (!part) return
    recent = withKey(recent, d.name, undefined)
    run(inTerminal ? "terminal" : "open", part.path, function(ok, _, reason) {
      if (!ok) failed("open", d, reason)
      root.refresh()
    })
    close()
  }

  function copyPath(d) {
    var part = DriveModel.mountedParts(d)[0]
    if (part) Quickshell.execDetached(["wl-copy", "--", part.mountpoint])
    close()
  }

  function toggleMount(d, part) {
    recent = withKey(recent, d.name, undefined)
    var verb = part.mountpoint ? "unmount" : "mount"
    run(verb, part.path, function(ok, _, reason) {
      if (!ok) failed(verb, d, reason)
      root.refresh()
    })
  }

  function eject(d, then) {
    if (ejecting[d.name] === "busy") { if (then) Qt.callLater(then); return }
    ejecting = withKey(ejecting, d.name, "busy")
    console.log("softwave.drives: eject", d.path)
    run("eject", d.path, function(ok, _, reason) {
      console.log("softwave.drives: eject", d.path, ok ? "ok" : "failed: " + reason)
      if (then) Qt.callLater(then)
      if (ok) {
        if (root.opened && root.ejectMode) {
          departed = withKey(departed, d.name, d)
          departSafety.restart()
        }
        ejecting = withKey(ejecting, d.name, "done")
        notify(strings.t("ejected").arg(d.title), "", notifyIcon("ejected", d))
      } else {
        ejecting = withKey(ejecting, d.name, undefined)
        failed("eject", d, reason)
      }
      root.refresh()
    })
    if (!ejectMode) close()
  }

  // ------------------------------------------------------- eject list model

  // The eject popup keeps its rows in a ListModel synced by name, so a
  // refresh doesn't rebuild them and cut a launch short. A drive that was
  // just ejected stays in `departed` until its row has flown out.
  property var departed: ({})
  readonly property var driveMap: DriveModel.byName(drives)
  ListModel { id: ejectModel }

  function syncEjectModel() {
    var keep = {}
    drives.forEach(function(d) { keep[d.name] = true })
    for (var i = ejectModel.count - 1; i >= 0; i--) {
      var n = ejectModel.get(i).name
      if (!keep[n] && !departed[n]) ejectModel.remove(i)
    }
    drives.forEach(function(d) {
      for (var j = 0; j < ejectModel.count; j++) if (ejectModel.get(j).name === d.name) return
      ejectModel.append({ name: d.name })
    })
  }

  function landed(name) {
    departed = withKey(departed, name, undefined)
    syncEjectModel()
  }

  // Fallback if a row never got to play (panel closed mid-launch).
  Timer {
    id: departSafety
    interval: 2500
    onTriggered: { root.departed = ({}); root.syncEjectModel() }
  }

  // One drive after another: running them together let two ejects race over
  // the same file manager windows and udisks, and one would come back busy.
  property var ejectQueue: []
  function ejectAll() {
    ejectQueue = drives.slice()
    ejectNext()
  }
  function ejectNext() {
    if (ejectQueue.length === 0) return
    var d = ejectQueue[0]
    ejectQueue = ejectQueue.slice(1)
    eject(d, ejectNext)
  }

  // A dry-run eject for `preview launch`: rumble, then fly out, then return.
  property string previewName: ""
  function previewLaunch(seconds) {
    if (!latest) return
    previewName = latest.name
    ejectMode = true
    open()
    ejecting = withKey(ejecting, previewName, "busy")
    previewLaunchTimer.interval = seconds * 1000
    previewLaunchTimer.restart()
  }
  Timer {
    id: previewLaunchTimer
    onTriggered: {
      var d = root.driveMap[root.previewName]
      root.ejecting = root.withKey(root.ejecting, root.previewName, undefined)
      if (d) root.departed = root.withKey(root.departed, d.name, d)
      previewReturn.restart()
    }
  }
  Timer { id: previewReturn; interval: 2200; onTriggered: root.landed(root.previewName) }

  // Middle-click and IPC: act on the most recently attached drive.
  readonly property var latest: hasDrives ? drives[drives.length - 1] : null

  // Usage the bar capsule shows: the most recently attached drive.
  readonly property real latestFill: {
    if (!latest) return 0
    var p = DriveModel.primaryPart(latest)
    return p && p.mountpoint ? DriveModel.usageFraction(p) : 0
  }

  // ---------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: root.iconShown
    // A touch larger than its neighbours, so the capsule's bar reads clearly.
    opticalSize: Math.round(Style.bar.iconCanvas * 1.25)
    iconComponent: Component {
      Item {
        width: button.opticalSize
        height: button.opticalSize

        DriveIcon {
          anchors.fill: parent
          iconSize: parent.width
          color: root.hasDrives ? root.barForeground : Qt.darker(root.barForeground, 1.55)
          fill: root.latestFill
          lit: !!root.latest && DriveModel.mountedParts(root.latest).length > 0
          busy: root.anyBusy || root.previewBusy || root.connecting
          outputScale: root.outputScale
          insertTick: root.insertTick
          ejectTick: root.ejectTick

          Behavior on color { ColorAnimation { duration: Style.duration(160) } }
        }
      }
    }
    onPressed: function(pressedButton) {
      if (pressedButton === Qt.MiddleButton) {
        if (root.latest) root.openDrive(root.latest, false)
        return
      }
      // Left: drive cards. Right: the eject list.
      var wantEject = pressedButton === Qt.RightButton
      if (root.opened && root.ejectMode === wantEject) {
        root.close()
      } else {
        root.ejectMode = wantEject
        root.open()
      }
    }
  }

  // --------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(root.ejectMode ? 300 : 360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: root.ejectMode ? ejectColumn.implicitHeight : listColumn.implicitHeight
      onCloseRequested: root.close()

      // ------------------------------------------------ left-click: details
      Column {
        id: listColumn
        visible: !root.ejectMode
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: listHeader.implicitHeight

          PanelSectionHeader {
            id: listHeader
            text: strings.t("title")
            foreground: root.foreground
            fontFamily: root.fontFamily
            transform: Translate { id: listHeaderShift }

            PixelSnap { target: listHeader; shift: listHeaderShift; outputScale: root.outputScale }
          }
          SnapText {
            outputScale: root.outputScale
            anchors.right: parent.right
            anchors.bottom: listHeader.bottom
            visible: root.hasDrives
            textFormat: Text.PlainText
            text: strings.tn("count", root.drives.length).arg(Commons.I18n.formatNumber(root.drives.length))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The computer's own disk, in a quieter card: no hover, no actions.
        Item {
          id: systemCard
          visible: !!root.system
          width: listColumn.width
          height: Style.space(36) + Style.space(20)
          readonly property real fraction: root.system && root.system.total > 0 ? Math.min(1, root.system.used / root.system.total) : 0

          BorderSurface {
            id: systemSurface
            width: systemSnap.px(parent.width)
            height: systemSnap.px(parent.height)
            transform: Translate { id: systemShift }
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)

            PixelSnap { id: systemSnap; target: systemSurface; shift: systemShift; outputScale: root.outputScale }
          }

          RadarRing {
            id: systemRadar
            x: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: systemRadarSnap.px(Style.space(36))
            height: width
            outputScale: root.outputScale
            transform: Translate { id: systemRadarShift }
            PixelSnap { id: systemRadarSnap; target: systemRadar; shift: systemRadarShift; outputScale: root.outputScale }
            value: systemCard.fraction
            showText: false
            color: root.levelColor(value)
            trackColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
            fontFamily: root.fontFamily
          }

          Column {
            anchors.left: systemRadar.right
            anchors.leftMargin: Style.space(12)
            anchors.right: systemFree.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            SnapText {
              outputScale: root.outputScale
              width: parent.width
              text: strings.t("system")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
            SnapText {
              outputScale: root.outputScale
              width: parent.width
              text: root.system ? [root.kindName(root.system), root.system.fstype, root.size(root.system.total)].filter(function(s) { return s }).join(" · ") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Column {
            id: systemFree
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter

            SnapText {
              outputScale: root.outputScale
              anchors.right: parent.right
              width: Math.min(implicitWidth, Style.space(110))
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              text: root.system ? root.size(root.system.free) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            SnapText {
              outputScale: root.outputScale
              anchors.right: parent.right
              width: Math.min(implicitWidth, Style.space(110))
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              text: strings.t("free")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        SnapText {
          outputScale: root.outputScale
          visible: !root.hasDrives
          textFormat: Text.PlainText
          text: root.connecting ? strings.t("connecting") : strings.t("empty")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.drives

          // A card per drive. Resting, it shows free space; hovered, the
          // border lights in the accent and the actions slide in its place.
          Item {
            id: card
            required property var modelData
            readonly property var drive: modelData
            readonly property var primary: DriveModel.primaryPart(drive)
            readonly property bool mounted: !!primary && primary.mountpoint !== ""
            readonly property bool busy: root.ejecting[drive.name] === "busy"
            readonly property bool hot: cardHover.hovered

            width: listColumn.width
            height: cardBody.implicitHeight + Style.space(24)

            HoverHandler { id: cardHover }

            // Only the surface is snapped, not the card, so the snapped
            // controls inside keep their own independent positions.
            BorderSurface {
              id: cardSurface
              width: cardSnap.px(parent.width)
              height: cardSnap.px(parent.height)
              transform: Translate { id: cardShift }
              radius: Style.cornerRadius
              color: card.hot ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : Style.normalFillFor(root.foreground, Commons.Color.accent)
              borderSpec: card.hot ? Border.controlSpec("hover-cursor", root.foreground, Commons.Color.accent)
                                   : Border.controlSpec("normal", root.foreground, Commons.Color.accent)
              Behavior on color { ColorAnimation { duration: Style.duration(140) } }

              PixelSnap { id: cardSnap; target: cardSurface; shift: cardShift; outputScale: root.outputScale }
            }

            Column {
              id: cardBody
              x: Style.space(12)
              y: Style.space(12)
              width: parent.width - Style.space(24)
              spacing: Style.space(10)

              Item {
                width: parent.width
                height: Style.space(48)

                RadarRing {
                  id: ring
                  width: ringSnap.px(parent.height)
                  height: width
                  outputScale: root.outputScale
                  transform: Translate { id: ringShift }

                  PixelSnap { id: ringSnap; target: ring; shift: ringShift; outputScale: root.outputScale }
                  value: card.mounted ? DriveModel.usageFraction(card.primary) : 0
                  mounted: card.mounted
                  busy: card.busy
                  color: card.mounted ? root.levelColor(value) : root.foreground
                  textColor: root.foreground
                  Behavior on color { ColorAnimation { duration: Style.duration(240) } }
                  trackColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
                  fontFamily: root.fontFamily
                }

                Column {
                  anchors.left: ring.right
                  anchors.leftMargin: Style.space(12)
                  anchors.right: trailing.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  SnapText {

                    outputScale: root.outputScale
                    width: parent.width
                    textFormat: Text.PlainText
                    text: card.drive.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  SnapText {
                    outputScale: root.outputScale
                    width: parent.width
                    textFormat: Text.PlainText
                    text: card.busy ? strings.t("ejecting") : root.describe(card.drive)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // Free space at rest, actions on hover.
                Item {
                  id: trailing
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(freeInfo.implicitWidth, actionRow.implicitWidth)
                  height: parent.height

                  Column {
                    id: freeInfo
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: card.hot ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

                    SnapText {

                      outputScale: root.outputScale
                      anchors.right: parent.right
                      // Capped so a long translation can't squeeze the drive name.
                      width: Math.min(implicitWidth, Style.space(110))
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: card.mounted ? root.size(card.primary.total - card.primary.used) : root.size(card.drive.size)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    SnapText {
                      outputScale: root.outputScale
                      anchors.right: parent.right
                      // Capped so a long translation can't squeeze the drive name.
                      width: Math.min(implicitWidth, Style.space(110))
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: card.mounted ? strings.t("free") : strings.t("notMounted")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: actionRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    opacity: card.hot ? 1 : 0
                    visible: opacity > 0
                    transform: Translate { x: card.hot ? 0 : Style.space(8); Behavior on x { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } } }
                    Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

                    SnapActionButton {
                      outputScale: root.outputScale
                      iconText: String.fromCodePoint(0xF0770)
                      tooltipText: strings.t("open")
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      enabled: !card.busy && !!card.primary
                      onClicked: root.openDrive(card.drive, false)
                    }
                    SnapActionButton {
                      outputScale: root.outputScale
                      iconText: String.fromCodePoint(0xF018D)
                      tooltipText: strings.t("openTerminal")
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      enabled: !card.busy && !!card.primary
                      onClicked: root.openDrive(card.drive, true)
                    }
                    SnapActionButton {
                      outputScale: root.outputScale
                      iconText: String.fromCodePoint(0xF018F)
                      tooltipText: strings.t("copyPath")
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      enabled: !card.busy && card.mounted
                      onClicked: root.copyPath(card.drive)
                    }
                    SnapActionButton {
                      outputScale: root.outputScale
                      iconText: String.fromCodePoint(0xF01EA)
                      tooltipText: strings.t("eject")
                      foreground: root.foreground
                      hoverColor: Commons.Color.accent
                      fontFamily: root.fontFamily
                      enabled: !card.busy
                      onClicked: root.eject(card.drive)
                    }
                  }
                }
              }

              // The disk as one strip, a segment per filesystem sized to it.
              // Segments are placed by hand so every edge is on a whole pixel.
              Item {
                id: strip
                width: stripSnap.px(parent.width)
                height: stripSnap.px(Style.space(4))
                transform: Translate { id: stripShift }
                readonly property var segments: DriveModel.stripLayout(
                  card.drive.parts.map(function(p) { return p.size }),
                  width, stripSnap.px(Style.space(2)), stripSnap.px(Style.space(6)), stripSnap.grid)

                PixelSnap { id: stripSnap; target: strip; shift: stripShift; outputScale: root.outputScale }

                Repeater {
                  model: card.drive.parts
                  Rectangle {
                    required property var modelData
                    required property int index
                    readonly property var seg: strip.segments[index] || ({ x: 0, w: 0 })
                    // Placed by hand, so mirrored by hand for right-to-left languages.
                    x: Commons.I18n.rightToLeft ? strip.width - seg.x - seg.w : seg.x
                    width: seg.w
                    height: parent.height
                    radius: height / 2
                    color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
                    opacity: modelData.mountpoint ? 1 : 0.5
                    clip: true

                    Rectangle {
                      height: parent.height
                      radius: parent.radius
                      width: stripSnap.px(parent.width * DriveModel.usageFraction(modelData))
                      x: Commons.I18n.rightToLeft ? parent.width - width : 0
                      color: root.levelColor(DriveModel.usageFraction(modelData))
                      Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
                    }
                  }
                }
              }

              // Filesystem chips: a filled dot when mounted. Click to toggle.
              // Spacing is a whole number of pixels too, so gaps between
              // chips are all the same instead of alternating 7 and 8.
              Flow {
                id: chipFlow
                width: parent.width
                spacing: stripSnap.px(Style.space(6))
                visible: card.drive.parts.length > 0

                Repeater {
                  model: card.drive.parts

                  Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool on: modelData.mountpoint !== ""
                    width: chipSnap.px(chipRow.implicitWidth + Style.space(16))
                    height: chipSnap.px(chipRow.implicitHeight + Style.space(8))
                    transform: Translate { id: chipShift }

                    PixelSnap { id: chipSnap; target: chip; shift: chipShift; outputScale: root.outputScale }
                    radius: height / 2
                    color: chipMouse.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"
                    border.width: 1
                    border.color: chipMouse.containsMouse ? Commons.Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                    opacity: card.busy ? 0.4 : 1
                    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
                    Behavior on border.color { ColorAnimation { duration: Style.duration(120) } }

                    Row {
                      id: chipRow
                      anchors.centerIn: parent
                      spacing: Style.space(6)

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(6); height: width; radius: width / 2
                        color: chip.on ? Commons.Color.accent : "transparent"
                        border.width: chip.on ? 0 : 1
                        border.color: root.dim
                      }
                      SnapText {
                        outputScale: root.outputScale
                        textFormat: Text.PlainText
                        text: chip.modelData.label || chip.modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      SnapText {
                        outputScale: root.outputScale
                        textFormat: Text.PlainText
                        text: chipMouse.containsMouse ? (chip.on ? strings.t("unmount") : strings.t("mount")) : chip.modelData.fstype
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: chipMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: !card.busy
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleMount(card.drive, chip.modelData)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------ right-click: eject
      // A plain pop-up: one pad per drive with its own Eject key, and Eject
      // all at the foot when two or more are attached. Rows don't react to
      // hover; only the keys do. An ejected drive rumbles while it unmounts,
      // then drops out of its pad like a rocket and the pad folds away.
      Column {
        id: ejectColumn
        visible: root.ejectMode
        width: parent.width
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: ejectHeader.implicitHeight

          PanelSectionHeader {
            id: ejectHeader
            text: strings.t("eject")
            foreground: root.foreground
            fontFamily: root.fontFamily
            transform: Translate { id: ejectHeaderShift }

            PixelSnap { target: ejectHeader; shift: ejectHeaderShift; outputScale: root.outputScale }
          }
          SnapText {
            outputScale: root.outputScale
            anchors.right: parent.right
            anchors.top: ejectHeader.top
            anchors.topMargin: ejectHeader.topPadding
            visible: root.drives.length > 1
            text: strings.tn("count", root.drives.length).arg(Commons.I18n.formatNumber(root.drives.length))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        SnapText {
          outputScale: root.outputScale
          visible: ejectModel.count === 0
          text: root.connecting ? strings.t("connecting") : strings.t("empty")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: ejectModel

          Item {
            id: pad
            required property string name
            readonly property var drive: root.driveMap[name] || root.departed[name] || null
            readonly property var primary: drive ? DriveModel.primaryPart(drive) : null
            readonly property bool mounted: !!primary && primary.mountpoint !== ""
            readonly property bool busy: root.ejecting[name] === "busy"
            readonly property bool gone: !!root.departed[name] || root.ejecting[name] === "done"
            readonly property real fullHeight: Style.space(50)
            // A little taller than the pad, so the clip never shaves its border.
            readonly property real slotHeight: fullHeight + Style.space(2)
            readonly property real grid: root.outputScale > 0 ? root.outputScale : 1
            readonly property real p: 1 / grid
            readonly property color tint: mounted ? root.levelColor(DriveModel.usageFraction(primary)) : root.foreground

            width: ejectColumn.width
            height: slotHeight
            visible: height > 0.5
            clip: true

            // Launch position: + is down. `shake` is the ignition rumble.
            property real drop: 0
            property real shake: 0
            property real trail: 0
            property real fade: 1

            onGoneChanged: {
              if (gone) { rumble.stop(); launch.restart(); return }
              // Back on the pad (a preview, or a drive that stayed attached).
              launch.stop()
              drop = 0; trail = 0; fade = 1; height = slotHeight
            }
            Component.onCompleted: if (gone) { height = 0; Qt.callLater(root.landed, name) }

            BorderSurface {
              id: padSurface
              width: padSnap.px(parent.width)
              height: padSnap.px(pad.fullHeight)
              transform: Translate { id: padShift }
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)

              PixelSnap { id: padSnap; target: padSurface; shift: padShift; outputScale: root.outputScale }
            }

            // The rocket: the drive icon, its exhaust above it (it flies down).
            Item {
              id: rocket
              x: Style.space(12)
              y: (pad.fullHeight - height) / 2
              width: Style.space(24)
              height: width
              transform: Translate { x: pad.shake; y: pad.drop }

              // Trail left behind while it falls.
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.top
                anchors.bottomMargin: -Style.space(4)
                width: 2 * pad.p
                height: pad.trail
                visible: height > 0.5
                gradient: Gradient {
                  GradientStop { position: 0.0; color: "transparent" }
                  GradientStop { position: 1.0; color: pad.tint }
                }
              }

              // Exhaust: three pixel puffs that flicker while it rumbles.
              Repeater {
                model: 3
                Rectangle {
                  required property int index
                  width: 2 * pad.p; height: width
                  x: Math.round((rocket.width / 2 + (index - 1) * 3 * pad.p) * pad.grid) / pad.grid - pad.p
                  y: -Style.space(1) - (index === 1 ? 3 * pad.p : 0)
                  color: pad.tint
                  opacity: 0
                  visible: pad.busy || launch.running
                  Timer {
                    interval: 70 + parent.index * 23
                    repeat: true
                    running: (pad.busy || launch.running) && !Style.reduceMotion
                    onTriggered: parent.opacity = Math.random() * 0.9
                    onRunningChanged: if (!running) parent.opacity = 0
                  }
                }
              }

              DriveIcon {
                anchors.centerIn: parent
                iconSize: Style.space(22)
                color: pad.tint
                fill: pad.mounted ? DriveModel.usageFraction(pad.primary) : 0
                outputScale: root.outputScale
                lit: pad.mounted
                busy: pad.busy
              }
            }

            Column {
              anchors.left: rocket.right
              anchors.leftMargin: Style.space(12)
              anchors.right: padKey.left
              anchors.rightMargin: Style.space(8)
              y: (pad.fullHeight - height) / 2
              spacing: Style.space(1)
              opacity: pad.fade

              SnapText {
                outputScale: root.outputScale
                width: parent.width
                text: pad.drive ? pad.drive.title : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              SnapText {
                outputScale: root.outputScale
                width: parent.width
                text: !pad.drive ? "" : pad.busy || pad.gone ? strings.t("ejecting")
                  : root.kindName(pad.drive) + " · " + root.size(pad.drive.size)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            SnapActionButton {
              id: padKey
              outputScale: root.outputScale
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              y: Math.round((pad.fullHeight - height) / 2)
              size: Style.space(28) | 1
              bordered: true
              iconText: String.fromCodePoint(0xF01EA)
              tooltipText: strings.t("ejectShort")
              foreground: root.foreground
              hoverColor: Commons.Color.accent
              fontFamily: root.fontFamily
              enabled: !pad.busy && !pad.gone && !!pad.drive
              opacity: pad.fade * (enabled ? 1 : 0.4)
              onClicked: root.eject(pad.drive)
            }

            // Ignition: a one-pixel rumble while the drive unmounts.
            Timer {
              id: rumble
              property int step: 0
              interval: 45
              repeat: true
              running: pad.busy && !pad.gone && !Style.reduceMotion
              onTriggered: { step = (step + 1) % 4; pad.shake = [0, pad.p, 0, -pad.p][step] }
              onRunningChanged: if (!running) pad.shake = 0
            }

            // Lift-off, downwards: a small hop, then it accelerates out of the
            // pad with a trail, the text fades, and the pad folds shut.
            SequentialAnimation {
              id: launch
              NumberAnimation { target: pad; property: "drop"; to: -3 * pad.p; duration: Style.duration(110); easing.type: Easing.OutQuad }
              ParallelAnimation {
                NumberAnimation { target: pad; property: "drop"; to: pad.fullHeight; duration: Style.duration(420); easing.type: Easing.InCubic }
                NumberAnimation { target: pad; property: "trail"; from: 0; to: pad.fullHeight * 0.6; duration: Style.duration(420); easing.type: Easing.InQuad }
                NumberAnimation { target: pad; property: "fade"; to: 0; duration: Style.duration(320); easing.type: Easing.OutCubic }
              }
              NumberAnimation { target: pad; property: "trail"; to: 0; duration: Style.duration(120) }
              NumberAnimation { target: pad; property: "height"; to: 0; duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
              ScriptAction { script: root.landed(pad.name) }
            }
          }
        }

        // Eject all: one wide accent key under the pads.
        SnapButton {
          id: ejectAll
          visible: root.drives.length > 1
          outputScale: root.outputScale
          width: px(parent.width)
          iconText: String.fromCodePoint(0xF01EA)
          text: strings.t("ejectAll")
          foreground: Commons.Color.accent
          background: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12)
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          iconSize: Style.font.body
          bordered: true
          enabled: !root.anyBusy
          opacity: enabled ? 1 : 0.4
          onClicked: root.ejectAll()
        }
      }
    }
  }

  IpcHandler {
    target: "softwave.drives.actions"
    function openLatest(): void { if (root.latest) root.openDrive(root.latest, false) }
    function ejectLatest(): void { if (root.latest) root.eject(root.latest) }
    // Sends a sample notification with the plugin's icon (attached, ejected, removed, warning).
    function notifyTest(kind: string): void {
      var d = root.latest
      var title = d ? d.title : "Drive"
      var summary = kind === "attached" ? strings.t("attached").arg(title)
        : kind === "ejected" ? strings.t("ejected").arg(title)
        : kind === "removed" ? strings.t("removed").arg(title) : strings.t("unsafe").arg(title)
      root.notify(summary, d ? root.describe(d) : "", root.notifyIcon(kind, d), kind === "warning" ? "critical" : "normal")
    }
    function openDetails(): void { root.ejectMode = false; root.open() }
    function openEject(): void { root.ejectMode = true; root.open() }
    function refresh(): void { root.refresh() }
    // Animation preview: `attach` replays the arrival, `busy` loops for N
    // seconds, `launch` opens the eject pop-up and plays an eject of the
    // latest drive without touching it.
    function preview(kind: string, seconds: int): void {
      if (kind === "attach") { root.insertTick++; return }
      if (kind === "launch") { root.previewLaunch(Math.max(1, Math.min(10, seconds))); return }
      root.previewBusy = true
      previewTimer.interval = Math.max(1, Math.min(120, seconds)) * 1000
      previewTimer.restart()
    }
  }
}
