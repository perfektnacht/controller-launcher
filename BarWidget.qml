import QtQuick
import qs.Commons
import qs.Ui

// Arm/disarm toggle and the honest answer to "is this thing intercepting my
// controller right now?". Left click toggles capture, right click opens the
// wheel without one.
BarWidget {
  id: root
  moduleName: "perfektnacht.gamepad-wheel"

  readonly property string pluginId: "perfektnacht.gamepad-wheel"

  // Writable: the shell assigns `service` on plugins that pair UI with a
  // service entry point. Falls back to a lookup when it does not.
  property var service: null

  readonly property var wheelService: root.service
    ? root.service
    : ((root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
       ? root.bar.shell.serviceFor(root.pluginId) : null)

  readonly property bool armed: wheelService ? wheelService.armed === true : false
  readonly property bool connected: wheelService ? wheelService.connected === true : false
  readonly property string deviceName: wheelService ? String(wheelService.deviceName || "") : ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // nf-md-controller / nf-md-controller_off
    text: root.connected ? "󰊴" : "󰊵"
    opacity: root.armed ? 1.0 : 0.55

    tooltipText: {
      if (!root.connected) return "Gamepad Wheel — no controller"
      var who = root.deviceName || "Controller"
      return root.armed
        ? who + " — capturing input (click to release)"
        : who + " — passive (click to capture)"
    }

    onPressed: function(pressedButton) {
      if (!root.wheelService) return
      if (pressedButton === Qt.LeftButton) root.wheelService.toggleArmed()
      else if (pressedButton === Qt.RightButton) root.wheelService.showWheel()
    }
  }
}
