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

  readonly property string pluginId: "perfektnacht.controller-launcher"
  readonly property string pluginDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""

  // Mirrors of the daemon's state. The daemon is the source of truth for all
  // three -- we set them from its status lines rather than optimistically on
  // request, so the bar indicator can never claim a grab that failed.
  property bool armed: false
  property bool connected: false
  property string deviceName: ""
  property string summonButton: "mode"

  property var launchers: []

  // ------------------------------------------------------------- the setting

  // What the daemon understands. Anything else in shell.json is a typo, and
  // falling back beats starting a daemon that exits with "unknown button".
  readonly property var summonChoices: [
    "south", "east", "north", "west", "select", "start", "mode"
  ]

  readonly property string configuredSummon: {
    var wanted = root.settingValue("summonButton")
    return root.summonChoices.indexOf(wanted) !== -1 ? wanted : "mode"
  }

  // Bar widgets are handed their shell.json entry as `settings`; services are
  // not, so read the same entry the bar widget would. Layout first, then the
  // top-level plugins array, which is the order the shell writes them in.
  function settingValue(key) {
    var config = root.shell ? root.shell.shellConfig : null
    if (!config) return ""

    var layout = (config.bar && config.bar.layout) ? config.bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        var found = root.entryValue(entries[i], key)
        if (found !== "") return found
      }
    }

    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++) {
      var hit = root.entryValue(plugins[p], key)
      if (hit !== "") return hit
    }
    return ""
  }

  // Widget ids can carry an instance suffix, so match on the part before it.
  function entryValue(entry, key) {
    if (!entry || !entry.id) return ""
    if (String(entry.id).split("#")[0] !== root.pluginId) return ""
    return (key in entry) ? String(entry[key]) : ""
  }

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
        if (text) console.warn("controller-launcher: " + text)
      }
    }

    // A daemon that died with the wheel open would otherwise leave the
    // overlay on screen with nothing able to dismiss it.
    onExited: {
      root.armed = false
      root.connected = false
      root.hideWheel()
      // Deferred: `running` is still true inside its own exit handler, and
      // startDaemon() treats that as "already up" and does nothing.
      if (root.restartingForSetting) {
        root.restartingForSetting = false
        Qt.callLater(root.startDaemon)
      }
    }
  }

  function startDaemon() {
    if (root.pluginDir === "" || daemon.running) return
    daemon.command = [root.pluginDir + "/bin/omarchy-controller-launcherd",
                      "--summon", root.configuredSummon]
    daemon.running = true
  }

  // The daemon reads --summon once at startup, so a changed setting only
  // reaches it through a restart.
  property bool restartingForSetting: false

  // Capture is deliberate and per-session. Editing a setting is not a request
  // to stop capturing, so a restart that we caused re-arms itself once the new
  // daemon reports for duty.
  property bool rearmAfterRestart: false

  onConfiguredSummonChanged: {
    if (!daemon.running) {
      startDaemon()
      return
    }
    root.rearmAfterRestart = root.armed
    root.restartingForSetting = true
    daemon.running = false
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

  // Arming is the dependable beat before a summon, and it costs a handful of
  // `command -v` calls. Refreshing here means the first wheel of a session
  // usually opens correct rather than correcting itself a frame later.
  onArmedChanged: if (root.armed) refreshLaunchers()

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
      console.warn("controller-launcher: unparseable daemon line: " + text)
      return
    }

    switch (event.t) {
    case "status":
      root.armed = event.armed === true
      root.connected = event.connected === true
      root.deviceName = String(event.name || "")
      root.summonButton = String(event.summon || root.summonButton)
      if (root.rearmAfterRestart) {
        root.rearmAfterRestart = false
        if (!root.armed) root.arm()
      }
      break

    case "device":
      root.connected = event.connected === true
      if (event.name) root.deviceName = String(event.name)
      if (!root.connected) root.hideWheel()
      break

    // No refresh here: Wheel.open() asks for one, which covers this summon
    // and every other entry point rather than just the controller button.
    case "summon":
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
      console.warn("controller-launcher: " + String(event.msg || ""))
      break
    }
  }

  // ------------------------------------------------------------- launchers

  // Re-run on every summon: installing Lutris should not need a shell restart
  // to show up, and the guards are a handful of `command -v` calls.
  Process {
    id: discovery
    property string collected: ""
    // Raw output of the last run that we accepted, so an unchanged result can
    // be dropped before it touches root.launchers.
    property string signature: ""

    stdout: SplitParser {
      onRead: function(line) { discovery.collected += line + "\n" }
    }
    onExited: function(code) {
      var raw = discovery.collected
      discovery.collected = ""
      if (code !== 0) return

      // Nothing installed or removed since the last run, which is the common
      // case. Reassigning would rebuild every wedge delegate for no change.
      if (raw === discovery.signature) return

      var parsed
      try {
        parsed = JSON.parse(raw)
      } catch (error) {
        console.warn("controller-launcher: launcher discovery returned invalid JSON")
        return
      }
      if (!Array.isArray(parsed)) return

      discovery.signature = raw
      root.launchers = parsed

      // The wheel takes its copy of the list when it opens, and the discovery
      // we start on summon lands a beat after that. Hand the result to the
      // wheel already on screen, or the first summon after installing
      // something keeps showing it greyed out.
      var wheel = root.wheelItem()
      if (wheel && typeof wheel.refreshLaunchers === "function") wheel.refreshLaunchers()
    }
  }

  function refreshLaunchers() {
    if (discovery.running || root.pluginDir === "") return
    discovery.collected = ""
    discovery.command = [root.pluginDir + "/bin/omarchy-controller-launcher-launchers"]
    discovery.running = true
  }
}
