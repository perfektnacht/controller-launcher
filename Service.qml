import QtQuick
import Quickshell
import Quickshell.Io

// Owns the gamepad daemon and routes its events to the wheel overlay.
//
// `armed` is never persisted. Every shell start comes up disarmed, so input
// capture is always something you turned on for this session rather than
// something left on by a previous one.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "perfektnacht.gamepad-wheel"
  readonly property string pluginDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""

  // Mirrors of the daemon's state. The daemon is the source of truth for all
  // three -- we set them from its status lines rather than optimistically on
  // request, so the bar indicator can never claim a grab that failed.
  property bool armed: false
  property bool connected: false
  property string deviceName: ""
  property string summonButton: "mode"

  property var launchers: []

  // ------------------------------------------------------------- daemon i/o

  // command and running are both set imperatively in startDaemon(). Bound to
  // pluginDir instead, `running` can flip true in the same evaluation pass
  // that still has the pre-injection empty command, and Process starts once
  // against a path that does not exist.
  Process {
    id: daemon
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text) console.warn("gamepad-wheel: " + text)
      }
    }

    // A daemon that died with the wheel open would otherwise leave the
    // overlay on screen with nothing able to dismiss it.
    onExited: {
      root.armed = false
      root.connected = false
      root.hideWheel()
    }
  }

  function startDaemon() {
    if (root.pluginDir === "" || daemon.running) return
    daemon.command = [root.pluginDir + "/bin/omarchy-gamepad-wheeld"]
    daemon.running = true
  }

  // The shell injects `manifest` after createObject, so pluginDir arrives one
  // step behind construction.
  onPluginDirChanged: {
    startDaemon()
    refreshLaunchers()
  }

  function send(command) {
    if (!daemon.running) return
    daemon.write(command + "\n")
  }

  function arm() { send("arm") }
  function disarm() { send("disarm") }
  function toggleArmed() { send(root.armed ? "disarm" : "arm") }

  // --------------------------------------------------------------- overlay

  // The overlay is a separate entry point of this same plugin, mounted by the
  // shell's panel loader. keepLoaded in the manifest keeps it alive between
  // summons so aim updates land on a live item.
  function wheelItem() {
    if (!root.shell || !root.shell.panelLoaders) return null
    var loader = root.shell.panelLoaders[root.pluginId]
    return (loader && loader.item) ? loader.item : null
  }

  function showWheel() {
    if (!root.shell) return
    root.shell.summon(root.pluginId, JSON.stringify({ launchers: root.launchers }))
  }

  function hideWheel() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // ---------------------------------------------------------------- events

  function handleLine(line) {
    var text = String(line || "").trim()
    if (!text) return

    var event
    try {
      event = JSON.parse(text)
    } catch (error) {
      console.warn("gamepad-wheel: unparseable daemon line: " + text)
      return
    }

    switch (event.t) {
    case "status":
      root.armed = event.armed === true
      root.connected = event.connected === true
      root.deviceName = String(event.name || "")
      root.summonButton = String(event.summon || root.summonButton)
      break

    case "device":
      root.connected = event.connected === true
      if (event.name) root.deviceName = String(event.name)
      if (!root.connected) root.hideWheel()
      break

    case "summon":
      root.refreshLaunchers()
      root.showWheel()
      break

    case "aim": {
      var wheel = root.wheelItem()
      if (wheel && typeof wheel.setAim === "function") wheel.setAim(event.x, event.y)
      break
    }

    case "aborting": {
      var aborting = root.wheelItem()
      if (aborting && typeof aborting.setAborting === "function") aborting.setAborting(true)
      break
    }

    case "commit": {
      var target = root.wheelItem()
      if (target && typeof target.commit === "function") target.commit()
      root.hideWheel()
      break
    }

    case "cancel":
      root.hideWheel()
      break

    case "error":
      console.warn("gamepad-wheel: " + String(event.msg || ""))
      break
    }
  }

  // ------------------------------------------------------------- launchers

  // Re-run on every summon: installing Lutris should not need a shell restart
  // to show up, and the guards are a handful of `command -v` calls.
  Process {
    id: discovery
    property string collected: ""

    stdout: SplitParser {
      onRead: function(line) { discovery.collected += line + "\n" }
    }
    onExited: function(code) {
      var raw = discovery.collected
      discovery.collected = ""
      if (code !== 0) return
      try {
        var parsed = JSON.parse(raw)
        if (Array.isArray(parsed)) root.launchers = parsed
      } catch (error) {
        console.warn("gamepad-wheel: launcher discovery returned invalid JSON")
      }
    }
  }

  function refreshLaunchers() {
    if (discovery.running || root.pluginDir === "") return
    discovery.collected = ""
    discovery.command = [root.pluginDir + "/bin/omarchy-gamepad-wheel-launchers"]
    discovery.running = true
  }
}
