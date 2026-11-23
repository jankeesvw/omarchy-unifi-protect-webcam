import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A UniFi Protect camera as a webcam.
//
// The panel is a list of your cameras with a switch beside each. Switch one on
// and it shows up in Meet, Zoom and the rest as a camera called "UniFi
// Protect"; switch another on and the same camera shows that one instead, so a
// call that already picked it never has to pick again.
//
// Nothing here talks to the console or touches a frame. bin/unifi-protect-webcam
// does all of that, and `watch` streams a line of JSON whenever its state
// changes, so the panel has nothing to poll.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.unifi-protect-webcam"
  ipcTarget: "jankeesvw.unifi-protect-webcam"

  readonly property string iconGear: ""
  readonly property string iconRefresh: ""
  readonly property string iconBack: ""
  readonly property string iconCopy: ""

  readonly property string script:
    decodeURIComponent(Qt.resolvedUrl("bin/unifi-protect-webcam").toString().replace(/^file:\/\//, ""))

  readonly property string host: String(setting("host", "192.168.1.1"))
  readonly property string size: setting("size", "1080p") === "720p" ? "720p" : "1080p"
  readonly property string lastCamera: String(setting("camera", ""))
  readonly property int panelWidth: setting("panelWidth", 340)

  readonly property int gap: Style.space(10)
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color muted: fade(foreground, 0.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string monoFamily: "JetBrainsMono Nerd Font"

  // --- state ------------------------------------------------------------------

  // The last line `watch` printed, replaced wholesale.
  property var payload: ({})
  readonly property bool loaded: payload.ok === true
  readonly property var feed: payload.feed || ({})
  readonly property var device: payload.device || ({})
  readonly property bool hasKey: payload.key === true
  readonly property bool trusted: payload.trusted === true
  readonly property bool deviceReady: device.ready === true
  readonly property bool live: feed.on === true
  readonly property bool streaming: live && feed.streaming === true

  property var cameras: []
  property string camerasError: ""
  property bool camerasLoading: false
  // Set when the console stopped presenting the certificate you pinned: the
  // only way on from there is to look at the new one.
  property bool repin: false

  property bool userSettings: false
  property string settingsError: ""
  property var trustInfo: null
  property string trustError: ""

  property bool busy: false
  property string actionError: ""
  property int cursor: 0

  readonly property string view: !loaded ? "loading"
    : (!hasKey || userSettings) ? "settings"
    : (!trusted || repin) ? "trust"
    : "cameras"

  onViewChanged: {
    if (view === "trust") root.showTrust()
    if (view === "cameras" && root.opened) root.refreshCameras()
    Qt.callLater(root.focusView)
  }

  onOpenedChanged: {
    if (!root.opened) return
    root.actionError = ""
    if (root.view === "cameras") root.refreshCameras()
    if (root.view === "trust") root.showTrust()
  }

  // --- helpers ----------------------------------------------------------------

  // Camera names, errors and certificate subjects come from somewhere else.
  // Every Text below is PlainText regardless; this is for the bar tooltip, which
  // is the shell's own component and not ours to pin.
  function plain(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/[<>&]/g, "").replace(/[\u0000-\u001f\u007f-\u009f]/g, "").slice(0, 160)
  }

  function fade(c, amount) {
    var bg = Commons.Color.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount, c.g + (bg.g - c.g) * amount,
                   c.b + (bg.b - c.b) * amount, 1)
  }

  // Under the system python with -I -S, so nothing in the environment or the
  // working directory decides what runs.
  function cmd(args) { return ["/usr/bin/python3", "-I", "-S", root.script].concat(args) }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cameraName(id) {
    for (var i = 0; i < root.cameras.length; i++)
      if (root.cameras[i].id === id) return root.cameras[i].name
    return String(root.feed.camera || "")
  }

  function isActive(id) { return root.live && root.feed.camera_id === id }

  function rowEnabled(camera) {
    return root.deviceReady && !root.busy && camera && (camera.connected === true || root.isActive(camera.id))
  }

  readonly property string statusLine: {
    if (root.busy) return "Switching…"
    if (root.actionError !== "") return root.actionError
    if (root.device.taken === true) return "Something else already uses /dev/video42, so there is nowhere to put the picture."
    if (!root.deviceReady) return "One-time setup first: the virtual camera does not exist yet."
    var name = String(root.feed.camera || root.cameraName(root.feed.camera_id))
    if (root.streaming) return "Live as “UniFi Protect” · " + name + " · " + root.feed.fps + " fps"
    if (root.live && root.feed.error) return name + ": " + root.feed.error
    if (root.live) return "Connecting to " + name + "…"
    if (root.feed.error) return "Stopped: " + root.feed.error
    return "Off. Pick a camera and calls see it as “UniFi Protect”."
  }
  readonly property bool statusBad: root.actionError !== "" || root.device.taken === true
    || (root.live && !root.streaming && !!root.feed.error) || (!root.live && !!root.feed.error)

  // What the one-time setup asks for, verbatim, and the same as the README. The
  // panel never runs any of it: it needs root, and root runs only what you
  // pasted into your own terminal. The two files are written out in full rather
  // than copied from the plugin's directory, so nothing root installs is read
  // from a place your own account can change.
  readonly property string setupCommands: [
    "sudo pacman -S --needed v4l2loopback-dkms v4l2loopback-utils",
    "sudo tee /etc/systemd/system/unifi-protect-webcam.service >/dev/null <<'EOF'",
    "[Unit]",
    "Description=Virtual camera for the UniFi Protect Webcam plugin",
    "After=systemd-modules-load.service",
    "",
    "[Service]",
    "Type=oneshot",
    "RemainAfterExit=yes",
    "ExecStartPre=/bin/sh -c 'if /usr/bin/modprobe -c | /usr/bin/grep -q \"^options v4l2loopback \"; then exec /usr/bin/modprobe v4l2loopback; else exec /usr/bin/modprobe v4l2loopback devices=0; fi'",
    "ExecStart=/usr/bin/v4l2loopback-ctl add --name \"UniFi Protect\" --exclusive-caps 1 /dev/video42",
    "ExecStop=/usr/bin/v4l2loopback-ctl delete /dev/video42",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "EOF",
    "echo 'SUBSYSTEM==\"video4linux\", KERNEL==\"video42\", TAG+=\"uaccess\"' | sudo tee /etc/udev/rules.d/70-unifi-protect-webcam.rules >/dev/null",
    "sudo udevadm control --reload-rules",
    "sudo systemctl daemon-reload",
    "sudo systemctl enable --now unifi-protect-webcam.service"
  ].join("\n")

  // --- actions ----------------------------------------------------------------

  function refreshCameras() {
    if (camerasProc.running || !root.hasKey || !root.trusted) return
    root.camerasError = ""
    root.camerasLoading = true
    camerasProc.command = root.cmd(["cameras", "--host", root.host])
    camerasProc.running = true
  }

  function switchTo(id) {
    if (root.busy || !id) return
    root.actionError = ""
    root.busy = true
    if (root.isActive(id)) {
      actionProc.command = root.cmd(["off"])
    } else {
      root.persistSettings({ camera: id })
      actionProc.command = root.cmd(["on", "--host", root.host, "--size", root.size, id])
    }
    actionProc.running = true
  }

  function toggleFromBar() {
    if (root.busy) return
    if (root.live) root.switchTo(root.feed.camera_id)
    else if (root.lastCamera !== "" && root.deviceReady && root.hasKey && root.trusted)
      root.switchTo(root.lastCamera)
    else root.open()
  }

  function setSize(next) {
    if (next === root.size) return
    root.persistSettings({ size: next })
    // A running camera picks the new size up straight away.
    if (root.live && !root.busy) {
      root.busy = true
      actionProc.command = root.cmd(["on", "--host", root.host, "--size", next, root.feed.camera_id])
      actionProc.running = true
    }
  }

  function saveSettings() {
    root.settingsError = ""
    var nextHost = String(hostField.text).trim()
    if (nextHost === "") nextHost = "192.168.1.1"
    if (nextHost !== root.host) {
      root.persistSettings({ host: nextHost })
      root.cameras = []
      root.trustInfo = null
    }
    var key = String(keyField.text).trim()
    if (key !== "") {
      if (keyProc.running) return
      keyProc.pending = key
      keyProc.command = root.cmd(["set-key"])
      keyProc.running = true
      return
    }
    if (root.hasKey) root.userSettings = false
    else root.settingsError = "Paste an API key first."
  }

  function showSettings() {
    hostField.text = root.host
    keyField.text = ""
    root.settingsError = ""
    root.userSettings = true
  }

  function showTrust() {
    root.trustInfo = null
    root.trustError = ""
    if (trustShowProc.running) return
    trustShowProc.command = root.cmd(["trust", "show", "--host", root.host])
    trustShowProc.running = true
  }

  // Pins what is on screen and only that: `trust accept` fetches the
  // certificate again and refuses if it is not the one you were shown.
  function acceptTrust() {
    if (!root.trustInfo || trustAcceptProc.running) return
    root.trustError = ""
    trustAcceptProc.command = root.cmd(["trust", "accept", "--host", root.host, String(root.trustInfo.fingerprint)])
    trustAcceptProc.running = true
  }

  property bool copied: false
  Timer { id: copiedReset; interval: 2500; onTriggered: root.copied = false }

  function copySetup() {
    if (copyProc.running) return
    copyProc.pending = root.setupCommands
    copyProc.running = true
    root.copied = true
    copiedReset.restart()
  }

  function moveCursor(step) {
    var count = root.cameras.length
    if (count === 0) return
    root.cursor = Math.max(0, Math.min(count - 1, root.cursor + step))
  }

  function focusView() {
    if (!root.opened) return
    if (root.view === "settings") hostField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  // --- bar --------------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (!root.loaded) return "UniFi Protect Webcam"
      if (!root.hasKey || !root.trusted || !root.deviceReady) return "UniFi Protect Webcam needs setting up"
      if (root.streaming) return "UniFi Protect Webcam · " + root.plain(root.feed.camera) + " · right-click to stop"
      if (root.live) return "UniFi Protect Webcam · connecting to " + root.plain(root.feed.camera)
      return "UniFi Protect Webcam is off · right-click for the last camera"
    }
    onPressed: function (b) {
      if (b === Qt.RightButton) root.toggleFromBar()
      else root.toggle()
    }
    iconComponent: Component {
      UniFiCameraMark {
        iconSize: Style.font.icon
        // Lit while a call can see the camera; the one place that says so
        // without opening anything.
        color: root.streaming ? Commons.Color.accent
             : (root.live && root.feed.error ? Commons.Color.urgent : root.foreground)
        opacity: root.live ? 1.0 : 0.55
      }
    }
  }

  // --- processes --------------------------------------------------------------

  Process {
    id: watcher
    running: true
    command: root.cmd(["watch"])
    stdout: SplitParser {
      onRead: function (line) {
        if (line.length > 8192) return
        var next
        try { next = JSON.parse(line) } catch (e) { return }
        if (next && typeof next === "object") root.payload = next
      }
    }
    // The helper does not exit on its own; if it ever does, start it again.
    onExited: restartWatch.start()
  }
  Timer { id: restartWatch; interval: 2000; onTriggered: watcher.running = true }

  Process {
    id: camerasProc
    stdout: SplitParser {
      onRead: function (line) {
        if (line.length > 65536) return
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (data.ok === true && Array.isArray(data.cameras)) {
          var list = []
          for (var i = 0; i < data.cameras.length && i < 64; i++) {
            var c = data.cameras[i]
            if (!c || !/^[A-Za-z0-9]{1,64}$/.test(String(c.id))) continue
            list.push({ id: String(c.id), name: String(c.name || c.id).slice(0, 64), connected: c.connected === true })
          }
          root.cameras = list
          root.repin = false
          if (root.cursor >= list.length) root.cursor = 0
          for (var j = 0; j < list.length; j++) if (root.isActive(list[j].id)) root.cursor = j
        } else {
          root.camerasError = String(data.error || "could not list the cameras").slice(0, 200)
          if (data.reason === "pinchanged") root.repin = true
        }
      }
    }
    onExited: root.camerasLoading = false
  }

  Process {
    id: actionProc
    stdout: SplitParser {
      onRead: function (line) {
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (data.ok !== true) root.actionError = String(data.error || "that did not work").slice(0, 200)
      }
    }
    onExited: root.busy = false
  }

  Process {
    id: keyProc
    stdinEnabled: true
    property string pending: ""
    stdout: SplitParser {
      onRead: function (line) {
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (data.ok === true) {
          keyField.text = ""
          root.userSettings = false
        } else {
          root.settingsError = String(data.error || "could not save the key").slice(0, 200)
        }
      }
    }
    // The key travels on stdin, never on a command line, and is let go of as
    // soon as it is written.
    onStarted: {
      write(pending + "\n")
      pending = ""
      stdinEnabled = false
    }
    onExited: {
      pending = ""
      stdinEnabled = true
    }
  }

  Process {
    id: trustShowProc
    stdout: SplitParser {
      onRead: function (line) {
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (data.ok === true && /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(String(data.fingerprint))) {
          root.trustInfo = data
        } else {
          root.trustInfo = null
          root.trustError = String(data.error || "could not read the certificate").slice(0, 200)
        }
      }
    }
  }

  Process {
    id: trustAcceptProc
    stdout: SplitParser {
      onRead: function (line) {
        var data
        try { data = JSON.parse(line) } catch (e) { return }
        if (data.ok === true) {
          root.repin = false
          root.trustInfo = null
          root.cameras = []
          root.refreshCameras()
        } else {
          root.trustError = String(data.error || "nothing was pinned").slice(0, 200)
          root.showTrust()
        }
      }
    }
  }

  Process {
    id: copyProc
    command: ["/usr/bin/wl-copy"]
    stdinEnabled: true
    property string pending: ""
    onStarted: {
      write(pending)
      pending = ""
      stdinEnabled = false
    }
    onExited: stdinEnabled = true
  }

  // --- panel ------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.view === "settings" ? hostField : keyCatcher

    readonly property int desiredWidth: Style.space(root.panelWidth)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // A plain Item rather than PanelKeyCatcher: the settings view is a form,
    // and an ancestor Item only sees the keys its focused field did not want,
    // so Tab walks the fields and Enter presses what has the focus.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.view === "settings" && root.hasKey) root.userSettings = false
          else root.close()
          event.accepted = true
          return
        }
        if (root.view !== "cameras") return
        if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
          root.moveCursor(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
          root.moveCursor(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          var camera = root.cameras[root.cursor]
          if (camera && root.rowEnabled(camera)) root.switchTo(camera.id)
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          root.refreshCameras(); event.accepted = true
        } else if (event.key === Qt.Key_Comma) {
          root.showSettings(); event.accepted = true
        }
      }

      ColumnLayout {
        id: content
        width: parent.width
        spacing: root.gap

        // -- header ----------------------------------------------------------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          UniFiCameraMark {
            iconSize: Style.font.icon
            color: root.streaming ? Commons.Color.accent : root.foreground
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "UniFi Protect Webcam"
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            color: root.foreground
            elide: Text.ElideRight
          }
          PanelActionButton {
            visible: root.view === "cameras"
            iconText: root.iconRefresh
            tooltipText: "Reload the cameras (R)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.refreshCameras()
          }
          PanelActionButton {
            visible: root.view === "cameras" || root.view === "trust"
            iconText: root.iconGear
            tooltipText: "Console and key (,)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showSettings()
          }
          PanelActionButton {
            visible: root.view === "settings" && root.hasKey
            iconText: root.iconBack
            tooltipText: "Back (Esc)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.userSettings = false
          }
        }

        Text {
          visible: root.view === "loading"
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Loading…"
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.muted
        }

        // -- cameras ---------------------------------------------------------

        ColumnLayout {
          visible: root.view === "cameras"
          Layout.fillWidth: true
          spacing: root.gap

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.statusLine
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.statusBad ? Commons.Color.urgent : (root.streaming ? root.foreground : root.muted)
          }

          // The one-time setup, shown until the device exists.
          Rectangle {
            visible: !root.deviceReady && root.device.taken !== true
            Layout.fillWidth: true
            implicitHeight: setupColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.fade(root.foreground, 0.7)

            ColumnLayout {
              id: setupColumn
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Run these once in a terminal. They need sudo, which is why the plugin does not run them for you. The README says what each line does."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.muted
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                text: root.setupCommands
                font.family: root.monoFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
              }
              Button {
                text: root.copied ? "Copied" : "Copy commands"
                iconText: root.iconCopy
                focusable: true
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copySetup()
              }
            }
          }

          Text {
            visible: root.camerasError !== "" || (root.camerasLoading && root.cameras.length === 0)
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.camerasError !== "" ? root.camerasError : "Asking the console for its cameras…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.camerasError !== "" ? Commons.Color.urgent : root.muted
          }

          Repeater {
            model: root.cameras

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool active: root.isActive(modelData.id)
              readonly property bool enabledRow: root.rowEnabled(modelData)
              readonly property bool here: root.cursor === index

              Layout.fillWidth: true
              implicitHeight: Math.max(Style.space(36), rowLine.implicitHeight + Style.space(12))
              radius: Style.cornerRadius
              color: here ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
              border.width: here ? 1 : 0
              border.color: root.fade(root.foreground, 0.6)

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: row.enabledRow ? Qt.PointingHandCursor : Qt.ArrowCursor
                onEntered: root.cursor = row.index
                onClicked: if (row.enabledRow) root.switchTo(row.modelData.id)
              }

              RowLayout {
                id: rowLine
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: row.modelData.name
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.active
                  color: row.enabledRow || row.active ? root.foreground : root.muted
                }
                Text {
                  textFormat: Text.PlainText
                  text: row.active ? (root.streaming ? "live" : "connecting")
                      : (row.modelData.connected ? "" : "offline")
                  visible: text !== ""
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: row.active && root.streaming ? Commons.Color.accent : root.muted
                }
                ToggleSwitch {
                  checked: row.active
                  hasCursor: row.here
                  enabled: row.enabledRow
                  opacity: enabled ? 1.0 : 0.45
                  foreground: root.foreground
                  onToggled: root.switchTo(row.modelData.id)
                }
              }
            }
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "↑↓ choose · Enter switch · , settings · Esc close"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
        }

        // -- settings --------------------------------------------------------

        ColumnLayout {
          visible: root.view === "settings"
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: "Console address"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
          TextField {
            id: hostField
            Layout.fillWidth: true
            text: root.host
            maximumLength: 64
            activeFocusOnTab: true
            foreground: root.foreground
            placeholderText: "192.168.1.1"
            onAccepted: keyField.forceActiveFocus()
          }

          Text {
            Layout.topMargin: Style.space(6)
            textFormat: Text.PlainText
            text: "API key"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
          TextField {
            id: keyField
            Layout.fillWidth: true
            password: true
            maximumLength: 256
            activeFocusOnTab: true
            foreground: root.foreground
            placeholderText: root.hasKey ? "Saved. Paste a new one to replace it" : "Paste the key here"
            onAccepted: root.saveSettings()
          }
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Make one at https://" + root.host + "/unifi-api/protect, ideally signed in as a local user with Protect: View Only. It is stored in ~/.config/unifi-protect-webcam and only ever sent to the console you pin next."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }

          Text {
            Layout.topMargin: Style.space(6)
            textFormat: Text.PlainText
            text: "Picture"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
          RowLayout {
            spacing: Style.space(6)
            Button {
              text: "1080p"
              selected: root.size === "1080p"
              bordered: true
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setSize("1080p")
            }
            Button {
              text: "720p"
              selected: root.size === "720p"
              bordered: true
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setSize("720p")
            }
          }

          Text {
            visible: root.settingsError !== ""
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.settingsError
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: Commons.Color.urgent
          }

          Button {
            Layout.topMargin: Style.space(6)
            text: keyProc.running ? "Saving…" : "Save"
            bordered: true
            focusable: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveSettings()
          }
        }

        // -- trust -----------------------------------------------------------

        ColumnLayout {
          visible: root.view === "trust"
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.repin
              ? "The console is presenting a different certificate from the one you trusted. Nothing is sent to it until you have looked at this one."
              : "Your console signs its own certificate. Compare this fingerprint with the one your browser shows for https://" + root.host + ", then trust it. The key and the video only ever go to a console with this certificate."
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.repin ? Commons.Color.urgent : root.foreground
          }
          Text {
            visible: root.trustInfo !== null
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            text: root.trustInfo ? String(root.trustInfo.fingerprint) : ""
            font.family: root.monoFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }
          Text {
            visible: root.trustInfo !== null
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.trustInfo
              ? String(root.trustInfo.subject || "") + " · valid until " + String(root.trustInfo.expires || "?")
              : ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
          Text {
            visible: root.trustInfo === null && root.trustError === ""
            textFormat: Text.PlainText
            text: "Fetching the certificate…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.muted
          }
          Text {
            visible: root.trustError !== ""
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.trustError
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: Commons.Color.urgent
          }
          RowLayout {
            spacing: Style.space(6)
            Button {
              text: trustAcceptProc.running ? "Checking…" : "Trust this certificate"
              enabled: root.trustInfo !== null
              bordered: true
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.acceptTrust()
            }
            Button {
              text: "Fetch again"
              bordered: true
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showTrust()
            }
          }
        }
      }
    }
  }
}
