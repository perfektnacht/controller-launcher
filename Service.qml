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
  // The shell strips __sourceDir from manifests it hands to third-party
  // plugins, so a normal `omarchy plugin add` install never sees it. This file
  // was loaded from the plugin directory, so its own URL names that directory
  // wherever it was installed. Still gated on `manifest` so the daemon starts
  // at the same beat as before -- see onPluginDirChanged.
  readonly property string pluginDir: !manifest ? ""
    : manifest.__sourceDir ? String(manifest.__sourceDir) : root.ownDir()

  function ownDir() {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") !== 0) return ""
    return decodeURIComponent(url.slice("file://".length)).replace(/\/+$/, "")
  }

  // Daemon events for the overlay. The overlay is handed this service and
  // listens; the service cannot reach the overlay, because third-party plugins
  // get no handle on the shell's panel loaders.
  signal aimed(real x, real y)
  signal abortingRequested()
  signal commitRequested()
  signal launchersRefreshed()

  // Mirrors of the daemon's state. The daemon is the source of truth for all
  // three -- we set them from its status lines rather than optimistically on
  // request, so the bar indicator can never claim a grab that failed.
  property bool armed: false
  property bool connected: false
  property string deviceName: ""
  property string devicePath: ""
  property string summonButton: "mode"

  property var launchers: []

  // Everything the picker can offer, refreshed when the menu opens rather than
  // held live: probing every evdev node is not something to do on a timer for
  // a list nobody is looking at.
  property var devices: []

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

  // Empty means automatic, which is both the default and what the picker's
  // first entry restores. Stored like summonButton rather than kept for the
  // session: which controller is on your desk changes far less often than
  // whether you want the wheel armed.
  readonly property string configuredDevice: root.settingValue("device")

  // Bar widgets are handed their shell.json entry as `settings`; services are
  // not, so read the same entry the bar widget would.
  function settingValue(key) {
    return root.entryValue(root.ownEntry(), key)
  }

  // Our shell.json entry: layout first, then the top-level plugins array,
  // which is the order the shell writes them in. `barConfig` is all a
  // third-party plugin is given; only a first-party shell also exposes the
  // whole of shell.json, and with it `plugins`.
  function ownEntry() {
    var bar = root.shell ? root.shell.barConfig : null
    var layout = (bar && bar.layout) ? bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (root.isOwnEntry(entries[i])) return entries[i]
      }
    }

    var config = root.shell ? root.shell.shellConfig : null
    var plugins = (config && Array.isArray(config.plugins)) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++) {
      if (root.isOwnEntry(plugins[p])) return plugins[p]
    }
    return null
  }

  // Widget ids can carry an instance suffix, so match on the part before it.
  function isOwnEntry(entry) {
    return !!entry && !!entry.id && String(entry.id).split("#")[0] === root.pluginId
  }

  function entryValue(entry, key) {
    if (!root.isOwnEntry(entry)) return ""
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
    var argv = [root.pluginDir + "/bin/omarchy-controller-launcherd",
                "--summon", root.configuredSummon]
    if (root.configuredDevice !== "") argv.push("--device", root.configuredDevice)
    daemon.command = argv
    daemon.running = true
  }

  // The daemon reads --summon and --device once at startup, so a changed
  // setting only reaches it through a restart.
  property bool restartingForSetting: false

  // Capture is deliberate and per-session. Editing a setting is not a request
  // to stop capturing, so a restart that we caused re-arms itself once the new
  // daemon reports for duty.
  property bool rearmAfterRestart: false

  function restartForSetting() {
    if (!daemon.running) {
      startDaemon()
      return
    }
    root.rearmAfterRestart = root.armed
    root.restartingForSetting = true
    daemon.running = false
  }

  onConfiguredSummonChanged: root.restartForSetting()
  onConfiguredDeviceChanged: root.restartForSetting()

  // Which controller to drive the wheel with. Empty hands it back to the
  // daemon's own preference order. Persisted through the same path the bar
  // widget's other settings take, so it survives a restart.
  // updateEntryInline replaces the whole entry, so carry the other keys over.
  // It returns false for an unchanged entry too, so there is nothing to report.
  function selectDevice(path) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") return
    var settings = ({})
    var current = root.ownEntry() || {}
    for (var k in current) if (k !== "id") settings[k] = current[k]
    settings.device = String(path || "")
    root.shell.updateEntryInline(root.pluginId, settings)
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
  // summons, so it is already listening when the signals above fire.

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
      root.devicePath = root.connected ? String(event.path || "") : ""
      if (!root.connected) root.hideWheel()
      break

    // No refresh here: Wheel.open() asks for one, which covers this summon
    // and every other entry point rather than just the controller button.
    case "summon":
      root.showWheel()
      break

    case "aim":
      root.aimed(Number(event.x) || 0, Number(event.y) || 0)
      break

    case "aborting":
      root.abortingRequested()
      break

    // Delivery is synchronous, so the wheel launches before it is hidden.
    case "commit":
      root.commitRequested()
      root.hideWheel()
      break

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
      root.launchersRefreshed()
    }
  }

  function refreshLaunchers() {
    if (discovery.running || root.pluginDir === "") return
    discovery.collected = ""
    discovery.command = [root.pluginDir + "/bin/omarchy-controller-launcher-launchers"]
    discovery.running = true
  }

  // --------------------------------------------------------------- catalog

  // Everything the wheel could draw, switched-off entries included. Kept apart
  // from `launchers` because that list has already dropped whatever is hidden,
  // so a menu built on it could only ever take entries away.
  property var catalog: []

  // Why the last toggle was refused. The script declines to touch a config it
  // cannot parse or a guard someone wrote by hand, and a menu that swallowed
  // that would just look like it had ignored the click.
  property string catalogError: ""

  // Which entry has a write in flight. The script takes a lock, so a second
  // click would wait rather than race, but a row should stop accepting clicks
  // it cannot reflect yet.
  property string togglingId: ""

  Process {
    id: catalogScan
    property string collected: ""

    stdout: SplitParser {
      onRead: function(line) { catalogScan.collected += line + "\n" }
    }
    onExited: function(code) {
      var raw = catalogScan.collected
      catalogScan.collected = ""
      if (code !== 0) return
      try {
        var parsed = JSON.parse(raw)
        if (Array.isArray(parsed)) root.catalog = parsed
      } catch (error) {
        console.warn("controller-launcher: catalog returned invalid JSON")
      }
    }
  }

  function refreshCatalog() {
    if (catalogScan.running || root.pluginDir === "") return
    catalogScan.collected = ""
    catalogScan.command = [root.pluginDir + "/bin/omarchy-controller-launcher-launchers",
                           "--all"]
    catalogScan.running = true
  }

  // The script's exit codes, in the words the menu should use. Anything else
  // is a bug in one of the two, so it says so plainly rather than guessing.
  function toggleMessage(code, id) {
    switch (code) {
    case 2: return "No entry called " + id + "."
    case 3: return "A rule in your config decides that one."
    case 4: return "gamepad-wheel.json is not valid JSON."
    default: return "Could not switch " + id + "."
    }
  }

  Process {
    id: toggle

    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text) console.warn("controller-launcher: " + text)
      }
    }

    // Re-read the catalog either way. On success it is the new state; on a
    // refusal it is the state that was there all along, which is exactly what
    // the row should snap back to.
    onExited: function(code) {
      var id = root.togglingId
      root.togglingId = ""
      root.catalogError = (code === 0) ? "" : root.toggleMessage(code, id)
      root.refreshCatalog()
      if (code === 0) root.refreshLaunchers()
    }
  }

  function toggleEntry(id) {
    if (root.togglingId !== "" || toggle.running || root.pluginDir === "") return
    root.togglingId = String(id)
    toggle.command = [root.pluginDir + "/bin/omarchy-controller-launcher-toggle",
                      String(id), "flip"]
    toggle.running = true
  }

  // --------------------------------------------------------------- devices

  Process {
    id: deviceScan
    property string collected: ""

    stdout: SplitParser {
      onRead: function(line) { deviceScan.collected += line + "\n" }
    }
    onExited: function(code) {
      var raw = deviceScan.collected
      deviceScan.collected = ""
      if (code !== 0) return
      try {
        var parsed = JSON.parse(raw)
        if (Array.isArray(parsed)) root.devices = parsed
      } catch (error) {
        console.warn("controller-launcher: device list returned invalid JSON")
      }
    }
  }

  // Runs the daemon's own lister in a second process rather than asking the
  // running daemon: a grab is exclusive over events and not over opening, and
  // each hidraw open has its own report queue, so this cannot take input away
  // from the daemon holding a controller.
  function refreshDevices() {
    if (deviceScan.running || root.pluginDir === "") return
    deviceScan.collected = ""
    deviceScan.command = [root.pluginDir + "/bin/omarchy-controller-launcherd",
                          "--list-devices", "--json"]
    deviceScan.running = true
  }
}
