import QtQuick
import qs.Commons
import qs.Ui

// Arm/disarm toggle and the honest answer to "is this thing intercepting my
// controller right now?". Left click toggles capture, right click opens a menu
// holding the controller picker and the wheel itself.
BarWidget {
  id: root
  moduleName: "perfektnacht.controller-launcher"

  readonly property string pluginId: "perfektnacht.controller-launcher"

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
  readonly property string devicePath: wheelService ? String(wheelService.devicePath || "") : ""
  readonly property string pinnedDevice: wheelService ? String(wheelService.configuredDevice || "") : ""
  readonly property var devices: wheelService && Array.isArray(wheelService.devices)
    ? wheelService.devices : []

  readonly property var catalog: wheelService && Array.isArray(wheelService.catalog)
    ? wheelService.catalog : []
  readonly property string catalogError: wheelService
    ? String(wheelService.catalogError || "") : ""
  readonly property string togglingId: wheelService
    ? String(wheelService.togglingId || "") : ""

  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: Style.font.family

  property bool menuOpen: false

  // PopupCard routes its own dismissal -- an outside click clearing Hyprland's
  // focus grab -- through owner.close(). Without this it would assign to its
  // `open` binding instead, breaking the binding and leaving the menu stuck.
  function close() {
    root.menuOpen = false
  }

  // Kernel device names lead with the manufacturer's full legal name, which is
  // most of the width and none of the information: "Sony Interactive
  // Entertainment DualSense Wireless Controller" elides to "Sony Interactive
  // Entertainment DualS...", telling you nothing about which pad it is. Only
  // exact known prefixes are dropped, so an unrecognised device keeps its name
  // whole rather than being trimmed by a guess.
  readonly property var vendorPrefixes: [
    "Sony Interactive Entertainment ",
    "Valve Software ",
    "Microsoft ",
    "Nintendo "
  ]

  function shortName(name) {
    var text = String(name || "")
    for (var i = 0; i < root.vendorPrefixes.length; i++) {
      var prefix = root.vendorPrefixes[i]
      if (text.indexOf(prefix) === 0) return text.substring(prefix.length)
    }
    return text
  }

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
      if (pressedButton === Qt.LeftButton) {
        root.wheelService.toggleArmed()
      } else if (pressedButton === Qt.RightButton) {
        // Probed on open rather than held live, so the list reflects what is
        // switched on right now instead of what was there at shell start.
        // Same for the catalog: the extensions file is editable by hand, and
        // the menu should show what is in it now rather than at shell start.
        if (!root.menuOpen) {
          root.wheelService.refreshDevices()
          root.wheelService.refreshCatalog()
        }
        root.menuOpen = !root.menuOpen
      }
    }
  }

  // KeyboardPanel rather than PopupCard: the bar's own surface takes
  // WlrKeyboardFocus.None, so a popup parented to it never sees a key press
  // and Escape would do nothing. This owns a focused layer surface instead,
  // which is what every panel in the shell that closes on Escape uses.
  KeyboardPanel {
    id: menu
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.menuOpen
    focusTarget: keyCatcher
    contentWidth: menu.fittedContentWidth(Style.space(300))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()

      Column {
        id: menuColumn
        anchors.fill: parent
        spacing: Style.space(8)

        Text {
          text: "Controller"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          visible: root.devices.length === 0
          text: "No controllers found."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // Automatic first, then one row per controller. Automatic is not a
        // device, so it carries the empty path that clears the setting.
        Repeater {
          model: {
            var rows = [{ path: "", name: "Automatic", kind: "auto" }]
            for (var i = 0; i < root.devices.length; i++) rows.push(root.devices[i])
            return rows
          }

          delegate: Item {
            id: deviceRow
            required property var modelData
            width: menuColumn.width
            implicitHeight: Style.space(28)

            readonly property string path: String(modelData.path || "")
            readonly property bool chosen: root.pinnedDevice === deviceRow.path
            // Which one is actually driving the wheel, which is only the same as
            // the chosen one when something is pinned and it turned up.
            readonly property bool live: deviceRow.path !== ""
              && root.devicePath === deviceRow.path

            Text {
              id: mark
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              width: Style.space(18)
              text: deviceRow.chosen ? "●" : "○"
              color: deviceRow.chosen ? Color.accent : Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Right-aligned and outside the eliding name, or the marker that
            // says which controller is actually driving the wheel is the first
            // thing a long device name eats.
            Text {
              id: inUse
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              visible: deviceRow.live
              text: "in use"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: mark.right
              anchors.right: inUse.visible ? inUse.left : parent.right
              anchors.rightMargin: inUse.visible ? Style.space(8) : 0
              // External input (device name, subprocess text, config). Never AutoText.
              textFormat: Text.PlainText
              text: root.shortName(deviceRow.modelData.name)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.wheelService) root.wheelService.selectDevice(deviceRow.path)
                root.menuOpen = false
              }
            }
          }
        }

        PanelSeparator { width: menuColumn.width }

        Text {
          text: "On the wheel"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        // Only ever shown after a click that did not take. The script refuses
        // to touch a config it cannot parse or a guard someone wrote by hand,
        // and swallowing that would read as the menu ignoring the click.
        Text {
          visible: root.catalogError !== ""
          width: menuColumn.width
          // External input (device name, subprocess text, config). Never AutoText.
          textFormat: Text.PlainText
          text: root.catalogError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Every entry the wheel knows about, in wheel order, switched off ones
        // included. Order is the catalog's, so an entry switched back on
        // returns to the slot it always had instead of the end of the ring.
        Repeater {
          model: root.catalog

          delegate: Item {
            id: entryRow
            required property var modelData
            width: menuColumn.width
            implicitHeight: Style.space(26)

            readonly property string entryId: String(modelData.id || "")
            readonly property bool shown: modelData.hidden !== true
            readonly property bool installed: modelData.installed === true

            // `when` holds an expression rather than a plain yes or no, so
            // there is no way to flip this row without throwing away whatever
            // rule the user wrote there. The script refuses these too -- this
            // just stops the row from offering.
            readonly property bool locked: modelData.toggleable === false

            readonly property bool busy: root.togglingId === entryRow.entryId
            readonly property bool actionable: !entryRow.locked && !entryRow.busy

            // A check rather than the device list's filled circle: those rows
            // are one-of-many and these are each independent, and the marks
            // should not imply otherwise.
            Text {
              id: check
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              width: Style.space(18)
              text: entryRow.shown ? "󰄬" : ""
              color: entryRow.locked ? Qt.darker(root.foreground, 1.5) : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Right-aligned and outside the eliding label, for the same reason
            // the device rows keep "in use" out there.
            Text {
              id: note
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              visible: entryRow.locked || !entryRow.installed
              // Locked wins: it is the one that says the row will not respond,
              // which matters more than whether the app is on disk.
              text: entryRow.locked ? "rule" : "not installed"
              color: Qt.darker(root.foreground, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: check.right
              anchors.right: note.visible ? note.left : parent.right
              anchors.rightMargin: note.visible ? Style.space(8) : 0
              // External input (device name, subprocess text, config). Never AutoText.
              textFormat: Text.PlainText
              text: String(entryRow.modelData.label || entryRow.entryId)
              // Switched off is still a choice you can reverse, so those rows
              // stay readable. Locked is dimmer because it will not respond.
              color: entryRow.locked
                ? Qt.darker(root.foreground, 1.8)
                : (entryRow.shown ? root.foreground : Qt.darker(root.foreground, 1.4))
              opacity: entryRow.busy ? 0.5 : 1.0
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              enabled: entryRow.actionable
              cursorShape: entryRow.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
              // The menu stays open: switching entries on and off is something
              // you do a few of at once, and closing after each would make
              // rearranging the wheel a series of trips to the bar.
              onClicked: {
                if (root.wheelService) root.wheelService.toggleEntry(entryRow.entryId)
              }
            }
          }
        }

        PanelSeparator { width: menuColumn.width }

        Item {
          width: menuColumn.width
          implicitHeight: Style.space(28)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: "Open the wheel"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.menuOpen = false
              if (root.wheelService) root.wheelService.showWheel()
            }
          }
        }
      }
    }
  }
}
